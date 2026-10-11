defmodule Whiska.Review do
  @moduledoc """
  A finished branch's diff as a Markdown file in the main checkout, so the
  person opens it from a link the way they open a spec, in whatever viewer
  their links open in (ADR-next-whiska-stands-alone).

  One file per question, `.whiska/reviews/<id>.md`, rewritten each time the
  question is shown. It sits beside the kept specs and is ignored the same way,
  through `.git/info/exclude`, so no committed file changes.
  """

  alias Whiska.Spec

  @dir ".whiska/reviews"
  @exclude_line "/.whiska/"

  @spec write(Path.t(), pos_integer(), String.t(), String.t(), pos_integer(), String.t()) ::
          {:ok, Path.t()} | {:error, term()}
  def write(main_checkout, id, base, branch, ahead, diff) do
    dir = Path.join(main_checkout, @dir)
    path = Path.join(dir, "#{id}.md")
    temp = "#{path}.#{System.unique_integer([:positive])}.tmp"

    with :ok <- Spec.ignore(main_checkout, @exclude_line),
         :ok <- no_link(main_checkout),
         :ok <- File.mkdir_p(dir),
         :ok <- no_link(main_checkout),
         :ok <- File.write(temp, render(base, branch, ahead, diff), [:exclusive]),
         :ok <- rename(temp, path) do
      {:ok, path}
    end
  end

  # A link in the folder would carry the write anywhere the person can write,
  # such as a folder Claude Code reads as instructions. A link at the file
  # itself is replaced by the rename, never followed.
  defp no_link(main_checkout) do
    [".whiska", @dir]
    |> Enum.find(&match?({:ok, %{type: :symlink}}, File.lstat(Path.join(main_checkout, &1))))
    |> case do
      nil -> :ok
      link -> {:error, {:symlink, link}}
    end
  end

  defp rename(temp, path) do
    with {:error, _} = error <- File.rename(temp, path) do
      File.rm(temp)
      error
    end
  end

  @doc """
  The file's text. The diff sits in a fence longer than any run of backticks
  in it, so no line of the branch can close the fence early.
  """
  @spec render(String.t(), String.t(), pos_integer(), String.t()) :: String.t()
  def render(base, branch, ahead, diff) do
    branch = plain(branch)
    fence = String.duplicate("`", max(3, longest_backtick_run(diff) + 1))

    """
    # #{branch} against #{base}

    #{commits(ahead)}, from `git diff #{base}...#{branch}`.

    #{fence}diff
    #{String.trim_trailing(diff, "\n")}
    #{fence}
    """
  end

  @spec commits(pos_integer()) :: String.t()
  def commits(1), do: "1 commit"
  def commits(n), do: "#{n} commits"

  defp longest_backtick_run(text) do
    ~r/`+/
    |> Regex.scan(text)
    |> Enum.map(fn [run] -> String.length(run) end)
    |> Enum.max(fn -> 0 end)
  end

  # A branch name is a mouse's to choose, and git allows more in one than a
  # heading or a code span can hold.
  defp plain(name), do: String.replace(name, ~r/[^A-Za-z0-9._\/-]/, "?")
end
