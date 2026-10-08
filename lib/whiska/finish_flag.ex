defmodule Whiska.FinishFlag do
  @moduledoc """
  An empty file saying a finished line is out in a house's main session and
  the person has not written anything since (ADR-0008).

  It is a hint for the hook shim, never a record: the finished report's `sent`
  status is what holds the slot. The shim reads it with shell builtins alone, so
  a prompt in a main session with nothing out exits before any Erlang starts. A
  flag left behind costs one escript start per prompt until the next prompt
  lowers it; a missing one leaves the report holding the slot until `dismiss`,
  a hold on its branch, or that branch's next message.

  It lives in the main checkout's own `.git` directory, which `git status`
  never shows. That directory is the person's, not a mouse's, but a build mouse
  can still write there, so the flag is created, never written through.
  """

  @filename "whiska-finish"

  @spec path(Path.t()) :: Path.t()
  def path(main_checkout), do: Path.join([main_checkout, ".git", @filename])

  @spec set(Path.t()) :: :ok | {:error, term()}
  def set(main_checkout) do
    path = path(main_checkout)

    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} -> :ok
      {:ok, %File.Stat{}} -> {:error, :not_a_plain_file}
      {:error, :enoent} -> File.write(path, "", [:exclusive])
      {:error, _} = error -> error
    end
  end

  @spec clear(Path.t()) :: :ok | {:error, term()}
  def clear(main_checkout) do
    case File.rm(path(main_checkout)) do
      {:error, :enoent} -> :ok
      other -> other
    end
  end

  @spec set?(Path.t()) :: boolean()
  def set?(main_checkout) do
    match?({:ok, %File.Stat{type: :regular}}, File.lstat(path(main_checkout)))
  end
end
