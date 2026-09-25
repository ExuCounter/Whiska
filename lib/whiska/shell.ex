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
  Anything involving substitution, `eval`, or a nested shell is refused outright
  rather than guessed at.
  """

  # Commands that cannot modify the filesystem. Deliberately conservative: a
  # command missing from this list is denied, which is recoverable, whereas a
  # mutating command wrongly added to it is not.
  @read_only ~w(
    ls cat head tail wc nl tac seq echo printf pwd whoami hostname uname date
    grep egrep fgrep rg ag find fd file stat du df tree
    sort uniq cut tr column comm join paste fold
    diff cmp jq yq xmllint
    which type command basename dirname realpath readlink
    env printenv true false test man help less more
  )

  # `git` is read-only or not depending on its subcommand, and only these are
  # unambiguously read-only. Everything else — including `branch`, `tag`,
  # `stash`, `config`, `remote` and `worktree`, each of which has mutating
  # forms — is treated as mutating.
  @read_only_git ~w(
    log diff status show blame rev-parse rev-list ls-files ls-tree ls-remote
    describe shortlog whatchanged cat-file reflog grep annotate count-objects
  )

  # Constructs whose real behaviour is hidden from a non-parser: another shell,
  # a substitution, or a command built at runtime.
  @opaque_constructs [~r/\$\(/, ~r/`/, ~r/\beval\b/, ~r/\bexec\b/, ~r/\bxargs\b/]
  @nested_shells ~w(bash sh zsh fish dash ksh)

  # A `>` that is not followed by `&` writes to a file. `2>&1` and `1>&2`
  # duplicate a descriptor and create nothing.
  @writing_redirect ~r/>(?!&)/

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
      opaque?(trimmed) -> true
      Regex.match?(@writing_redirect, trimmed) -> true
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

  defp opaque?(command) do
    Enum.any?(@opaque_constructs, &Regex.match?(&1, command)) or
      Enum.any?(@nested_shells, &Regex.match?(~r/\b#{&1}\s+-[a-z]*c\b/, command))
  end

  # A file-descriptor duplication (`2>&1`, `1>&2`, `>&2`) contains an `&` that
  # would otherwise look like a command separator, leaving a stray `1` behind
  # that reads as an unknown command. Drop them before splitting.
  @fd_duplication ~r/\d*>&\d+/

  # Split on the operators that end one command and begin another.
  defp segments(command) do
    command
    |> String.replace(@fd_duplication, " ")
    |> String.split(~r/;|\n|&&|\|\||\||&/, trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp segment_mutates?(segment) do
    case segment |> tokenize() |> drop_env_assignments() do
      [] -> false
      ["git" | rest] -> git_mutates?(rest)
      ["sed" | rest] -> Enum.any?(rest, &(&1 in ["-i", "--in-place"] or &1 =~ ~r/^-i/))
      [head | _] -> Path.basename(head) not in @read_only
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
end
