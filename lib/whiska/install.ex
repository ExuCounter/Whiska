defmodule Whiska.Install do
  @moduledoc """
  Writing Whiska's hook into a repo's own `.claude/settings.json`.

  ADR-0016 makes hooks per-project rather than global, and the file is checked
  into git so the rules travel with the repo: anyone who clones it and has Whiska
  installed gets the same enforcement automatically. Global hooks would mean zero
  setup per project but would not travel, which is the wrong trade for rules that
  exist to contain what a worker can do.

  Everything here is a pure transformation of the settings map except the actual
  write, so the merge behaviour — idempotency, leaving other people's hooks
  alone — is testable without touching a filesystem.
  """

  # Every tool that a rule can actually deny, and no others.
  #
  # `Bash` earns its place: sniff mode denies mutating commands (ADR-0018) and
  # containment denies ones reaching into the main checkout (ADR-0013), so a
  # matcher without it would leave both rules silently never firing.
  #
  # `Read`, `Grep` and `Glob` are deliberately absent. They are a large share of
  # all tool calls and can never be denied, and ADR-0033 is blunt about it: not
  # running at all beats running fast.
  @matcher "Write|Edit|MultiEdit|NotebookEdit|Bash"

  @doc "The Claude Code matcher Whiska registers for."
  @spec matcher() :: String.t()
  def matcher, do: @matcher

  @doc """
  The hook command for a `whiska` binary at `path`.

  Both the Erlang runtime and the binary are named absolutely, on purpose. A
  `mix escript.build` binary begins `#!/usr/bin/env escript`, so it only runs
  when `escript` is findable on `PATH` — and a hook does not necessarily inherit
  an interactive shell's `PATH`. With a version manager in play it is not found
  at all. `:code.root_dir/0` reports the runtime this very process is running on,
  so the path is exact rather than guessed, and it sidesteps the version
  manager's shim (itself a shell script) into the bargain.

  No `bash -c` wrapper: spawning a shell to spawn the real thing costs about
  4 ms, more than twice what ADR-0033's eventual native hook will cost in total.
  """
  @spec command(Path.t()) :: String.t()
  def command(whiska_path), do: "#{escript_path()} #{whiska_path} hook pre-tool-use"

  @doc "The `escript` belonging to the runtime this process is running on."
  @spec escript_path() :: Path.t()
  def escript_path, do: Path.join([to_string(:code.root_dir()), "bin", "escript"])

  @doc """
  Merge Whiska's hook into an existing settings map.

  Idempotent, and surgical: unrelated settings, unrelated hook events, and other
  people's `PreToolUse` entries all survive untouched. A previously-installed
  Whiska entry is replaced rather than duplicated — including one written before
  the matcher was widened, which is why the entry is recognised by its command
  rather than by its matcher.
  """
  @spec merge(map(), Path.t()) :: map()
  def merge(settings, whiska_path) when is_map(settings) do
    entry = %{
      "matcher" => @matcher,
      "hooks" => [%{"type" => "command", "command" => command(whiska_path)}]
    }

    existing = get_in(settings, ["hooks", "PreToolUse"]) || []
    others = Enum.reject(existing, &ours?/1)

    settings
    |> Map.put_new("hooks", %{})
    |> put_in(["hooks", "PreToolUse"], others ++ [entry])
  end

  # Ours is whatever runs a `whiska ... hook pre-tool-use`, whatever matcher it
  # was registered with. Matching on the matcher would fail to recognise an
  # entry written by an older version and would stack a duplicate beside it.
  defp ours?(%{"hooks" => hooks}) when is_list(hooks) do
    Enum.any?(hooks, fn
      %{"command" => command} when is_binary(command) ->
        String.contains?(command, "hook pre-tool-use")

      _ ->
        false
    end)
  end

  defp ours?(_), do: false
end
