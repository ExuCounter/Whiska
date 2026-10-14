defmodule Whiska.PR do
  @moduledoc """
  `whiska pr`: push a finished branch by its name and open a merge request for
  it through the forge its remote is on (`Whiska.Forge.opener/1`): `gh`, or
  `glab` where the remote is a GitLab one. The body is the
  mouse's own message, which carries what the diff cannot; the title is the
  subject of the branch's first commit. The link is recorded on the mouse, so
  the owl watches the base for its merge and the branch's next finished line
  reads as one with a merge request open.

  A branch whose merge request is already open gets its new commits pushed to
  it instead, never forced. Files the mouse left uncommitted stop both, as for
  `whiska land`.

  A merge request is opened only here, on the person's word (ADR-0085). A tool
  missing or signed out is said, and nothing stands in for it.
  """

  alias Whiska.Forge
  alias Whiska.Git
  alias Whiska.Land
  alias Whiska.Report
  alias Whiska.Schema.Mouse
  alias Whiska.Schema.Question
  alias Whiska.Storage

  @doc "Open `question`'s mouse's merge request from `main_checkout`, committing first with the message in `commit`."
  @spec run(Path.t(), Mouse.t(), Question.t(), Path.t() | nil) ::
          {:ok, String.t()} | {:error, String.t()}
  def run(main_checkout, %Mouse{} = mouse, %Question{} = question, commit) do
    with :ok <- Land.commit_left(main_checkout, mouse, commit, "pr") do
      case mouse.merge_request_url do
        nil -> open(main_checkout, mouse, question)
        url -> push_more(mouse, url)
      end
    end
  end

  @doc "A link Whiska records: plain https, with nothing a shell or a terminal would act on."
  @spec link?(String.t()) :: boolean()
  def link?(url),
    do: Regex.match?(~r|\Ahttps://[A-Za-z0-9.-]+(:[0-9]+)?(/[^\s()\[\]<>"'`\\\p{C}]*)?\z|u, url)

  defp push_more(mouse, url) do
    with :ok <- push(mouse, []) do
      {:ok, "Pushed #{mouse.branch}'s new commits to its merge request, #{url}."}
    end
  end

  defp open(main_checkout, mouse, question) do
    with {:ok, %{base: base, commits: [first | _]}} <- own_commits(main_checkout, mouse),
         {:ok, title} <- subject(main_checkout, first),
         {:ok, forge} <- Forge.opener(main_checkout),
         :ok <- push(mouse, ["-u"]),
         {:ok, url} <-
           create(forge, main_checkout, mouse.branch, base, title, Report.text(question.text)),
         :ok <- record(mouse, url) do
      {:ok,
       "Opened #{url} for #{mouse.branch}. The owl takes the worktree down once it is " <>
         "merged into #{base}."}
    end
  end

  defp own_commits(main_checkout, mouse) do
    case Git.own_commits(main_checkout, mouse.branch, mouse.base) do
      {:ok, %{commits: []} = own} ->
        {:error, "#{mouse.branch} has nothing beyond #{own.base}."}

      {:ok, own} ->
        {:ok, own}

      {:error, reason} ->
        {:error, "could not read #{mouse.branch}'s commits (#{inspect(reason)})."}
    end
  end

  defp subject(main_checkout, commit) do
    case git(main_checkout, ["log", "-1", "--format=%s", commit]) do
      {out, 0} -> {:ok, String.trim(out)}
      {out, _} -> {:error, "could not read #{commit}'s subject: #{String.trim(out)}"}
    end
  end

  defp push(%Mouse{path: path, branch: branch}, flags) do
    case git(path, ["push" | flags] ++ ["origin", "refs/heads/#{branch}:refs/heads/#{branch}"]) do
      {_, 0} -> :ok
      {out, _} -> {:error, "git would not push #{branch}: #{String.trim(out)}"}
    end
  end

  defp create(forge, main_checkout, branch, base, title, body) do
    name = "whiska-pr-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    file = Path.join(System.tmp_dir!(), name <> ".md")

    case File.write(file, body, [:exclusive]) do
      :ok ->
        try do
          open(forge, main_checkout, branch, base, title, file)
        after
          File.rm(file)
        end

      {:error, reason} ->
        {:error, "#{branch} is pushed, but its description could not be written (#{reason})."}
    end
  end

  defp open(forge, main_checkout, branch, base, title, file) do
    with {:ok, args} <- forge.create_args(main_checkout, branch, base, title, file) do
      case System.cmd(Forge.CLI.find(forge.tool()), args,
             cd: main_checkout,
             stderr_to_stdout: true
           ) do
        {out, 0} -> forge.link(out)
        {out, _} -> {:error, "#{branch} is pushed, but #{forge.tool()} said: #{String.trim(out)}"}
      end
    end
  end

  defp record(mouse, url) do
    with true <-
           link?(url) ||
             {:error, "opened #{url}, which is not a plain https link, so it is not recorded."},
         {:ok, _} <- Storage.record_merge_request(mouse.mouse_id, url) do
      :ok
    else
      {:error, message} when is_binary(message) -> {:error, message}
      {:error, reason} -> {:error, "opened #{url}, but could not record it (#{inspect(reason)})."}
    end
  end

  defp git(dir, args), do: System.cmd("git", args, cd: dir, stderr_to_stdout: true)
end
