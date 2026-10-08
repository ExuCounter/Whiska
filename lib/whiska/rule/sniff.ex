defmodule Whiska.Rule.Sniff do
  @moduledoc """
  A sniff mouse investigates and reports; it never writes code.

  ADR-0069 defines the two modes. **build** produces a real change — its edits
  are confined to its own worktree by `Whiska.Rule.MainCheckout`. **sniff** is
  investigation only, and `PreToolUse` blocks *all* edits, not just ones outside
  the worktree. A mouse nobody shaped is held to the same rule until the person
  chooses a mode (ADR-0069).

  That "all" is the whole point, and it is why this rule needs no `Whiska.Layout`:
  where the edit points is irrelevant. The only questions are what mode the mouse
  is in and whether the tool changes anything.

  For `Bash`, "changes anything" is `Whiska.Shell`'s judgment, which errs towards
  mutating whenever it cannot read a command confidently. A sniff mouse denied a
  harmless command can reach for `Read` or `Grep`; a sniff mouse that slipped one
  mutation through is not a sniff mouse.
  """

  alias Whiska.Shell

  @edit_tools ~w(Write Edit MultiEdit NotebookEdit)

  @type decision :: :allow | {:deny, String.t()}

  @doc "Decide one tool call for a mouse in `mode`."
  @spec decide(String.t(), map(), String.t()) :: decision()
  def decide(tool_name, tool_input, mode)

  # A mouse nobody shaped is held to sniff until somebody chooses (ADR-0069):
  # a skipped spawn step is far more often a sniff mouse with write access than
  # a build mouse kept waiting, and the wait ends with one command.
  @read_only ~w(sniff unshaped)

  # Every other mode — build today — is somebody else's rule.
  def decide(_tool_name, _tool_input, mode) when mode not in @read_only, do: :allow

  def decide(tool_name, _tool_input, mode) when tool_name in @edit_tools do
    {:deny, reason(mode, "#{tool_name} writes to disk")}
  end

  def decide("Bash", tool_input, mode) do
    command = Map.get(tool_input, "command", "")

    if Shell.mutating?(command) do
      {:deny, reason(mode, "this command can change files on disk")}
    else
      :allow
    end
  end

  def decide(_tool_name, _tool_input, _mode), do: :allow

  defp reason("unshaped", what) do
    """
    Whiska denied this: #{what}, and this mouse was never given a shape.

    A spawn gives every mouse its mode before Claude starts (ADR-0069). This one
    has none, so it may read but not write — Read, Grep, Glob and read-only
    shell commands all work. Do not try to change this yourself: stop and ask
    the person which it should be. They run `whiska mode build` or
    `whiska mode sniff` in this worktree.
    """
    |> String.trim()
  end

  defp reason("sniff", what) do
    """
    Whiska denied this: #{what}, and this mouse is in sniff mode.

    A sniff mouse investigates and reports — it never writes code, anywhere,
    including inside its own worktree (ADR-0069). Reading tools are unaffected:
    Read, Grep and Glob all work, as do read-only shell commands like
    `git log`, `git diff` and `grep`.

    If the work needs a change, do not make it and do not ask to switch modes.
    Finish the investigation, and end the report on the finished marker with a
    **Proposed build** block — Found, Build, Touches — as the `whiska-finish`
    skill describes. The person can then hand it to a fresh session shaped for
    the build.
    """
    |> String.trim()
  end
end
