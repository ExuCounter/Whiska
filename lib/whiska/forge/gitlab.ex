defmodule Whiska.Forge.GitLab do
  @moduledoc """
  GitLab, through `glab`: reading a merge request with `glab api` GETs, and
  opening one with `glab mr create`.

  The merge request itself is one GET, and carries `user_notes_count` and
  `updated_at`, so the discussions, which can run to pages, are read only when
  one of those moved ([GitLab merge requests API](https://docs.gitlab.com/api/merge_requests/)).
  """

  @behaviour Whiska.Forge
  @behaviour Whiska.Forge.Opener

  alias Whiska.Forge
  alias Whiska.Forge.CLI

  @link ~r"\Ahttps://([A-Za-z0-9][A-Za-z0-9.-]*(?::[0-9]{1,5})?)/([A-Za-z0-9._-]+(?:/[A-Za-z0-9._-]+)+)/-/merge_requests/([0-9]+)/?\z"

  # A merge request's discussions are read 100 to a page; this many pages is
  # far past any review, and a forge paging forever is cut off there.
  @pages 20

  # The largest integer the house's SQLite stores; a forge's number past it
  # would stop the read from being kept.
  @largest 9_223_372_036_854_775_807

  defguardp number?(n) when is_integer(n) and n >= 0 and n <= @largest

  @running ~w(created waiting_for_resource preparing pending running scheduled)

  @impl true
  def tool, do: "glab"

  @impl Whiska.Forge
  def parse(url) do
    case Regex.run(@link, url) do
      [_, host, project, number] ->
        {:ok,
         %{
           forge: __MODULE__,
           host: host,
           project: project,
           number: String.to_integer(number),
           url: url
         }}

      nil ->
        :error
    end
  end

  @impl Whiska.Forge
  def label(%{number: number}), do: "!#{number}"

  @impl Whiska.Forge
  def merge_request(ref, run) do
    with {:ok, body, _headers} <- CLI.get(run, ref.host, merge_request_path(ref)) do
      snapshot(body)
    end
  end

  @impl Whiska.Forge
  def notes(ref, run), do: discussions(ref, run, 1, [])

  @impl Whiska.Forge
  def member?(ref, user_id, run) when is_integer(user_id) do
    case CLI.get(run, ref.host, "#{project_path(ref)}/members/all/#{user_id}") do
      {:ok, _member, _headers} -> {:ok, true}
      :missing -> {:ok, false}
      unknown -> unknown
    end
  end

  @impl Whiska.Forge
  def me(ref, run), do: user(run, ref.host)

  @impl Whiska.Forge
  def project_readable?(ref, run) do
    case CLI.get(run, ref.host, project_path(ref)) do
      {:ok, _project, _headers} -> {:ok, true}
      :missing -> {:ok, false}
      unknown -> unknown
    end
  end

  @impl Whiska.Forge.Opener
  def create_args(main_checkout, branch, base, title, file) do
    with {:ok, %{username: username}} <- signed_in(main_checkout) do
      {:ok,
       ["mr", "create", "--assignee", username, "--source-branch", branch] ++
         ["--target-branch", base, "--title", title, "--description-file", file, "--yes"]}
    end
  end

  @impl Whiska.Forge.Opener
  def link(out) do
    case Regex.scan(~r|https://\S+|, out) |> List.last() do
      [url] -> {:ok, url}
      nil -> {:error, "glab printed no link:\n\n#{String.trim(out)}"}
    end
  end

  defp signed_in(main_checkout) do
    run = %{tool: CLI.find("glab"), cwd: main_checkout, timeout_ms: 30_000}

    with host when is_binary(host) <- Forge.origin_host(main_checkout),
         {:ok, user} <- user(run, host) do
      {:ok, user}
    else
      _ ->
        {:error, "glab is not signed in, so the branch is pushed but no merge request is open."}
    end
  end

  defp user(run, host) do
    with {:ok, body, _headers} <- CLI.get(run, host, "user") do
      case body do
        %{"id" => id, "username" => username} when number?(id) and is_binary(username) ->
          {:ok, %{id: id, username: username}}

        _ ->
          {:unknown, :unreadable_user, nil}
      end
    end
  end

  defp project_path(ref), do: "projects/" <> URI.encode(ref.project, &URI.char_unreserved?/1)

  defp merge_request_path(ref), do: "#{project_path(ref)}/merge_requests/#{ref.number}"

  defp snapshot(%{"state" => state, "user_notes_count" => count} = body)
       when is_binary(state) and number?(count) do
    {:ok,
     %{
       state: state(state),
       head_sha: string(body["sha"]),
       pipeline: pipeline(body["head_pipeline"]),
       notes_count: count,
       updated_at: string(body["updated_at"]),
       source_branch: string(body["source_branch"]),
       ready?: body["detailed_merge_status"] == "mergeable"
     }}
  end

  defp snapshot(_body), do: {:unknown, :unreadable_merge_request, nil}

  # `locked` is GitLab's word for a merge request in the middle of merging.
  defp state("merged"), do: :merged
  defp state("closed"), do: :closed
  defp state(_opened_or_locked), do: :open

  defp pipeline(%{"id" => id, "status" => status} = pipeline) when number?(id) do
    %{id: id, status: pipeline_status(status), sha: string(pipeline["sha"])}
  end

  defp pipeline(_none), do: nil

  defp pipeline_status("success"), do: :passed
  defp pipeline_status("failed"), do: :failed
  defp pipeline_status(status) when status in @running, do: :running
  defp pipeline_status(_canceled_skipped_manual), do: :other

  defp string(value) when is_binary(value), do: value
  defp string(_value), do: nil

  defp discussions(_ref, _run, page, _read) when page > @pages,
    do: {:unknown, :too_many_pages, nil}

  defp discussions(ref, run, page, read) do
    path = "#{merge_request_path(ref)}/discussions?per_page=100&page=#{page}"

    with {:ok, body, headers} <- CLI.get(run, ref.host, path),
         true <- is_list(body) || {:unknown, :unreadable_discussions, nil} do
      read = read ++ body

      case Integer.parse(Map.get(headers, "x-next-page", "")) do
        {next, ""} when next > page -> discussions(ref, run, next, read)
        _last -> threads(read)
      end
    end
  end

  defp threads(discussions) do
    discussions = Enum.filter(discussions, &is_map/1)

    # GitLab says whether a thread is resolved on each of its notes.
    open =
      Enum.count(discussions, fn discussion ->
        Enum.any?(
          List.wrap(discussion["notes"]),
          &(is_map(&1) and &1["resolvable"] == true and &1["resolved"] != true)
        )
      end)

    notes =
      for discussion <- discussions,
          %{"id" => id, "author" => %{"id" => author_id, "username" => author}} = note <-
            List.wrap(discussion["notes"]),
          number?(id) and number?(author_id) and is_binary(author),
          do: %{id: id, author_id: author_id, author: author, system?: note["system"] == true}

    {:ok, %{threads_open: open, notes: notes}}
  end
end
