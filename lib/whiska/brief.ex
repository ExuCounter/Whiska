defmodule Whiska.Brief do
  @moduledoc """
  A session's brief: everything Whiska tells it, in one file Claude Code is
  started with (`--append-system-prompt-file`). The main session's is
  `priv/briefs/main.md`; a mouse's is its mode's, `build.md` or `sniff.md`, or
  `review.md` for a build mouse the owl starts for a merge request's review. A
  mouse's task is not in it: the task is the session's first message.

  A review round's rules, `review_rules.md`, are written once and stand in for
  `{{review rules}}` in the build and review briefs; the letter that hands a
  round over carries them too. The report's shape, `report_rules.md`, stands in
  for `{{report rules}}` in the same two briefs.

  A mouse's brief is written to `.whiska-brief.md` at its worktree root, which
  git ignores like the spec (`Whiska.Spec`). The main session's is written into
  the house, beside its database, so a checkout holds no file of Whiska's.

  The briefs are read when Whiska is built, so the escript carries them.
  """

  @paths for name <- ~w(main build sniff review review_rules report_rules),
             do: {name, Path.join([__DIR__, "..", "..", "priv", "briefs", name <> ".md"])}

  for {_name, path} <- @paths, do: @external_resource(path)

  @read Map.new(@paths, fn {name, path} -> {name, File.read!(path)} end)
  @review_rules String.trim_trailing(@read["review_rules"])
  @report_rules String.trim_trailing(@read["report_rules"])

  @briefs @read
          |> Map.drop(["review_rules", "report_rules"])
          |> Map.new(fn {name, text} ->
            {name,
             text
             |> String.replace("{{review rules}}", @review_rules)
             |> String.replace("{{report rules}}", @report_rules)}
          end)

  @filename ".whiska-brief.md"

  @spec filename() :: String.t()
  def filename, do: @filename

  @spec exclude_line() :: String.t()
  def exclude_line, do: "/" <> @filename

  @doc "The main session's brief, or a mouse's for its mode, or the review brief."
  @spec render(:main | String.t()) :: String.t()
  def render(:main), do: @briefs["main"]
  def render(name) when name in ["build", "sniff", "review"], do: @briefs[name]

  @spec review_rules() :: String.t()
  def review_rules, do: @review_rules

  @doc "The flags that start Claude Code with the brief at `path`."
  @spec claude_args(Path.t()) :: [String.t()]
  def claude_args(path \\ @filename), do: ["--append-system-prompt-file", path]

  @doc """
  Write a mouse's brief into `worktree`. Git is told to ignore it first; that
  failing is said, as for the spec, and the brief is written all the same.
  Anything but a plain file at the path is refused.
  """
  @spec write(Path.t(), Path.t(), String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def write(main_checkout, worktree, name) do
    said =
      case Whiska.Spec.ignore(main_checkout, exclude_line()) do
        :ok ->
          []

        {:error, reason} ->
          ["whiska: could not make git ignore #{@filename} (#{inspect(reason)})."]
      end

    path = Path.join(worktree, @filename)

    with :ok <- plain_or_absent(path),
         :ok <- File.write(path, render(name)),
         do: {:ok, said}
  end

  # A worktree holds whatever the repo committed, a link included, and a write
  # through one would land in whatever it points at.
  defp plain_or_absent(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} -> :ok
      {:ok, %File.Stat{}} -> {:error, :not_a_plain_file}
      {:error, :enoent} -> :ok
      {:error, _} = error -> error
    end
  end

  @doc "Whether any of `processes` is a Claude started with the brief at `path`."
  @spec started_with?([%{argv: [String.t()]}], Path.t()) :: boolean()
  def started_with?(processes, path) do
    Enum.any?(processes, fn %{argv: argv} ->
      argv |> Enum.chunk_every(2, 1) |> Enum.member?(claude_args(path))
    end)
  end

  @doc "Where the main session's brief is written, in the house of `main_checkout`."
  @spec main_path(Path.t()) :: Path.t()
  def main_path(main_checkout),
    do: main_checkout |> Whiska.Storage.database_path() |> Path.dirname() |> Path.join("main.md")

  @doc "Write the main session's brief into the house. Answers its path."
  @spec write_main(Path.t()) :: {:ok, Path.t()} | {:error, term()}
  def write_main(main_checkout) do
    path = main_path(main_checkout)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, render(:main)) do
      {:ok, path}
    end
  end
end
