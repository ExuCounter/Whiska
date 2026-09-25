defmodule Whiska.Rule.MainCheckout do
  @moduledoc """
  The one rule v0.0.1 enforces: a mouse may not edit the main checkout.

  ADR-0013 is the why. Every other protection in this design — worktree
  containment, `checks.yml`, diff review, push approval — only covers a mouse's
  own worktree. An edit made directly in the main checkout skips all of it. So the
  rule is mechanical (ADR-0010): a `PreToolUse` hook that can actually block,
  rather than a line in `CLAUDE.md` that a mouse may or may not follow.

  ## What is policed

  Only tools that hand the hook a literal target path: `Write`, `Edit`,
  `MultiEdit` (`file_path`) and `NotebookEdit` (`notebook_path`). Resolving those
  is exact, so the rule never produces a false denial.

  ## Bash

  `Bash` is policed too, but only when a command is **both** mutating and names a
  path resolving into the main checkout. Gating on mutation is what makes this
  tolerable: `cat <main>/CONTEXT.md` and `grep -r <main>` stay allowed, while
  `sed -i`, a redirect, and `git -C <main> commit` do not. A plain substring
  match on the main-checkout path would have denied the reads too, which is the
  kind of false denial that trains people to ignore a hook.

  The mutation judgment is `Whiska.Shell`'s, and it errs towards "mutating"
  whenever it cannot read a command confidently. Here that costs a false denial
  on an exotic-but-harmless command that happens to mention the main checkout —
  rare enough to be worth the containment.

  Reads are never policed, in any tool: the rule is about containment of
  *changes*, not a sandbox.

  ## No carve-out in v0.0.1

  ADR-0013 carves out Whiska's own config files — `checks.yml`, `dispatch.yml`,
  the `CLAUDE.md` block — as still directly editable. That carve-out is scoped to
  the **main session** editing its own repo's setup, and does not extend to a
  mouse reaching into the main checkout from a worktree: that is the containment
  breach the ADR exists to stop. So this slice denies every main-checkout edit,
  full stop.
  """

  alias Whiska.Layout
  alias Whiska.Shell

  @path_keys %{
    "Write" => "file_path",
    "Edit" => "file_path",
    "MultiEdit" => "file_path",
    "NotebookEdit" => "notebook_path"
  }

  @type decision :: :allow | {:deny, String.t()}

  @doc """
  Decide one tool call.

  Anything this slice does not police — every tool without an explicit target
  path, and every read — is allowed through untouched, leaving the rest of Claude
  Code's own permission machinery to have the final say.
  """
  @spec decide(String.t(), map(), Layout.t()) :: decision()
  def decide("Bash", tool_input, %Layout{} = layout) do
    command = Map.get(tool_input, "command", "")

    # Reads of the main checkout are fine; only a command that can change
    # something there is a containment breach.
    if Shell.mutating?(command) do
      command
      |> Shell.paths()
      |> Enum.map(&resolve(&1, layout))
      |> Enum.find_value(:allow, fn target ->
        case judge(target, layout) do
          {:deny, _} = denial -> denial
          :allow -> nil
        end
      end)
    else
      :allow
    end
  end

  def decide(tool_name, tool_input, %Layout{} = layout) do
    with {:ok, key} <- Map.fetch(@path_keys, tool_name),
         {:ok, raw} when is_binary(raw) <- Map.fetch(tool_input, key) do
      raw
      |> resolve(layout)
      |> judge(layout)
    else
      _ -> :allow
    end
  end

  # A relative path in a tool call is relative to where the mouse is working,
  # which is its own worktree.
  defp resolve(raw, layout), do: Path.expand(raw, layout.worktree_root)

  defp judge(target, layout) do
    cond do
      Layout.inside?(target, layout.worktree_root) -> :allow
      Layout.inside?(target, layout.main_checkout) -> {:deny, reason(target, layout)}
      true -> :allow
    end
  end

  defp reason(target, layout) do
    """
    Whiska denied this edit: #{target} is outside this mouse's worktree.

    This mouse's worktree is #{layout.worktree_root}
    The main checkout is     #{layout.main_checkout}

    Edits in the main checkout are blocked (ADR-0013) — they bypass worktree
    containment, checks, diff review and push approval. Make this change inside
    the worktree instead; if it genuinely belongs in the main checkout, that is a
    decision for the main session, not for a mouse.
    """
    |> String.trim()
  end
end
