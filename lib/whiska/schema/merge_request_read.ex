defmodule Whiska.Schema.MergeRequestRead do
  @moduledoc """
  What the owl last read of one mouse's merge request on its forge (ADR-0087).

  Keyed by the mouse, for the link in `url`: a mouse whose link changes starts
  a row afresh. `state` is nil until a read works, then `open`, `merged`,
  `closed`, or `gone` once the forge has not had it three reads in a row.
  """

  use Ecto.Schema

  @primary_key {:mouse_id, :string, autogenerate: false}

  schema "merge_request_reads" do
    field(:url, :string)
    field(:state, :string)
    field(:head_sha, :string)
    field(:pipeline_id, :integer)
    # running | passed | failed | other, or nil with no pipeline.
    field(:pipeline, :string)
    field(:threads_open, :integer, default: 0)
    # Of those, the ones whose newest note is the account's own: they wait on
    # the reviewer.
    field(:threads_answered, :integer, default: 0)
    field(:notes_count, :integer)
    field(:forge_updated_at, :string)
    field(:ready, :boolean, default: false)
    # Why the forge will not merge it yet (`Whiska.Forge.blocker/0`), or nil.
    field(:blocker, :string)
    # The cursor: a comment at or below it never counts.
    field(:seen_note_id, :integer)
    field(:seen_failed_pipeline_id, :integer)
    field(:missing_reads, :integer, default: 0)
    # The last read that worked; and since when, and why, every read has failed.
    field(:read_at, :utc_datetime)
    field(:unread_since, :utc_datetime)
    field(:unread_reason, :string)
    # When the owl asked the person about this merge request closing; cleared
    # when it reads open again.
    field(:asked_at, :utc_datetime)
    # The review read and not yet handed to a mouse, as JSON (`pending/1`).
    field(:pending, :string)
    # The owl's last review round: when, `woke` or `started`, and the
    # branch's `origin` ref and the forge's head then.
    field(:round_at, :utc_datetime)
    field(:round_by, :string)
    field(:round_ref, :string)
    field(:round_head, :string)
    field(:rounds_unpushed, :integer, default: 0)
    # The owl's own question about the review, and why: cap, start_failed or
    # died.
    field(:review_asked_at, :utc_datetime)
    field(:review_asked_why, :string)
    # The open threads counted as review, by id, as JSON (`threads_handed/1`):
    # one is counted once, and again only through a new comment in it.
    field(:threads_handed, :string)
  end

  @fields ~w(url state head_sha pipeline_id pipeline threads_open threads_answered notes_count forge_updated_at
             ready blocker seen_note_id seen_failed_pipeline_id missing_reads read_at unread_since
             unread_reason asked_at pending round_at round_by round_ref round_head
             rounds_unpushed review_asked_at review_asked_why threads_handed)a

  @doc false
  def fields, do: @fields

  @typedoc """
  A review: new comments, each with its thread when the forge named one, and
  a pipeline that failed on the head. A comment marked `open` is the newest
  note of an open thread no round had, however old.
  """
  @type review :: %{
          comments: [
            %{
              required(:id) => pos_integer(),
              required(:author) => String.t(),
              required(:discussion_id) => String.t() | nil,
              optional(:open) => true
            }
          ],
          pipeline: %{id: pos_integer(), sha: String.t()} | nil
        }

  @doc """
  The review a row or its fields keep, or nil. Whatever will not decode, or
  is not the shape `encode_pending/1` writes, is nil: a row is the owl's own
  writing, so that is a bug, and handing nothing over is its safe reading.
  """
  @spec pending(map()) :: review() | nil
  def pending(%{pending: text}) when is_binary(text) do
    case JSON.decode(text) do
      {:ok, %{"comments" => comments, "pipeline" => pipeline}} when is_list(comments) ->
        with {:ok, comments} <- comments(comments),
             {:ok, pipeline} <- pipeline(pipeline) do
          %{comments: comments, pipeline: pipeline}
        else
          _ -> nil
        end

      _ ->
        nil
    end
  end

  def pending(_none), do: nil

  @doc "A review as `pending` stores it; nil for nothing to keep."
  @spec encode_pending(review() | nil) :: String.t() | nil
  def encode_pending(nil), do: nil
  def encode_pending(%{comments: [], pipeline: nil}), do: nil

  def encode_pending(%{comments: comments, pipeline: pipeline}) do
    JSON.encode!(%{
      "comments" => Enum.map(comments, &encode_comment/1),
      "pipeline" => pipeline && %{"id" => pipeline.id, "sha" => pipeline.sha}
    })
  end

  @doc "The ids of the open threads `row` has counted as review."
  @spec threads_handed(map()) :: [String.t()]
  def threads_handed(%{threads_handed: text}) when is_binary(text) do
    case JSON.decode(text) do
      {:ok, ids} when is_list(ids) -> Enum.filter(ids, &is_binary/1)
      _ -> []
    end
  end

  def threads_handed(_none), do: []

  @doc "Thread ids as `threads_handed` stores them; nil for none."
  @spec encode_threads_handed([String.t()]) :: String.t() | nil
  def encode_threads_handed([]), do: nil
  def encode_threads_handed(ids), do: JSON.encode!(ids)

  defp encode_comment(%{open: true} = c),
    do: Map.put(encode_comment(Map.delete(c, :open)), "open", true)

  defp encode_comment(c),
    do: %{"id" => c.id, "author" => c.author, "discussion_id" => c.discussion_id}

  defp comments(list) do
    Enum.reduce_while(list, {:ok, []}, fn
      %{"id" => id, "author" => author, "discussion_id" => thread} = c, {:ok, acc}
      when is_integer(id) and is_binary(author) and (is_binary(thread) or is_nil(thread)) ->
        comment = %{id: id, author: author, discussion_id: thread}
        comment = if c["open"] == true, do: Map.put(comment, :open, true), else: comment
        {:cont, {:ok, acc ++ [comment]}}

      _other, _acc ->
        {:halt, :error}
    end)
  end

  defp pipeline(nil), do: {:ok, nil}

  defp pipeline(%{"id" => id, "sha" => sha}) when is_integer(id) and is_binary(sha),
    do: {:ok, %{id: id, sha: sha}}

  defp pipeline(_other), do: :error
end
