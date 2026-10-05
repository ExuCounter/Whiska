defmodule Whiska.Spec do
  @moduledoc """
  The spec a mouse writes after grilling and the person approves before any code
  (ADR-next-a-grilled-brief-is-written-down-before-it-is-built): one file at the
  worktree root that is never committed.

  Untracked is not enough. The owl takes a landed worktree down only when `git
  status` reads it clean (ADR-0061), and git counts an untracked file as a change.
  So the file is ignored through the main checkout's `.git/info/exclude`, which
  is local to this machine, never committed, and read by every worktree of the
  repo. Git then deletes the spec along with the worktree.
  """

  @filename ".whiska-spec.md"
  @exclude_line "/" <> @filename

  @spec filename() :: String.t()
  def filename, do: @filename

  @doc "The exclude pattern, anchored so a file of that name deeper down stays visible."
  @spec exclude_line() :: String.t()
  def exclude_line, do: @exclude_line

  @doc "Make git ignore the spec in every worktree of this checkout. Safe to repeat."
  @spec ignore(Path.t()) :: :ok | {:error, term()}
  def ignore(main_checkout) do
    git_dir = Path.join(main_checkout, ".git")
    exclude = Path.join([git_dir, "info", "exclude"])

    with true <- File.dir?(git_dir) || {:error, :no_git_dir},
         :ok <- File.mkdir_p(Path.dirname(exclude)),
         {:ok, existing} <- read(exclude) do
      if @exclude_line in String.split(existing, "\n") do
        :ok
      else
        File.write(exclude, separated(existing) <> @exclude_line <> "\n")
      end
    end
  end

  defp read(path) do
    case File.read(path) do
      {:error, :enoent} -> {:ok, ""}
      other -> other
    end
  end

  defp separated(""), do: ""
  defp separated(text), do: if(String.ends_with?(text, "\n"), do: text, else: text <> "\n")
end
