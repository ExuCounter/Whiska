defmodule Whiska.Forge.GitLab do
  @moduledoc """
  GitLab, through `glab`: reading a merge request with `glab api` GETs,
  opening one with `glab mr create`, and replying on and resolving its threads
  with `glab api` POST and PUT.

  The merge request itself is one GET, and carries `user_notes_count` and
  `updated_at`, so the discussions, which can run to pages, are read only when
  one of those moved ([GitLab merge requests API](https://docs.gitlab.com/api/merge_requests/)).
  """

  @behaviour Whiska.Forge
  @behaviour Whiska.Forge.Opener
  @behaviour Whiska.Forge.Replier

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

  @no_blocker ~w(mergeable ci_must_pass ci_still_running checking unchecked
                 approvals_syncing preparing not_open requested_changes)

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

  # One GET for the open merge requests from `branch`, whatever they merge
  # into; one into `base` first. Only one from this project itself, never a
  # fork's branch of the same name, and only a link of its own shape on its own
  # host: it is recorded on the mouse, and read every minute after (ADR-0060).
  @impl Whiska.Forge
  def open_from(project, branch, base, run) do
    query = URI.encode_query([{"source_branch", branch}, {"state", "opened"}], :rfc3986)

    with {:ok, body, _headers} <-
           CLI.get(run, project.host, "#{project_path(project)}/merge_requests?#{query}") do
      if is_list(body) do
        opened =
          for request <- body, url = opened_from(request, project, branch), do: {request, url}

        case Enum.find(opened, fn {request, _url} -> request["target_branch"] == base end) ||
               List.first(opened) do
          {_request, url} -> {:ok, url}
          nil -> {:ok, nil}
        end
      else
        {:unknown, :unreadable_merge_requests, nil}
      end
    end
  end

  defp opened_from(
         %{
           "web_url" => url,
           "source_branch" => branch,
           "source_project_id" => id,
           "target_project_id" => id
         },
         project,
         branch
       )
       when is_binary(url) and is_integer(id) do
    case parse(url) do
      {:ok, %{host: host, project: name}} ->
        if String.downcase(host) == String.downcase(project.host) and
             String.downcase(name) == String.downcase(project.project),
           do: url

      _ ->
        nil
    end
  end

  defp opened_from(_other, _project, _branch), do: nil

  @impl Whiska.Forge.Opener
  def create_args(main_checkout, branch, base, title, file) do
    with {:ok, %{username: username}} <- signed_in(main_checkout) do
      {:ok,
       ["mr", "create", "--assignee", username, "--source-branch", branch] ++
         ["--target-branch", base, "--title", title, "--description-file", file, "--yes"]}
    end
  end

  @impl Whiska.Forge.Opener
  def browse_args(%{host: host, project: project, number: number}),
    do: ["mr", "view", Integer.to_string(number), "--web", "--repo", "https://#{host}/#{project}"]

  @impl Whiska.Forge.Opener
  def link(out) do
    case Regex.scan(~r|https://\S+|, out) |> List.last() do
      [url] -> {:ok, url}
      nil -> {:error, "glab printed no link:\n\n#{String.trim(out)}"}
    end
  end

  @impl Whiska.Forge.Replier
  def reply_args(ref, thread_id, json_file) do
    ~w(api --method POST --hostname) ++
      [ref.host, "--header", "Content-Type:application/json", "--input", json_file] ++
      ["#{discussion_path(ref, thread_id)}/notes"]
  end

  @impl Whiska.Forge.Replier
  def resolve_args(ref, thread_id),
    do:
      ~w(api --method PUT --hostname) ++
        [ref.host, "#{discussion_path(ref, thread_id)}?resolved=true"]

  @impl Whiska.Forge.Replier
  def thread_id?(id), do: id =~ ~r/\A[0-9a-f]{40}\z/

  @impl Whiska.Forge.Replier
  def thread(ref, thread_id, run) do
    with {:ok, body, _headers} <- CLI.get(run, ref.host, discussion_path(ref, thread_id)) do
      case body do
        %{"notes" => [%{"id" => id, "body" => text, "author" => %{"username" => author}} | _]}
        when number?(id) and is_binary(text) and is_binary(author) ->
          {:ok, %{author: author, body: text, note_id: id}}

        _ ->
          {:unknown, :unreadable_discussion, nil}
      end
    end
  end

  defp discussion_path(ref, thread_id), do: "#{merge_request_path(ref)}/discussions/#{thread_id}"

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
       ready?: body["detailed_merge_status"] == "mergeable",
       blocker: blocker(body["detailed_merge_status"])
     }}
  end

  defp snapshot(_body), do: {:unknown, :unreadable_merge_request, nil}

  # GitLab names one blocker at a time
  # ([detailed_merge_status](https://docs.gitlab.com/api/merge_requests/#merge-status)).
  # The pipeline's own say, GitLab still checking, and a request no longer
  # open are no blocker: the row says those otherwise. `requested_changes` is
  # none too: the open threads, counted apart, say what is asked. Every other
  # documented status is a rule that stops the merge with no word of its own,
  # so the generic `:blocked`, and so is one GitLab adds later.
  defp blocker("not_approved"), do: :approval
  defp blocker("conflict"), do: :conflict
  defp blocker("draft_status"), do: :draft
  defp blocker("discussions_not_resolved"), do: :threads
  defp blocker("need_rebase"), do: :rebase
  defp blocker(status) when status in @no_blocker, do: nil
  defp blocker(status) when is_binary(status), do: :blocked
  defp blocker(_none), do: nil

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

    notes =
      for discussion <- discussions,
          %{"id" => id, "author" => %{"id" => author_id, "username" => author}} = note <-
            List.wrap(discussion["notes"]),
          number?(id) and number?(author_id) and is_binary(author),
          do: %{
            id: id,
            author_id: author_id,
            author: author,
            system?: note["system"] == true,
            discussion_id: discussion_id(discussion["id"]),
            open?: open?(discussion)
          }

    {:ok, %{threads_open: Enum.count(discussions, &open?/1), notes: notes}}
  end

  # GitLab says whether a thread is resolved on each of its notes.
  defp open?(discussion) do
    Enum.any?(
      List.wrap(discussion["notes"]),
      &(is_map(&1) and &1["resolvable"] == true and &1["resolved"] != true)
    )
  end

  # A thread's id goes into the letter a mouse is woken with, so only an id
  # shaped like GitLab's own is kept: anything else is the forge's text.
  defp discussion_id(id) when is_binary(id) do
    if id =~ ~r/\A[A-Za-z0-9]{1,64}\z/, do: id
  end

  defp discussion_id(_none), do: nil
end
