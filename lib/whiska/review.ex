defmodule Whiska.Review do
  @moduledoc """
  A finished branch's diff as a Markdown file in the main checkout, so the
  person opens it from a link the way they open a spec, in whatever viewer
  their links open in (ADR-0085).

  One file per branch, `.whiska/reviews/<branch>-<hash>.md`, rewritten each time one
  of its questions is shown, so every question's link opens the branch's
  diff as it stands. It sits beside the kept specs and is ignored the same way,
  through `.git/info/exclude`, so no committed file changes.

  A person with a diff viewer of their own points the link at it instead, with
  a pattern in `WHISKA_DIFF_LINK`, and then no file is written.
  """

  alias Whiska.HouseFile

  @dir ".whiska/reviews"

  @spec write(Path.t(), String.t(), String.t(), pos_integer(), String.t()) ::
          {:ok, Path.t()} | {:error, term()}
  def write(main_checkout, base, branch, ahead, diff),
    do: HouseFile.write(main_checkout, @dir, name(branch), render(base, branch, ahead, diff))

  @doc "The branch's diff file, whether or not it was written."
  @spec file(Path.t(), String.t()) :: Path.t()
  def file(main_checkout, branch), do: Path.join([main_checkout, @dir, name(branch)])

  # Branch names that read alike once made safe for a file name, such as
  # `feat/x` and `feat-x`, keep a file each by the hash of the whole name.
  defp name(branch) do
    hash = :crypto.hash(:sha256, branch) |> Base.encode16(case: :lower) |> binary_part(0, 8)
    "#{String.replace(branch, ~r/[^A-Za-z0-9._-]+/, "-")}-#{hash}.md"
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

  @doc """
  The diff link a `WHISKA_DIFF_LINK` pattern makes, its `{base}` and
  `{branch}` filled in. Whiska names no viewer: the person's pattern does
  (ADR-0085). `:error` when there is no pattern, or one that could break the
  link — it must start with a scheme and hold no space, parenthesis,
  backslash, or control or format character — and the file link stands then.
  """
  @spec link(String.t() | nil, String.t(), String.t()) :: {:ok, String.t()} | :error
  def link(pattern, base, branch),
    do: fill(pattern, %{"{base}" => base, "{branch}" => branch})

  @doc """
  The spec link a `WHISKA_SPEC_LINK` pattern makes, its `{path}` (the spec
  file's absolute path) and `{branch}` filled in, under the same rules as the
  diff link's pattern (ADR-0085). `:error` and the file link stand otherwise.
  """
  @spec spec_link(String.t() | nil, Path.t(), String.t()) :: {:ok, String.t()} | :error
  def spec_link(pattern, path, branch),
    do: fill(pattern, %{"{path}" => path, "{branch}" => branch})

  defp fill(pattern, values) when is_binary(pattern) do
    if Regex.match?(~r/\A[A-Za-z][A-Za-z0-9+.-]*:[^\s()\\\p{C}]*\z/u, pattern) do
      {:ok, String.replace(pattern, Map.keys(values), &encode(values[&1]))}
    else
      :error
    end
  end

  defp fill(nil, _values), do: :error

  @spec file_link(Path.t()) :: String.t()
  def file_link(path), do: "file://" <> encode(path)

  # Whatever a branch is named, it reaches the link as one piece that cannot
  # close the Markdown link or start a new one.
  defp encode(text), do: URI.encode(text, &(URI.char_unreserved?(&1) or &1 == ?/))

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
