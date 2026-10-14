defmodule Whiska.Question.FromOwl do
  @moduledoc """
  The one question the owl asks on its own account: a mouse's merge request
  closed or went from the forge, so does its worktree go too (ADR-0087)?

  It comes in by the doorstep like every question (ADR-0036), as an entry
  marked `from: "owl"`, and is delivered to the main session like any other.
  Its words are fixed, so collection takes the mark only from an entry whose
  text is exactly what `entry/4` writes for that mouse: anything else that
  claims to be the owl's is recorded as the mouse's own.
  """

  alias Whiska.Doorstep.Entry
  alias Whiska.Schema.Mouse

  @marker "⁣⁣"

  @doc "The entry asking about `mouse`'s merge request `label`, `why` it is no longer open."
  @spec entry(Mouse.t(), String.t(), :closed | :gone, DateTime.t()) :: Entry.t()
  def entry(%Mouse{} = mouse, label, why, now) do
    branch = mouse.branch || mouse.mouse_id

    %Entry{
      mouse_id: mouse.mouse_id,
      branch: branch,
      worktree_root: mouse.path,
      stamped_at: now,
      text: text(branch, label, why),
      from: "owl"
    }
  end

  @doc "Whether `entry` is one the owl wrote: its mark, and its words for that branch."
  @spec ours?(Entry.t()) :: boolean()
  def ours?(%Entry{from: "owl", branch: branch, text: text}) do
    Enum.any?(
      for(why <- [:closed, :gone], label <- labels(text), do: text(branch, label, why)),
      &(&1 == text)
    )
  end

  def ours?(_entry), do: false

  defp labels(text), do: Regex.scan(~r/[!#][0-9]+/, text) |> List.flatten() |> Enum.uniq()

  defp text(branch, label, why) do
    """
    # #{label} #{said(why)}

    #{branch}'s merge request #{label} #{said(why)}, without merging. Whiska asks
    this itself: the mouse on #{branch} did not.

    Say "drop" to take its worktree, pane and branch down (`whiska drop #{branch}`),
    or "keep" to leave them and close this question (`whiska dismiss <id>`).

    Drop the worktree of #{branch}?
    #{@marker}
    """
  end

  defp said(:closed), do: "was closed on the forge"
  defp said(:gone), do: "is gone from the forge"
end
