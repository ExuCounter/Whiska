defmodule Whiska.Review do
  @moduledoc """
  A branch's diff as a patch file in the main checkout, so the person
  opens it from a link, in whatever their terminal or OS opens a `.diff` file
  with, as a spec opens in whatever opens a `.md` (ADR-0085). Whiska names no
  viewer: the file type is where the person plugs theirs in.

  One file per branch, `.whiska/reviews/<branch>-<hash>.diff`, rewritten each
  time one of its questions is shown, so every question's link opens the
  branch's diff as it stands. It sits beside the kept specs and is ignored the
  same way, through `.git/info/exclude`, so no committed file changes. It goes
  when Whiska deletes the branch.

  A branch whose merge request had a review round keeps a second file,
  `<branch>-<hash>.round.diff`: what it changed since that round began.
  """

  alias Whiska.HouseFile

  @dir ".whiska/reviews"

  @doc "Write the branch's diff, exactly as git printed it, so any tool that reads a patch reads it."
  @spec write(Path.t(), String.t(), String.t()) :: {:ok, Path.t()} | {:error, term()}
  def write(main_checkout, branch, diff),
    do: HouseFile.write(main_checkout, @dir, name(branch), diff)

  @spec write_round(Path.t(), String.t(), String.t()) :: {:ok, Path.t()} | {:error, term()}
  def write_round(main_checkout, branch, diff),
    do: HouseFile.write(main_checkout, @dir, round_name(branch), diff)

  @doc "Remove the branch's diff file and its round's."
  @spec remove(Path.t(), String.t()) :: :ok | {:error, term()}
  def remove(main_checkout, branch) do
    with :ok <- HouseFile.remove(main_checkout, @dir, name(branch)),
         do: remove_round(main_checkout, branch)
  end

  @spec remove_round(Path.t(), String.t()) :: :ok | {:error, term()}
  def remove_round(main_checkout, branch),
    do: HouseFile.remove(main_checkout, @dir, round_name(branch))

  @doc "The branch's diff file, whether or not it was written."
  @spec file(Path.t(), String.t()) :: Path.t()
  def file(main_checkout, branch), do: Path.join([main_checkout, @dir, name(branch)])

  @spec round_file(Path.t(), String.t()) :: Path.t()
  def round_file(main_checkout, branch), do: Path.join([main_checkout, @dir, round_name(branch)])

  defp round_name(branch), do: String.replace_suffix(name(branch), ".diff", ".round.diff")

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
