defmodule Whiska.Shell do
  @moduledoc """
  Reading an arbitrary shell command well enough to answer two questions:
  does it change anything, and which paths does it name?

  ## The governing principle

  **Anything this module cannot confidently read is reported as mutating.** A
  sniff mouse must never write code at all (ADR-0018), so an unrecognised command
  has to be treated as the dangerous case. That is the opposite balance from the
  worktree rule of ADR-0013, which polices only literal `file_path` arguments
  precisely so it can never produce a false denial — and the difference is
  deliberate. There, a false denial would land on the person and train them to
  ignore the hook. Here it lands on the mouse, which can reach for `Read` or
  `Grep` instead, while a single missed mutation defeats the whole mode.

  ## What it is not

  This is not a shell parser and does not try to be. It splits on the operators
  that separate commands, steps over leading environment assignments, and checks
  each resulting head word against a list of commands known to be read-only.
  A substitution or a nested shell is refused outright rather than guessed at.

  ## Quoting

  Operators are located against a *masked* copy of the command, in which the
  contents of quoted spans and backslash-escaped characters are replaced by a
  neutral filler of the same byte length. Without that step a `>` or a `|`
  inside an ordinary search pattern reads as a redirect or a pipe, and
  `rg "foo|bar" lib/` — or, in this repo, `grep -r "=>" lib/` — is denied. That
  is a false denial of the kind ADR-0034 warns trains a mouse to work around the
  hook, and the mask is what prevents it. The mask preserves byte offsets, so
  the operator positions it reports index into the original string.

  Judgment is made on *tokens*, never on the raw string, for the same reason:
  `\\bexec\\b` matched against raw text cannot tell `exec rm file` from
  `find . -exec grep …`, and cannot tell either from `grep -rn exec lib/`.
  """

  # Commands that cannot modify the filesystem. Deliberately conservative: a
  # command missing from this list is denied, which is recoverable, whereas a
  # mutating command wrongly added to it is not. Per ADR-0034 this list is
  # accepted maintenance — a read-only tool missing from it is a visible,
  # recoverable failure.
  @read_only ~w(
    ls cat head tail wc nl tac seq echo printf pwd whoami hostname uname date
    grep egrep fgrep rg ag find fd file stat du df tree
    sort uniq cut tr column comm join paste fold rev
    diff cmp jq yq xmllint
    which type command basename dirname realpath readlink
    env printenv true false test man help less more
    cd pushd popd dirs
    shasum md5sum sha1sum sha256sum cksum od strings xxd
    ps id groups nproc arch sleep expr tty locale
  )

  # `git` is read-only or not depending on its subcommand, and only these are
  # unambiguously read-only. Everything else — including `branch`, `tag`,
  # `stash`, `config`, `remote` and `worktree`, each of which has mutating
  # forms — is treated as mutating (ADR-0034).
  @read_only_git ~w(
    log diff status show blame rev-parse rev-list ls-files ls-tree ls-remote
    describe shortlog whatchanged cat-file reflog grep annotate count-objects
  )

  # `find` is read-only until one of its actions writes or runs something. The
  # command after `-exec` is judged on its own, which is what lets the common
  # read-only sweep through while `-exec rm` is still caught.
  @find_writing_actions ~w(-delete -fls -fprint -fprint0 -fprintf)
  @find_exec_actions ~w(-exec -execdir -ok -okdir)
  # `~S` deliberately: written as a plain string, the `\;` is an unrecognised
  # escape that collapses to a bare `;`, and the terminator silently stops
  # matching the token `find` actually receives.
  @find_exec_terminators [";", ~S(\;), "+"]

  # Commands on the read-only list that one of their own flags makes write a
  # file or run a program, as {short letters that write, short letters that take
  # a value, long names that write}. A value letter ends its cluster, as getopt
  # reads it: `sort -to` sets the separator to `o` and writes nothing. A long
  # name counts at any prefix, because getopt accepts `sort --out=x`; a prefix
  # it would call ambiguous is denied, which costs nothing since getopt refuses
  # to run it either. `tree` takes no value letters because it reads its values
  # from the next word, so every letter of a cluster is its own flag.
  @writing_flags %{
    "sort" => {"o", "ktST", ~w(output compress-program)},
    "yq" => {"is", "opI", ~w(inplace in-place split-exp)},
    "file" => {"C", "eFfmP", ~w(compile)},
    "tree" => {"oR", "", []},
    "rg" => {"", "", ~w(pre hostname-bin)},
    "ag" => {"", "", ~w(pager)},
    "man" => {"PH", "CEeLMmpRrSsT", ~w(pager html)}
  }

  # `less` without a terminal copies its input like `cat` and writes no log,
  # but whether a terminal is there is the environment's choice, not the
  # command's — so a log file or a start-up command is denied either way.
  @less_commands ~w(less more)
  @less_flags {"oO", "bhjkpPtTxyzD#", ~w(log-file LOG-FILE)}

  @xmllint_writing ~w(-o -output --output -shell --shell)

  # A second operand to `uniq` or `xxd` is the file it writes. Counting operands
  # means stepping over each flag's value, and only these are known to take one.
  # A flag missing from a list has its value counted as an operand, so a gap
  # here denies a read rather than allowing a write.
  @uniq_values ~w(-f -s -w --skip-fields --skip-chars --check-chars)
  @xxd_values ~w(-c -cols -g -groupsize -l -len -n -name -o -offset -s -seek -R)
  @date_values ~w(-d -f -r -v -z --date --file --reference)

  # `fd` runs everything after `-x` up to a `;`, like `find -exec`.
  @fd_exec_flags ~w(-x --exec -X --exec-batch)
  @fd_exec_terminators [";", ~S(\;)]

  # `-O` runs its value as a pager over the matching files. Only `git grep`
  # reads it that way: to `git diff` and `git log` it names an order file.
  @git_runners %{
    "grep" => {"O", "efABCm", ~w(open-files-in-pager)},
    "ls-remote" => {"", "", ~w(upload-pack)}
  }
  @git_reflog_writers ~w(expire delete drop)

  # Variables a command on the read-only list reads to find a program to run:
  # git's external diff and config, a pager, `less`'s input filter, ripgrep's
  # config file (which can set `--pre`).
  @program_variables ~r/^(GIT_|LESS|[A-Za-z_]*PAGER=|RIPGREP_CONFIG_PATH=)/

  @awk_commands ~w(awk gawk mawk)

  # An `awk` program is a program: it can redirect with `>` or shell out with
  # `system()`. Those live inside a quoted argument, where the mask deliberately
  # hides them from the redirect check, so they are looked for here instead.
  @awk_writes [~r/>/, ~r/\bsystem\s*\(/, ~r/\bprint[a-z]*\s*\|/]

  # A command built at runtime cannot be read at all. Judged against a mask that
  # keeps double-quoted content visible, since `"$(…)"` still substitutes while
  # `'$(…)'` is literal. A process substitution `<(…)` runs a command too.
  @substitution ~r/\$\(|<\(|`/

  # A `>` that is not followed by `&` writes to a file. `2>&1` and `1>&2`
  # duplicate a descriptor and create nothing.
  @writing_redirect ~r/>(?!&)/

  # The operators that end one command and begin another. An `&` preceded by `>`
  # is part of a descriptor duplication, not a separator.
  @separators ~r/;|\n|&&|\|\||\||(?<!>)&/

  @doc """
  Does this command change anything on disk?

  Returns `true` when it does, and also when the command cannot be read with
  confidence.
  """
  @spec mutating?(String.t()) :: boolean()
  def mutating?(command) when is_binary(command) do
    trimmed = String.trim(command)

    cond do
      trimmed == "" -> false
      Regex.match?(@substitution, mask(trimmed, :keep_double)) -> true
      Regex.match?(@writing_redirect, mask(trimmed, :mask_double)) -> true
      true -> trimmed |> segments() |> Enum.any?(&segment_mutates?/1)
    end
  end

  @doc """
  The paths a command names, as written.

  Used together with `mutating?/1` to decide whether a command reaches somewhere
  it should not. Relative paths come back relative; resolving them is the
  caller's job, since only the caller knows the working directory.
  """
  @spec paths(String.t()) :: [String.t()]
  def paths(command) when is_binary(command) do
    command
    |> words()
    |> Enum.map(&strip_operand_prefix/1)
    |> Enum.filter(&path_like?/1)
    |> Enum.uniq()
  end

  @doc """
  The separate commands a command line runs, split on `;`, `&&`, `||`, `|`,
  `&` and newlines that sit outside quotes.
  """
  @spec segments(String.t()) :: [String.t()]
  def segments(command) when is_binary(command) do
    command
    |> split_on_unquoted(@separators)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  # Locate separators in the masked copy, then slice the *original* at those
  # offsets. The mask is byte-for-byte the same length, so the offsets line up.
  defp split_on_unquoted(command, regex) do
    masked = mask(command, :mask_double)

    {parts, pos} =
      regex
      |> Regex.scan(masked, return: :index)
      |> Enum.reduce({[], 0}, fn [{start, len}], {acc, pos} ->
        {[binary_part(command, pos, start - pos) | acc], start + len}
      end)

    Enum.reverse([binary_part(command, pos, byte_size(command) - pos) | parts])
  end

  @doc "A command's words, split on whitespace, with one layer of quotes removed."
  @spec words(String.t()) :: [String.t()]
  def words(command) when is_binary(command) do
    command |> tokenize() |> Enum.map(&unquote_token/1)
  end

  # A subshell's parentheses sit on its first and last segments, glued to a
  # word: `(cd lib` and `git log)` are `cd lib` and `git log`.
  defp segment_mutates?(segment) do
    segment
    |> String.trim_leading("(")
    |> String.trim_trailing(")")
    |> words()
    |> tokens_mutate?()
  end

  defp tokens_mutate?(tokens) do
    {assignments, command} = Enum.split_while(tokens, &assignment?/1)

    if Enum.any?(assignments, &Regex.match?(@program_variables, &1)) do
      true
    else
      command_tokens_mutate?(command)
    end
  end

  defp command_tokens_mutate?([]), do: false

  defp command_tokens_mutate?([head | rest]) do
    case Path.basename(head) do
      "env" -> env_mutates?(rest)
      "command" -> command_mutates?(rest)
      "arch" -> arch_mutates?(rest)
      "git" -> git_mutates?(rest)
      "sed" -> Enum.any?(rest, &(&1 in ["-i", "--in-place"] or &1 =~ ~r/^-i/))
      "find" -> find_mutates?(rest)
      "fd" -> fd_mutates?(rest)
      "uniq" -> length(operands(rest, @uniq_values)) > 1
      "xxd" -> length(operands(rest, @xxd_values)) > 1
      "date" -> date_mutates?(rest)
      "hostname" -> writing_flag?(rest, {"F", "", ~w(file)}) or operands(rest, []) != []
      "xmllint" -> Enum.any?(rest, &(&1 in @xmllint_writing))
      less when less in @less_commands -> less_mutates?(rest)
      awk when awk in @awk_commands -> awk_mutates?(rest)
      other when is_map_key(@writing_flags, other) -> writing_flag?(rest, @writing_flags[other])
      other -> other not in @read_only
    end
  end

  defp writing_flag?(args, {letters, value_letters, names}) do
    args
    |> Enum.take_while(&(&1 != "--"))
    |> Enum.any?(&(short_flag(&1, letters, value_letters) != nil or long_flag?(&1, names)))
  end

  # The rest of the cluster after the first of `letters`, or nil when none of
  # them is set before a letter that takes the remainder as its value.
  defp short_flag("--" <> _, _letters, _value_letters), do: nil

  defp short_flag("-" <> cluster, letters, value_letters) do
    cluster
    |> String.graphemes()
    |> Enum.with_index()
    |> Enum.reduce_while(nil, fn {letter, index}, nil ->
      cond do
        String.contains?(letters, letter) -> {:halt, String.slice(cluster, (index + 1)..-1//1)}
        String.contains?(value_letters, letter) -> {:halt, nil}
        true -> {:cont, nil}
      end
    end)
  end

  defp short_flag(_token, _letters, _value_letters), do: nil

  defp long_flag?("--" <> flag, names) do
    [name | _value] = String.split(flag, "=", parts: 2)
    name != "" and Enum.any?(names, &String.starts_with?(&1, name))
  end

  defp long_flag?(_token, _names), do: false

  # Everything that is neither a flag nor a flag's value. A lone `-` names
  # standard input and is an operand; after `--` every word is one.
  defp operands(args, value_flags) do
    {flags, rest} = Enum.split_while(args, &(&1 != "--"))
    operands_before_dashes(flags, value_flags) ++ Enum.drop(rest, 1)
  end

  defp operands_before_dashes([], _value_flags), do: []

  defp operands_before_dashes([token | rest], value_flags) do
    cond do
      token in value_flags ->
        operands_before_dashes(Enum.drop(rest, 1), value_flags)

      token != "-" and String.starts_with?(token, "-") ->
        operands_before_dashes(rest, value_flags)

      true ->
        [token | operands_before_dashes(rest, value_flags)]
    end
  end

  # `date` sets the clock from an operand that is not a `+format`, unless `-j`
  # says not to.
  defp date_mutates?(args) do
    writing_flag?(args, {"s", "dfrvzI", ~w(set)}) or
      (not writing_flag?(args, {"j", "dfrvzI", []}) and
         Enum.any?(operands(args, @date_values), &(not String.starts_with?(&1, "+"))))
  end

  defp less_mutates?(args) do
    writing_flag?(args, @less_flags) or Enum.any?(args, &String.starts_with?(&1, "+"))
  end

  # `arch` alone prints the architecture; followed by a command it runs it. `-e`
  # sets a variable for that command, which is denied rather than judged.
  defp arch_mutates?([]), do: false
  defp arch_mutates?(["-e" | _rest]), do: true
  defp arch_mutates?([flag, _value | rest]) when flag in ["-arch", "-d"], do: arch_mutates?(rest)
  defp arch_mutates?(["-" <> _ | rest]), do: arch_mutates?(rest)
  defp arch_mutates?(command), do: tokens_mutate?(command)

  defp fd_mutates?(args) do
    case Enum.split_while(args, &(fd_exec(&1) == nil)) do
      {_args, []} ->
        false

      {_args, [flag | rest]} ->
        {command, tail} = Enum.split_while(rest, &(&1 not in @fd_exec_terminators))
        exec_mutates?(fd_exec(flag) ++ command) or fd_mutates?(Enum.drop(tail, 1))
    end
  end

  # The words of the command an exec flag carries inside itself, `[]` when the
  # command follows as separate words, or nil when the token is no exec flag.
  defp fd_exec(token) when token in @fd_exec_flags, do: []
  defp fd_exec("--exec=" <> command), do: [command]
  defp fd_exec("--exec-batch=" <> command), do: [command]

  defp fd_exec(token) do
    case short_flag(token, "xX", "dEetcjSo") do
      nil -> nil
      "" -> []
      command -> [command]
    end
  end

  # `git`'s global flags come before the subcommand, and `-C` takes an argument
  # that must be stepped over as well — otherwise the directory gets mistaken
  # for the subcommand. `-c` and `--config-env` set config, and config can name
  # a program that even a read-only subcommand runs: `diff.external` for
  # `git diff`, `core.fsmonitor` for `git status`.
  defp git_mutates?(["-C", _dir | rest]), do: git_mutates?(rest)
  defp git_mutates?(["-c" | _rest]), do: true
  defp git_mutates?(["--config-env" <> _ | _rest]), do: true

  defp git_mutates?([flag | rest]) when is_binary(flag) do
    if String.starts_with?(flag, "-") do
      git_mutates?(rest)
    else
      git_subcommand_mutates?(flag, rest)
    end
  end

  defp git_mutates?([]), do: true

  defp git_subcommand_mutates?(subcommand, args) do
    subcommand not in @read_only_git or
      writing_flag?(args, {"", "", ~w(output)}) or
      writing_flag?(args, Map.get(@git_runners, subcommand, {"", "", []})) or
      (subcommand == "reflog" and
         Enum.find(args, &(not String.starts_with?(&1, "-"))) in @git_reflog_writers)
  end

  defp find_mutates?(args) do
    Enum.any?(args, &(&1 in @find_writing_actions)) or find_exec_mutates?(args)
  end

  defp find_exec_mutates?(args) do
    case Enum.drop_while(args, &(&1 not in @find_exec_actions)) do
      [] ->
        false

      [_action | rest] ->
        {command, tail} = Enum.split_while(rest, &(&1 not in @find_exec_terminators))
        exec_mutates?(command) or find_exec_mutates?(Enum.drop(tail, 1))
    end
  end

  defp exec_mutates?([]), do: true
  defp exec_mutates?(command), do: tokens_mutate?(command)

  # `env` alone prints the environment; followed by a command it runs it, and
  # that command is the one to judge (ADR-0069). Its own flags are stepped over
  # where they are plain; one it cannot read — `-S` splits a string into a
  # command line of its own — is assumed to run something.
  defp env_mutates?([flag | rest])
       when flag in ["-i", "-", "--ignore-environment", "-0", "--null"],
       do: env_mutates?(rest)

  defp env_mutates?([flag, _name | rest]) when flag in ["-u", "--unset", "-C", "--chdir"],
    do: env_mutates?(rest)

  defp env_mutates?(["-" <> _ | _rest]), do: true
  defp env_mutates?(rest), do: tokens_mutate?(rest)

  # `command -v` and `-V` only say where a command lives; anything else runs it.
  defp command_mutates?([flag | _rest]) when flag in ["-v", "-V"], do: false
  defp command_mutates?(["-p" | rest]), do: command_mutates?(rest)
  defp command_mutates?(rest), do: tokens_mutate?(rest)

  defp awk_mutates?(args) do
    Enum.any?(args, fn arg -> Enum.any?(@awk_writes, &Regex.match?(&1, arg)) end)
  end

  defp assignment?(token), do: Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_]*=/, token)

  # Split on whitespace, but keep quoted runs together so a path with a space in
  # it survives as one token.
  defp tokenize(string) do
    ~r/"[^"]*"|'[^']*'|\S+/
    |> Regex.scan(string)
    |> Enum.map(fn [token] -> token end)
  end

  defp unquote_token(token) do
    cond do
      String.starts_with?(token, "\"") and String.ends_with?(token, "\"") ->
        String.slice(token, 1..-2//1)

      String.starts_with?(token, "'") and String.ends_with?(token, "'") ->
        String.slice(token, 1..-2//1)

      true ->
        token
    end
  end

  # A path can be glued to what introduces it: a redirect (`>out`, `2>out`,
  # `&>out`, `>|out`) or a `name=` operand (`of=out`, `--output=out`).
  @operand_prefix ~r/^(?:\d*&?[<>]+[|&]?|-{0,2}[A-Za-z_][A-Za-z0-9_-]*=)/

  defp strip_operand_prefix(token), do: String.replace(token, @operand_prefix, "")

  defp path_like?(token) do
    cond do
      token == "" -> false
      String.starts_with?(token, "-") -> false
      String.contains?(token, "/") -> true
      String.starts_with?(token, ".") -> true
      true -> false
    end
  end

  # Replace the contents of quoted spans, and any backslash-escaped character,
  # with filler of identical byte length. `:keep_double` leaves double-quoted
  # content visible, because a substitution still runs inside double quotes.
  defp mask(command, double) do
    command
    |> String.graphemes()
    |> mask_graphemes(:outside, double, [])
    |> Enum.reverse()
    |> IO.iodata_to_binary()
  end

  defp mask_graphemes([], _state, _double, acc), do: acc

  defp mask_graphemes(["\\", char | rest], state, double, acc) when state != :single,
    do: mask_graphemes(rest, state, double, [filler(char), filler("\\") | acc])

  defp mask_graphemes(["\\"], state, double, acc) when state != :single,
    do: mask_graphemes([], state, double, [filler("\\") | acc])

  defp mask_graphemes(["'" | rest], :outside, double, acc),
    do: mask_graphemes(rest, :single, double, ["'" | acc])

  defp mask_graphemes(["'" | rest], :single, double, acc),
    do: mask_graphemes(rest, :outside, double, ["'" | acc])

  defp mask_graphemes(["\"" | rest], :outside, double, acc),
    do: mask_graphemes(rest, :double, double, ["\"" | acc])

  defp mask_graphemes(["\"" | rest], :double, double, acc),
    do: mask_graphemes(rest, :outside, double, ["\"" | acc])

  defp mask_graphemes([char | rest], :single, double, acc),
    do: mask_graphemes(rest, :single, double, [filler(char) | acc])

  defp mask_graphemes([char | rest], :double, :mask_double, acc),
    do: mask_graphemes(rest, :double, :mask_double, [filler(char) | acc])

  defp mask_graphemes([char | rest], :double, :keep_double, acc),
    do: mask_graphemes(rest, :double, :keep_double, [char | acc])

  defp mask_graphemes([char | rest], :outside, double, acc),
    do: mask_graphemes(rest, :outside, double, [char | acc])

  defp filler(grapheme), do: String.duplicate("x", byte_size(grapheme))
end
