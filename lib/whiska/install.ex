defmodule Whiska.Install do
  @moduledoc """
  Writing Whiska's hook into a repo's own `.claude/settings.json`.

  ADR-0016 makes hooks per-project rather than global, and the file is checked
  into git so the rules travel with the repo: anyone who clones it and has Whiska
  installed gets the same enforcement automatically. Global hooks would mean zero
  setup per project but would not travel, which is the wrong trade for rules that
  exist to contain what a worker can do.

  ## Nothing machine-specific reaches settings.json

  "The rules travel with the repo" is only true if what gets committed works on
  somebody else's machine. An earlier version wrote two absolute paths into the
  hook command — the Erlang runtime and the binary, both resolved at install
  time — which pinned the file to one home directory and one Erlang version, and
  leaked a username into a shared repo besides. It also broke as soon as the
  runtime was upgraded.

  So the committed command names only a **shim** checked in beside it, and every
  machine-specific lookup moved into that shim, where it happens at run time.
  `WHISKA_BIN` and `WHISKA_ESCRIPT` override the lookups without editing it.

  The shim costs one extra process — about 5 ms. That was rejected when this was
  written, on the grounds that a shell wrapper costs more than ADR-0033's
  eventual native hook will cost in total. True, but the hook that exists today
  is an Elixir escript measured at ~124 ms per call, so the wrapper is about 4%
  of it. The cost lands on the version of the hook that can afford it, and the
  indirection means `settings.json` never has to change again when ADR-0033's
  native binary replaces what the shim points at.

  Everything here is a pure value except the actual write, so the merge behaviour
  — idempotency, leaving other people's hooks alone — is testable without
  touching a filesystem.
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

  @shim_path ".claude/hooks/whiska.sh"

  # The shim takes the hook's name as its argument, so one committed script
  # serves every hook Whiska registers.
  @command ~s|bash "$CLAUDE_PROJECT_DIR/#{@shim_path}" pre-tool-use|
  @stop_command ~s|bash "$CLAUDE_PROJECT_DIR/#{@shim_path}" stop|

  @shim_header """
  #!/usr/bin/env bash
  # Whiska's hooks. Takes the hook's name - pre-tool-use or stop - and hands
  # the payload on stdin to `whiska hook <name>`.
  #
  # Written by `whiska init` and checked into the repo so the rules travel with
  # it (ADR-0016). Everything machine-specific is resolved here, when the hook
  # runs, rather than baked into .claude/settings.json where it would name one
  # developer's home directory and one Erlang version.
  #
  # A hook does not necessarily inherit an interactive shell's PATH, so every
  # lookup ends by searching the filesystem directly rather than trusting it.
  # WHISKA_BIN and WHISKA_ESCRIPT override either, and are ignored if they do
  # not point at something runnable.

  """

  # Finding the binary and the runtime is written once and shared with the
  # statusline script below, so the two never drift apart.
  @resolve_whiska """
  whiska_bin="${WHISKA_BIN:-}"
  if [ -n "$whiska_bin" ] && [ ! -x "$whiska_bin" ]; then
    whiska_bin=""
  fi
  if [ -z "$whiska_bin" ]; then
    whiska_bin="$(command -v whiska 2>/dev/null)" || whiska_bin=""
  fi
  if [ -z "$whiska_bin" ] && [ -x "$HOME/.local/bin/whiska" ]; then
    whiska_bin="$HOME/.local/bin/whiska"
  fi

  """

  @shim_fail_open """
  # Fail open, loudly. A missing Whiska must never brick every tool call in a
  # session - the same trade Whiska.Hook.PreToolUse makes on a bad payload.
  if [ -z "$whiska_bin" ]; then
    echo "whiska: not found - allowing the call (set WHISKA_BIN to fix)" >&2
    exit 0
  fi

  """

  @resolve_escript """
  # An escript begins `#!/usr/bin/env escript`, so it only runs when escript is
  # on PATH. With a version manager in play it is not found at all - and asking
  # the version manager does not help when it is off PATH too, which is exactly
  # the case a hook lands in. So the last resort reads its install directory.
  escript_bin="${WHISKA_ESCRIPT:-}"
  if [ -n "$escript_bin" ] && [ ! -x "$escript_bin" ]; then
    escript_bin=""
  fi
  if [ -z "$escript_bin" ]; then
    escript_bin="$(command -v escript 2>/dev/null)" || escript_bin=""
  fi
  if [ -z "$escript_bin" ] && command -v asdf >/dev/null 2>&1; then
    escript_bin="$(asdf which escript 2>/dev/null)" || escript_bin=""
  fi
  if [ -z "$escript_bin" ]; then
    escript_bin="$(ls -1 "${ASDF_DATA_DIR:-$HOME/.asdf}"/installs/erlang/*/bin/escript \
      2>/dev/null | sort -V | tail -1)"
  fi
  if [ -z "$escript_bin" ]; then
    for candidate in /opt/homebrew/bin/escript /usr/local/bin/escript; do
      if [ -x "$candidate" ]; then
        escript_bin="$candidate"
        break
      fi
    done
  fi

  """

  @shim_exec """
  if [ -n "$escript_bin" ]; then
    exec "$escript_bin" "$whiska_bin" hook "$@"
  fi

  # No runtime anywhere. Whiska may be a native binary that needs none
  # (ADR-0033), so try it directly - and fail open if that does not work.
  if ! "$whiska_bin" hook "$@"; then
    echo "whiska: could not run $whiska_bin - allowing the call" >&2
  fi
  exit 0
  """

  @shim @shim_header <> @resolve_whiska <> @shim_fail_open <> @resolve_escript <> @shim_exec

  @statusline_path ".claude/hooks/whiska-statusline.sh"

  # Claude Code does not set CLAUDE_PROJECT_DIR for the statusline command, only
  # for hooks; the command runs from the project directory, so the relative path
  # is the fallback, and the variable is honoured if a later version sets it.
  @statusline_command ~s|bash "${CLAUDE_PROJECT_DIR:-.}/#{@statusline_path}"|

  @statusline_script """
                     #!/usr/bin/env bash
                     # Whiska's project statusline (ADR-0027). A project-level statusLine
                     # replaces the global one rather than merging with it, so this runs your
                     # global statusline first and appends one line: whether the owl is
                     # watching or down (always, so a blank line never passes for a working
                     # Whiska), how many whiskas are on this machine when there is more than
                     # one, the mice alive here, one open question in detail or a count for
                     # more, and which other whiska has something waiting. Only the owl is
                     # shown when nothing waits.
                     #
                     # Written by `whiska init`. The binary and runtime are resolved the same
                     # way the hook shim resolves them, at run time, never baked in here.

                     input="$(cat)"

                     global=""
                     if command -v jq >/dev/null 2>&1 && [ -r "$HOME/.claude/settings.json" ]; then
                       global="$(jq -r '.statusLine.command // empty' "$HOME/.claude/settings.json" 2>/dev/null)"
                     fi

                     base=""
                     case "$global" in
                       "" | *whiska-statusline.sh*) ;;
                       *) base="$(printf '%s' "$input" | bash -c "$global" 2>/dev/null)" ;;
                     esac

                     dir=""
                     if command -v jq >/dev/null 2>&1; then
                       dir="$(printf '%s' "$input" | jq -r '.workspace.current_dir // .workspace.project_dir // .cwd // empty' 2>/dev/null)"
                     fi
                     [ -d "$dir" ] || dir="$PWD"

                     """ <>
                       @resolve_whiska <>
                       @resolve_escript <>
                       """
                       segment=""
                       if [ -n "$whiska_bin" ] && [ -n "$escript_bin" ]; then
                         segment="$(cd "$dir" && "$escript_bin" "$whiska_bin" statusline 2>/dev/null)"
                       elif [ -n "$whiska_bin" ]; then
                         segment="$(cd "$dir" && "$whiska_bin" statusline 2>/dev/null)"
                       fi

                       if [ -n "$base" ] && [ -n "$segment" ]; then
                         printf '%s · %s' "$base" "$segment"
                       else
                         printf '%s%s' "$base" "$segment"
                       fi
                       """

  # One slash-command skill per command (ADR-0022): a thin wrapper around the
  # fixed `whiska` call, discoverable via /help, so the model never has to
  # compose the bash itself. Paths are relative to the repo root.
  @skills [
    {".claude/skills/whiska-questions/SKILL.md",
     """
     ---
     name: whiska-questions
     description: List the questions waiting on you from this repo's mice. Use when asked what is open, what is waiting, what the mice need, or on /whiska-questions.
     ---

     Run exactly this and show its output as it is:

         whiska questions

     To read one question in full, run `whiska questions <id>` with an id from the list.

     Present what it prints faithfully, then stop. Answering is the person's move —
     never reply to a question, guess an answer, or act on one on their behalf.
     """}
  ]

  @doc "The Claude Code matcher Whiska registers for."
  @spec matcher() :: String.t()
  def matcher, do: @matcher

  @doc "Where the shim lives, relative to the repo root."
  @spec shim_path() :: Path.t()
  def shim_path, do: @shim_path

  @doc """
  The hook command that goes into `settings.json`.

  Names only the shim, via `$CLAUDE_PROJECT_DIR`, so the committed file is the
  same on every machine.
  """
  @spec command() :: String.t()
  def command, do: @command

  @doc """
  The Stop hook command: the same shim, told it is a `stop`.

  This is the doorstep writer (ADR-0036). No matcher — a Stop hook has no tool
  to match on; it fires on every finished turn.
  """
  @spec stop_command() :: String.t()
  def stop_command, do: @stop_command

  @doc """
  The shim script's contents.

  Resolves the binary and the Erlang runtime when the hook fires, and allows the
  call rather than denying it when Whiska is not installed.
  """
  @spec shim() :: String.t()
  def shim, do: @shim

  @doc "Where the statusline script lives, relative to the repo root."
  @spec statusline_path() :: Path.t()
  def statusline_path, do: @statusline_path

  @doc "The statusLine command that goes into `settings.json`; names only the script."
  @spec statusline_command() :: String.t()
  def statusline_command, do: @statusline_command

  @doc "The statusline script's contents (ADR-0027)."
  @spec statusline_script() :: String.t()
  def statusline_script, do: @statusline_script

  @doc "The slash-command skills `whiska init` writes, as `{path, contents}` (ADR-0022)."
  @spec skills() :: [{Path.t(), String.t()}]
  def skills, do: @skills

  @doc """
  Merge Whiska's hook into an existing settings map.

  Idempotent, and surgical: unrelated settings, unrelated hook events, and other
  people's `PreToolUse` entries all survive untouched. A previously-installed
  Whiska entry is replaced rather than duplicated — including one written before
  the matcher was widened, and one written before the shim existed, which is why
  the entry is recognised by its command rather than by its matcher.
  """
  @spec merge(map()) :: map()
  def merge(settings) when is_map(settings) do
    pre_tool_use = %{
      "matcher" => @matcher,
      "hooks" => [%{"type" => "command", "command" => @command}]
    }

    stop = %{"hooks" => [%{"type" => "command", "command" => @stop_command}]}

    settings
    |> Map.put_new("hooks", %{})
    |> put_ours("PreToolUse", pre_tool_use)
    |> put_ours("Stop", stop)
    |> put_statusline()
  end

  # A project statusLine is a single value, not a list, so there is no "beside
  # the others" here: one that is ours, or missing, is set; one that is somebody
  # else's is left exactly alone rather than replaced.
  defp put_statusline(settings) do
    entry = %{"type" => "command", "command" => @statusline_command}

    case settings["statusLine"] do
      nil ->
        Map.put(settings, "statusLine", entry)

      %{"command" => command} when is_binary(command) ->
        if String.contains?(command, @statusline_path),
          do: Map.put(settings, "statusLine", entry),
          else: settings

      _ ->
        settings
    end
  end

  defp put_ours(settings, event, entry) do
    existing = get_in(settings, ["hooks", event]) || []
    others = Enum.reject(existing, &ours?/1)
    put_in(settings, ["hooks", event], others ++ [entry])
  end

  # Ours is whatever runs a `whiska ... hook ...`, or the shim that does it for
  # us — whatever matcher it was registered with, and whether or not the shim
  # took an argument when it was written. Matching on the matcher would fail to
  # recognise an entry written by an older version and would stack a duplicate
  # beside it.
  defp ours?(%{"hooks" => hooks}) when is_list(hooks) do
    Enum.any?(hooks, fn
      %{"command" => command} when is_binary(command) ->
        String.contains?(command, "whiska hook") or
          String.contains?(command, "hook pre-tool-use") or
          String.contains?(command, @shim_path)

      _ ->
        false
    end)
  end

  defp ours?(_), do: false
end
