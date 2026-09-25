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

  @awk_commands ~w(awk gawk mawk)

  # An `awk` program is a program: it can redirect with `>` or shell out with
  # `system()`. Those live inside a quoted argument, where the mask deliberately
  # hides them from the redirect check, so they are looked for here instead.
  @awk_writes [~r/>/, ~r/\bsystem\s*\(/, ~r/\bprint[a-z]*\s*\|/]

  # A command built at runtime cannot be read at all. Judged against a mask that
  # keeps double-quoted content visible, since `"$(…)"` still substitutes while
  # `'$(…)'` is literal.
  @substitution ~r/\$\(|`/

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
    |> tokenize()
    |> Enum.map(&unquote_token/1)
    |> Enum.filter(&path_like?/1)
    |> Enum.uniq()
  end

  defp segments(command) do
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

  defp segment_mutates?(segment) do
    case segment |> tokenize() |> Enum.map(&unquote_token/1) |> drop_env_assignments() do
      [] ->
        false

      [head | rest] ->
        case Path.basename(head) do
          "git" -> git_mutates?(rest)
          "sed" -> Enum.any?(rest, &(&1 in ["-i", "--in-place"] or &1 =~ ~r/^-i/))
          "find" -> find_mutates?(rest)
          awk when awk in @awk_commands -> awk_mutates?(rest)
          other -> other not in @read_only
        end
    end
  end

  # `git`'s global flags come before the subcommand, and two of them take an
  # argument that must be stepped over as well — otherwise the argument itself
  # (a directory, for `-C`) gets mistaken for the subcommand.
  defp git_mutates?(["-C", _dir | rest]), do: git_mutates?(rest)
  defp git_mutates?(["-c", _config | rest]), do: git_mutates?(rest)

  defp git_mutates?([flag | rest]) when is_binary(flag) do
    if String.starts_with?(flag, "-") do
      git_mutates?(rest)
    else
      flag not in @read_only_git
    end
  end

  defp git_mutates?([]), do: true

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
  defp exec_mutates?([head | _]), do: Path.basename(head) not in @read_only

  defp awk_mutates?(args) do
    Enum.any?(args, fn arg -> Enum.any?(@awk_writes, &Regex.match?(&1, arg)) end)
  end

  defp drop_env_assignments(tokens) do
    Enum.drop_while(tokens, &Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_]*=/, &1))
  end

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

  # A redirect can be written `>out.txt` with no space, so strip any leading
  # redirect operator before judging the token.
  defp path_like?(token) do
    token = String.replace_leading(token, ">", "") |> String.replace_leading("<", "")

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
