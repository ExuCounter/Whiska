defmodule Whiska.Review do
  @moduledoc """
  A finished branch's diff as a patch file in the main checkout, so the person
  opens it from a link, in whatever their terminal or OS opens a `.diff` file
  with, as a spec opens in whatever opens a `.md` (ADR-0085). Whiska names no
  viewer: the file type is where the person plugs theirs in.

  One file per branch, `.whiska/reviews/<branch>-<hash>.diff`, rewritten each
  time one of its questions is shown, so every question's link opens the
  branch's diff as it stands. It sits beside the kept specs and is ignored the
  same way, through `.git/info/exclude`, so no committed file changes. It goes
  when Whiska deletes the branch.
  """

  alias Whiska.HouseFile

  @dir ".whiska/reviews"

  @doc "Write the branch's diff, exactly as git printed it, so any tool that reads a patch reads it."
  @spec write(Path.t(), String.t(), String.t()) :: {:ok, Path.t()} | {:error, term()}
  def write(main_checkout, branch, diff),
    do: HouseFile.write(main_checkout, @dir, name(branch), diff)

  @spec remove(Path.t(), String.t()) :: :ok | {:error, term()}
  def remove(main_checkout, branch), do: HouseFile.remove(main_checkout, @dir, name(branch))

  @doc "The branch's diff file, whether or not it was written."
  @spec file(Path.t(), String.t()) :: Path.t()
  def file(main_checkout, branch), do: Path.join([main_checkout, @dir, name(branch)])

  # Branch names that read alike once made safe for a file name, such as
  # `feat/x` and `feat-x`, keep a file each by the hash of the whole name, long
  # enough that a mouse cannot search out a name sharing another branch's file.
  # The readable part is cut short so any branch name fits a file name.
  defp name(branch) do
    hash = :crypto.hash(:sha256, branch) |> Base.encode16(case: :lower) |> binary_part(0, 32)
    readable = String.replace(branch, ~r/[^A-Za-z0-9._-]+/, "-") |> String.slice(0, 100)
    "#{readable}-#{hash}.diff"
  end

  @spec file_link(Path.t()) :: String.t()
  def file_link(path), do: "file://" <> encode(path)

  # Whatever a branch is named, it reaches the link as one piece that cannot
  # close the Markdown link or start a new one.
  defp encode(text), do: URI.encode(text, &(URI.char_unreserved?(&1) or &1 == ?/))
end
