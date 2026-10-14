defmodule Whiska.Question.FromOwl do
  @moduledoc """
  The one question the owl asks on its own account: a mouse's merge request
  closed or went from the forge, so does its worktree go too (ADR-0087)?

  It comes in by the doorstep like every question (ADR-0036), as an entry
  marked `from: "owl"`, and is delivered to the main session like any other.
  Anything else that claims to be the owl's is recorded as the mouse's own.
  """

  alias Whiska.Doorstep.Entry
  alias Whiska.Forge
  alias Whiska.Schema.MergeRequestRead
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

  @doc """
  Whether `entry` is the question the owl asked about `mouse`: its mark, and
  exactly the words `entry/4` writes for that mouse's merge request, which the
  owl's `read` of it says it asked about. The words are public, so the read is
  what shows the owl wrote them.
  """
  @spec ours?(Entry.t(), Mouse.t() | nil, MergeRequestRead.t() | nil) :: boolean()
  def ours?(
        %Entry{from: "owl"} = entry,
        %Mouse{merge_request_url: url} = mouse,
        %MergeRequestRead{url: url, asked_at: %DateTime{}, state: state}
      )
      when is_binary(url) and state in ["closed", "gone"] do
    case Forge.for_url(url) do
      {:ok, ref} ->
        asked = entry(mouse, Forge.label(ref), why(state), entry.stamped_at)
        %{entry | worktree_root: asked.worktree_root} == asked

      {:error, _} ->
        false
    end
  end

  def ours?(_entry, _mouse, _read), do: false

  @doc "`whiska drop` for `branch`, quoted when the shell would read anything in it."
  @spec drop_command(String.t()) :: String.t()
  def drop_command(branch) do
    if branch =~ ~r"\A[A-Za-z0-9._/-]+\z",
      do: "whiska drop #{branch}",
      else: "whiska drop '#{String.replace(branch, "'", ~S('\''))}'"
  end

  defp why("closed"), do: :closed
  defp why("gone"), do: :gone

  defp text(branch, label, why) do
    """
    # #{label} #{said(why)}

    #{branch}'s merge request #{label} #{said(why)}, without merging. Whiska asks
    this itself: the mouse on #{branch} did not.

    Say "drop" to take its worktree, pane and branch down (`#{drop_command(branch)}`),
    or "keep" to leave them and close this question (`whiska dismiss <id>`).

    Drop the worktree of #{branch}?
    #{@marker}
    """
  end

  defp said(:closed), do: "was closed on the forge"
  defp said(:gone), do: "is gone from the forge"
end
