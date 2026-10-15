defmodule Whiska.DenyList do
  @moduledoc """
  What a mouse may not do, as Claude Code's own deny rules, in a settings file it
  is started with (ADR-0090).

  A mouse starts in bypass mode, so nothing prompts and no classifier judges its
  calls; deny rules still hold there. Every mouse is denied the person's
  commands (ADR-0079). A sniff mouse is also denied the file tools by bare name,
  which takes them out of its session altogether (ADR-0069).

  The rules match a command as it is written: `whiska hold x` and `hold x`, in a
  compound command, a subshell or a substitution too. `env`, `exec`, a full
  path, `bash -c` or a nested `claude -p` get round them, and that is accepted:
  they catch the honest case, which is all a text rule can (ADR-0024).

  The file is written to `.whiska-settings.json` at the worktree root, which git
  ignores like the brief, and rewritten on every shape.
  """

  @filename ".whiska-settings.json"

  @persons ~w(away hold focus resume reply dismiss close)
  @main_sessions ~w(spawn send tell land pr push merge-request drop)
  @file_tools ~w(Edit Write NotebookEdit)

  @spec filename() :: String.t()
  def filename, do: @filename

  @spec exclude_line() :: String.t()
  def exclude_line, do: "/" <> @filename

  @doc """
  The deny rules for a mouse in `mode`. The person's commands are denied as
  `whiska <word>`, and the one-word ones bare too; `spawn`, `send`, `tell`, `land`,
  `pr`, `push`, `merge-request` and `drop` only with `whiska` in front, since `pr`,
  `push` and `send` are other programs or words too. A trailing ` *` also matches the bare command.
  """
  @spec rules(String.t()) :: [String.t()]
  def rules("sniff"), do: persons() ++ @file_tools
  def rules("build"), do: persons()

  defp persons do
    Enum.map(@persons ++ @main_sessions, &"Bash(whiska #{&1} *)") ++
      Enum.map(@persons, &"Bash(#{&1} *)")
  end

  @doc "The settings file for a mouse in `mode`: its deny list and nothing else."
  @spec render(String.t()) :: String.t()
  def render(mode) do
    deny = Enum.map_join(rules(mode), ",\n", &("      " <> JSON.encode!(&1)))
    ~s|{\n  "permissions": {\n    "deny": [\n#{deny}\n    ]\n  }\n}\n|
  end

  @doc "The flags that start Claude Code in bypass mode with the file at `path`."
  @spec claude_args(Path.t()) :: [String.t()]
  def claude_args(path \\ @filename),
    do: ["--dangerously-skip-permissions", "--settings", path]

  @doc """
  Write a mouse's deny list into `worktree`. Git is told to ignore it first;
  that failing is said, as for the brief, and the file is written all the same.
  Anything but a plain file at the path is refused.
  """
  @spec write(Path.t(), Path.t(), String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def write(main_checkout, worktree, mode) do
    said =
      case Whiska.Spec.ignore(main_checkout, exclude_line()) do
        :ok ->
          []

        {:error, reason} ->
          ["whiska: could not make git ignore #{@filename} (#{inspect(reason)})."]
      end

    path = Path.join(worktree, @filename)

    with :ok <- plain_or_absent(path),
         :ok <- File.write(path, render(mode)),
         do: {:ok, said}
  end

  # A worktree holds whatever the repo committed, a link included, and a write
  # through one would land in whatever it points at.
  defp plain_or_absent(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} -> :ok
      {:ok, %File.Stat{}} -> {:error, :not_a_plain_file}
      {:error, :enoent} -> :ok
      {:error, _} = error -> error
    end
  end
end
