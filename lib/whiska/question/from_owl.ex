defmodule Whiska.Question.FromOwl do
  @moduledoc """
  The questions the owl asks on its own account, about a mouse's merge
  request: it closed or went from the forge, so does its worktree go too
  (ADR-0087)? And its review is no longer handed over, so may it be again
  (ADR-0060)?

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
  exactly the words `entry/4` or `review_entry/4` writes for that mouse's merge request, which the
  owl's `read` of it says it asked about. The words are public, so the read is
  what shows the owl wrote them.
  """
  @spec ours?(Entry.t(), Mouse.t() | nil, MergeRequestRead.t() | nil) :: boolean()
  def ours?(entry, mouse, read),
    do: asked_to_drop?(entry, mouse, read) or asked_about_review?(entry, mouse, read)

  defp asked_to_drop?(
         %Entry{from: "owl", stamped_at: %DateTime{} = stamped_at} = entry,
         %Mouse{merge_request_url: url} = mouse,
         %MergeRequestRead{url: url, asked_at: %DateTime{} = asked_at, state: state}
       )
       when is_binary(url) and state in ["closed", "gone"] do
    with true <- same_second?(stamped_at, asked_at),
         {:ok, ref} <- Forge.for_url(url) do
      asked = entry(mouse, Forge.label(ref), why(state), stamped_at)
      {entry.mouse_id, entry.branch, entry.text} == {asked.mouse_id, asked.branch, asked.text}
    else
      _ -> false
    end
  end

  defp asked_to_drop?(_entry, _mouse, _read), do: false

  @doc "Whether `entry` is the owl's question about `mouse`'s review, as `ours?/3` reads it."
  @spec asked_about_review?(Entry.t(), Mouse.t() | nil, MergeRequestRead.t() | nil) :: boolean()
  def asked_about_review?(
        %Entry{from: "owl", stamped_at: %DateTime{} = stamped_at} = entry,
        %Mouse{merge_request_url: url} = mouse,
        %MergeRequestRead{
          url: url,
          review_asked_at: %DateTime{} = asked_at,
          review_asked_why: why
        }
      )
      when is_binary(url) and why in ["cap", "start_failed", "died"] do
    with true <- same_second?(stamped_at, asked_at),
         {:ok, ref} <- Forge.for_url(url) do
      asked =
        review_entry(mouse, Forge.label(ref), String.to_existing_atom(why), stamped_at)

      {entry.mouse_id, entry.branch, entry.text} == {asked.mouse_id, asked.branch, asked.text}
    else
      _ -> false
    end
  end

  def asked_about_review?(_entry, _mouse, _read), do: false

  defp same_second?(a, b), do: DateTime.truncate(a, :second) == DateTime.truncate(b, :second)

  @doc """
  Whether the owl asks about `mouse` at all: not when its branch's name holds
  a space, a control character or a backtick, which could make words of its
  own in the question.
  """
  @spec askable?(Mouse.t()) :: boolean()
  def askable?(%Mouse{} = mouse),
    do: (mouse.branch || mouse.mouse_id) =~ ~r/\A[^\s`[:cntrl:]]+\z/u

  @doc "`whiska drop` for `branch`, quoted when the shell would read anything in it."
  @spec drop_command(String.t()) :: String.t()
  def drop_command(branch) do
    if branch =~ ~r"\A[A-Za-z0-9._/-]+\z",
      do: "whiska drop #{branch}",
      else: "whiska drop '#{String.replace(branch, "'", ~S('\''))}'"
  end

  @doc "The entry asking whether review on `mouse`'s merge request `label` is handed over again."
  @spec review_entry(Mouse.t(), String.t(), :cap | :start_failed | :died, DateTime.t()) ::
          Entry.t()
  def review_entry(%Mouse{} = mouse, label, why, now) do
    branch = mouse.branch || mouse.mouse_id

    %Entry{
      mouse_id: mouse.mouse_id,
      branch: branch,
      worktree_root: mouse.path,
      stamped_at: now,
      text: review_text(branch, label, why),
      from: "owl"
    }
  end

  defp review_text(branch, label, why) do
    """
    # #{label}'s review is waiting on you

    #{review_said(branch, label, why)} Whiska hands no more of #{label}'s review over
    until you say.

    Say "go on" to close this and let Whiska hand review over again
    (`whiska dismiss <id>`).

    Hand #{label}'s review over again?
    #{@marker}
    """
  end

  defp review_said(branch, label, :cap),
    do:
      "Whiska handed new review on #{label} to #{branch}'s mouse three rounds in a row, " <>
        "and none of them pushed."

  defp review_said(branch, label, :start_failed),
    do:
      "Whiska could not start a mouse for new review on #{label}, on #{branch}; the owl's " <>
        "log says why."

  defp review_said(branch, label, :died),
    do:
      "The mouse Whiska started for new review on #{label}, on #{branch}, ended without " <>
        "asking or reporting anything."

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
