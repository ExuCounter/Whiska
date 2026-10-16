defmodule Whiska.Doorstep.Entry do
  @moduledoc """
  One thing a mouse left on the doorstep: its whole final message, stamped.

  ADR-0036 fixes the stamp — `mouse_id`, branch label, timestamp. The worktree
  root travels too, because collection has to know whether that worktree still
  exists (a stale entry is recorded, never delivered) and the branch label alone
  cannot say. The text is the raw message; the owl classifies it (ADR-0009), so
  the hook that writes this stays a dumb file-writer.

  `ran_on` is the model id the turn ran on, read from the transcript the hook
  already reads; nil when the transcript did not say, and on an entry written
  before it travelled.

  `spec` is the text of the worktree's spec file when the turn ended, nil when
  there was none. It travels here because the doorstep is in the house and
  outlives the worktree, so the owl can keep a copy of the spec at collection
  whatever removes the worktree first (ADR-0063). `research` is the worktree's
  research document and `plan` its build plan the same way, each kept beside
  the spec (ADR-0063).

  `transcript` is the path of the session's Claude Code transcript, from the
  `Stop` payload, nil when the payload named none and on an entry written before
  it travelled. The owl reads the turn's usage from it at collection
  (ADR-0086).

  `from` is `owl` on an entry the owl itself leaves about a merge request
  (`Whiska.Question.FromOwl`), nil on a mouse's. It is a claim, not a proof:
  collection takes it only with the owl's own words (ADR-0036).

  `reply` is true on the mouse's reply to a letter or an answer, left while
  work it started before that line still runs (ADR-0052); false on any other
  stop and on an entry written before it travelled.
  """

  @enforce_keys [:mouse_id, :branch, :worktree_root, :stamped_at, :text]
  defstruct [
    :mouse_id,
    :branch,
    :worktree_root,
    :stamped_at,
    :text,
    ran_on: nil,
    spec: nil,
    research: nil,
    plan: nil,
    transcript: nil,
    from: nil,
    reply: false
  ]

  @type t :: %__MODULE__{
          mouse_id: String.t(),
          branch: String.t(),
          worktree_root: Path.t(),
          stamped_at: DateTime.t(),
          text: String.t(),
          ran_on: String.t() | nil,
          spec: String.t() | nil,
          research: String.t() | nil,
          plan: String.t() | nil,
          transcript: Path.t() | nil,
          from: String.t() | nil,
          reply: boolean()
        }

  @doc "The on-disk form: plain JSON, one object."
  @spec encode(t()) :: String.t()
  def encode(%__MODULE__{} = entry) do
    JSON.encode!(%{
      "mouse_id" => entry.mouse_id,
      "branch" => entry.branch,
      "worktree_root" => entry.worktree_root,
      "stamped_at" => DateTime.to_iso8601(entry.stamped_at),
      "text" => entry.text,
      "ran_on" => entry.ran_on,
      "spec" => entry.spec,
      "research" => entry.research,
      "plan" => entry.plan,
      "transcript" => entry.transcript,
      "from" => entry.from,
      "reply" => entry.reply
    })
  end

  @doc "Read one back; anything short of a complete entry is `:error`."
  @spec decode(binary()) :: {:ok, t()} | :error
  def decode(raw) do
    with {:ok,
          %{
            "mouse_id" => mouse_id,
            "branch" => branch,
            "worktree_root" => root,
            "stamped_at" => stamped,
            "text" => text
          } = fields}
         when is_binary(mouse_id) and is_binary(branch) and is_binary(root) and
                is_binary(text) <- JSON.decode(raw),
         {:ok, stamped_at, _} <- DateTime.from_iso8601(stamped) do
      {:ok,
       %__MODULE__{
         mouse_id: mouse_id,
         branch: branch,
         worktree_root: root,
         stamped_at: stamped_at,
         text: text,
         ran_on: if(is_binary(fields["ran_on"]), do: fields["ran_on"]),
         spec: if(is_binary(fields["spec"]), do: fields["spec"]),
         research: if(is_binary(fields["research"]), do: fields["research"]),
         plan: if(is_binary(fields["plan"]), do: fields["plan"]),
         transcript: if(is_binary(fields["transcript"]), do: fields["transcript"]),
         from: if(is_binary(fields["from"]), do: fields["from"]),
         reply: fields["reply"] == true
       }}
    else
      _ -> :error
    end
  end
end
