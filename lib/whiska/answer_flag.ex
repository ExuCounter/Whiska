defmodule Whiska.AnswerFlag do
  @moduledoc """
  An empty file saying a worktree's mouse has an answer it has not taken yet
  (ADR-next-an-answer-is-taken-not-typed).

  It is a hint for the hook shim, never a record: the database says what is
  chased. The shim reads it with shell builtins alone, so a prompt in a session
  with no answer waiting exits before any Erlang starts. A flag left behind
  costs that one mouse an escript start per prompt; a missing one ends with the
  owl ringing, then telling the person. Neither loses an answer.

  It lives in the worktree's own git admin directory, which git never shows in
  `git status` and removes with the worktree.
  """

  @filename "whiska-answer"

  @spec path(Path.t()) :: {:ok, Path.t()} | {:error, term()}
  def path(worktree_root) do
    with {:ok, contents} <- File.read(Path.join(worktree_root, ".git")),
         "gitdir: " <> gitdir <- String.trim(contents) do
      {:ok, Path.join(Path.expand(gitdir, worktree_root), @filename)}
    else
      {:error, _} = error -> error
      _other -> {:error, :not_a_linked_worktree}
    end
  end

  @spec set(Path.t()) :: :ok | {:error, term()}
  def set(worktree_root) do
    with {:ok, path} <- path(worktree_root), do: File.write(path, "")
  end

  @spec clear(Path.t()) :: :ok | {:error, term()}
  def clear(worktree_root) do
    with {:ok, path} <- path(worktree_root) do
      case File.rm(path) do
        {:error, :enoent} -> :ok
        other -> other
      end
    end
  end

  @spec set?(Path.t()) :: boolean()
  def set?(worktree_root) do
    case path(worktree_root) do
      {:ok, path} -> File.exists?(path)
      {:error, _} -> false
    end
  end
end
