defmodule Whiska.Rule.Sniff do
  @moduledoc """
  A sniff mouse investigates and reports; it never writes code.

  ADR-0018 defines the two modes. **build** produces a real change and is the
  default — its edits are confined to its own worktree by `Whiska.Rule.MainCheckout`.
  **sniff** is investigation only, and `PreToolUse` blocks *all* edits, not just
  ones outside the worktree.

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

  # Every mode other than sniff — build today — is somebody else's rule.
  def decide(_tool_name, _tool_input, mode) when mode != "sniff", do: :allow

  def decide(tool_name, _tool_input, "sniff") when tool_name in @edit_tools do
    {:deny, reason("#{tool_name} writes to disk")}
  end

  def decide("Bash", tool_input, "sniff") do
    command = Map.get(tool_input, "command", "")

    if Shell.mutating?(command) do
      {:deny, reason("this command can change files on disk")}
    else
      :allow
    end
  end

  def decide(_tool_name, _tool_input, "sniff"), do: :allow

  defp reason(what) do
    """
    Whiska denied this: #{what}, and this mouse is in sniff mode.

    A sniff mouse investigates and reports — it never writes code, anywhere,
    including inside its own worktree (ADR-0018). Reading tools are unaffected:
    Read, Grep and Glob all work, as do read-only shell commands like
    `git log`, `git diff` and `grep`.

    If this mouse is genuinely meant to be making changes, switch it with
    `whiska mode build` and try again.
    """
    |> String.trim()
  end
end
