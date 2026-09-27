defmodule Whiska.Doorstep.Entry do
  @moduledoc """
  One thing a mouse left on the doorstep: its whole final message, stamped.

  ADR-0036 fixes the stamp — `mouse_id`, branch label, timestamp. The worktree
  root travels too, because collection has to know whether that worktree still
  exists (a stale entry is recorded, never delivered) and the branch label alone
  cannot say. The text is the raw message; the owl classifies it (ADR-0009), so
  the hook that writes this stays a dumb file-writer.
  """

  @enforce_keys [:mouse_id, :branch, :worktree_root, :stamped_at, :text]
  defstruct [:mouse_id, :branch, :worktree_root, :stamped_at, :text]

  @type t :: %__MODULE__{
          mouse_id: String.t(),
          branch: String.t(),
          worktree_root: Path.t(),
          stamped_at: DateTime.t(),
          text: String.t()
        }

  @doc "The on-disk form: plain JSON, one object."
  @spec encode(t()) :: String.t()
  def encode(%__MODULE__{} = entry) do
    JSON.encode!(%{
      "mouse_id" => entry.mouse_id,
      "branch" => entry.branch,
      "worktree_root" => entry.worktree_root,
      "stamped_at" => DateTime.to_iso8601(entry.stamped_at),
      "text" => entry.text
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
          }}
         when is_binary(mouse_id) and is_binary(branch) and is_binary(root) and
                is_binary(text) <- JSON.decode(raw),
         {:ok, stamped_at, _} <- DateTime.from_iso8601(stamped) do
      {:ok,
       %__MODULE__{
         mouse_id: mouse_id,
         branch: branch,
         worktree_root: root,
         stamped_at: stamped_at,
         text: text
       }}
    else
      _ -> :error
    end
  end
end
