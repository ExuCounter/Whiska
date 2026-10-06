defmodule Whiska.AnswerFlag do
  @moduledoc """
  An empty file saying a worktree's mouse has an answer it has not taken yet
  (ADR-0080).

  It is a hint for the hook shim, never a record: the database says what is
  chased. The shim reads it with shell builtins alone, so a prompt in a session
  with no answer waiting exits before any Erlang starts. A flag left behind
  costs that one mouse an escript start per prompt; a missing one ends with the
  owl ringing, then telling the person. Neither loses an answer.

  It lives in the worktree's own git admin directory, which git never shows in
  `git status` and removes with the worktree.

  Where that is comes from the worktree's `.git` file, which the mouse working
  there can rewrite, and the owl and `whiska reply` act on it. So the file is
  read only when it is a plain file — a named pipe there would never answer and
  hang the owl — and the flag is created, never written through: whatever a
  mouse put at the flag's path, a link to one of the person's files included,
  is refused rather than emptied (ADR-0013).
  """

  @filename "whiska-answer"

  @spec path(Path.t()) :: {:ok, Path.t()} | {:error, term()}
  def path(worktree_root) do
    dot_git = Path.join(worktree_root, ".git")

    with {:ok, %File.Stat{type: :regular}} <- File.lstat(dot_git),
         {:ok, contents} <- File.read(dot_git),
         "gitdir: " <> gitdir <- String.trim(contents) do
      {:ok, Path.join(Path.expand(gitdir, worktree_root), @filename)}
    else
      {:error, _} = error -> error
      _other -> {:error, :not_a_linked_worktree}
    end
  end

  @spec set(Path.t()) :: :ok | {:error, term()}
  def set(worktree_root) do
    with {:ok, path} <- path(worktree_root) do
      case File.lstat(path) do
        {:ok, %File.Stat{type: :regular}} -> :ok
        {:ok, %File.Stat{}} -> {:error, :not_a_plain_file}
        {:error, :enoent} -> File.write(path, "", [:exclusive])
        {:error, _} = error -> error
      end
    end
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
      {:ok, path} -> match?({:ok, %File.Stat{type: :regular}}, File.lstat(path))
      {:error, _} -> false
    end
  end
end
