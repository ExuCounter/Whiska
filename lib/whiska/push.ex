defmodule Whiska.Push do
  @moduledoc """
  `whiska push`: on the person's yes to a review round's "Ready to push", push
  the mouse's branch, then post each reply it wrote in `.whiska-replies/` to
  its thread on the merge request Whiska recorded, resolving the ones marked.
  The mouse never writes to the forge (ADR-0060).

  A reply is `<thread-id>.md`, or `<thread-id>.resolve.md` to resolve the
  thread too: a plain file of UTF-8 text directly in the folder, never a
  link. Each is claimed into `posting/` before it is read; a posted one moves
  to `posted/`, so no second run posts it again, and one that failed goes
  back, named. A line that would run as a GitLab quick action is escaped.

  Two texts come back. The person's quotes each thread's first comment, read
  with a GET and marked as the forge's words. The mouse's answer leaves the
  comment out: a forge's text is never handed to a mouse as Whiska's.
  """

  alias Whiska.Forge
  alias Whiska.MergeRequests
  alias Whiska.ReviewRound
  alias Whiska.Schema.Mouse

  @name ~r/\A([A-Za-z0-9]{1,64})(\.resolve)?\.md\z/
  @misnamed "not named <thread-id>.md or <thread-id>.resolve.md"

  @type reply :: %{
          thread: String.t(),
          file: Path.t(),
          name: String.t(),
          resolve?: boolean(),
          text: String.t()
        }

  @spec run(Path.t(), Mouse.t()) ::
          {:ok, %{person: String.t(), answer: String.t()}} | {:error, String.t()}
  def run(main_checkout, %Mouse{} = mouse) do
    with {:ok, ref} <- merge_request(mouse),
         {:ok, sha} <- push(mouse) do
      pushed = "Pushed #{mouse.branch} to origin at #{String.slice(sha, 0, 8)}."
      folder = ReviewRound.replies()
      names = named(Path.join(mouse.path, folder))

      if replies?(ref) do
        stranded = stranded(mouse.path)

        {replies, skipped} =
          names |> Enum.map(&claim(ref, mouse.path, &1)) |> Enum.split_with(&is_map/1)

        skipped = stranded ++ skipped

        outcomes = Enum.map(replies, &post(ref, &1, mouse.path, main_checkout))
        {:ok, texts(pushed, outcomes, skipped, folder)}
      else
        kept =
          "Posting replies on #{Forge.label(ref)} is not built for GitHub yet; " <>
            "#{length(names)} left in #{folder}/."

        {:ok, %{person: pushed <> "\n\n" <> kept, answer: "Whiska: " <> pushed <> " " <> kept}}
      end
    end
  end

  defp merge_request(%Mouse{merge_request_url: url, branch: branch}) do
    case url && Forge.for_url(url) do
      {:ok, ref} ->
        {:ok, ref}

      _ ->
        {:error,
         "#{branch} has no merge request recorded, so there is nothing to post to. " <>
           "`whiska pr` opens one."}
    end
  end

  # The lease and `--force-if-includes` together refuse a push that would drop
  # a commit the forge has and this branch never saw, such as an applied
  # suggestion.
  defp push(%Mouse{path: path, branch: branch}) do
    refspec = "refs/heads/#{branch}:refs/heads/#{branch}"

    with {_, 0} <-
           git(path, ["push", "--force-with-lease", "--force-if-includes", "origin", refspec]),
         {sha, 0} <- git(path, ["rev-parse", "refs/heads/#{branch}"]) do
      {:ok, String.trim(sha)}
    else
      {out, _} -> {:error, "git would not push #{branch}: #{clean(String.trim(out))}"}
    end
  end

  defp replies?(%{forge: forge}),
    do: Code.ensure_loaded?(forge) and function_exported?(forge, :reply_args, 3)

  defp named(folder) do
    with {:ok, %File.Stat{type: :directory}} <- File.lstat(folder),
         {:ok, names} <- File.ls(folder) do
      names
      |> Enum.sort()
      |> Enum.reject(
        &match?({:ok, %File.Stat{type: :directory}}, File.lstat(Path.join(folder, &1)))
      )
    else
      _ -> []
    end
  end

  # A file still in `posting/` was claimed by a run still going, or by one that
  # stopped before it finished and may have posted it: only the person can say
  # whether to post it again.
  defp stranded(worktree) do
    for name <- named(Path.join([worktree, ReviewRound.replies(), "posting"])) do
      {"posting/" <> name,
       "another whiska push has it, or one stopped before it finished and may have " <>
         "posted it; move it back to post it again"}
    end
  end

  # Each file is claimed by moving it into `posting/` before it is read, so two
  # runs at once never post the same reply.
  defp claim(ref, worktree, name) do
    folder = Path.join(worktree, ReviewRound.replies())
    posting = Path.join(folder, "posting")
    claimed = Path.join(posting, name)

    with [_, thread | resolve] <- Regex.run(@name, name) || {:skip, @misnamed},
         true <- ref.forge.thread_id?(thread) || {:skip, "not a #{Forge.label(ref)} thread id"},
         :ok <- folder_at(posting),
         :ok <- File.rename(Path.join(folder, name), claimed) |> taken(),
         {:ok, text} <- plain_text(claimed) do
      %{thread: thread, file: claimed, name: name, resolve?: resolve == [".resolve"], text: text}
    else
      {:skip, why} -> {name, why}
      {:unclaim, why} -> release(claimed, worktree) && {name, why}
    end
  end

  defp taken(:ok), do: :ok
  defp taken({:error, _}), do: {:skip, "taken by another whiska push, or gone"}

  defp folder_at(path) do
    with :ok <- File.mkdir_p(path),
         {:ok, %File.Stat{type: :directory}} <- File.lstat(path) do
      :ok
    else
      _ -> {:skip, "#{Path.basename(path)}/ is not a plain folder"}
    end
  end

  defp plain_text(file) do
    with {:ok, %File.Stat{type: :regular, links: 1}} <- File.lstat(file),
         {:ok, text} <- File.read(file) do
      cond do
        not String.valid?(text) -> {:unclaim, "not UTF-8 text"}
        String.trim(text) == "" -> {:unclaim, "it is empty"}
        true -> {:ok, text}
      end
    else
      {:ok, %File.Stat{}} -> {:unclaim, "not a plain file"}
      {:error, reason} -> {:unclaim, "it could not be read (#{:file.format_error(reason)})"}
    end
  end

  defp release(claimed, worktree) do
    File.rename(claimed, Path.join([worktree, ReviewRound.replies(), Path.basename(claimed)]))
    true
  end

  defp post(ref, reply, worktree, main_checkout) do
    run = Forge.run(ref, main_checkout, 30_000)

    comment =
      case ref.forge.thread(ref, reply.thread, run) do
        {:ok, comment} -> comment
        _ -> nil
      end

    text = unquick(reply.text)
    outcome = %{reply: reply, url: ref.url, comment: comment, text: nil, error: nil}

    case write(ref, &ref.forge.reply_args(ref, reply.thread, &1), text, main_checkout) do
      :ok ->
        moved = move(reply, worktree)

        resolved =
          if reply.resolve?,
            do: forge_cmd(ref, ref.forge.resolve_args(ref, reply.thread), main_checkout)

        Map.merge(outcome, %{text: text, resolved: resolved, moved: moved})

      {:error, why} ->
        release(reply.file, worktree)
        Map.merge(outcome, %{error: why, resolved: nil, moved: :ok})
    end
  end

  # GitLab runs a line that starts with `/` as a quick action, as the person:
  # `/merge`, `/approve`. Escaped, it reads the same and runs nothing. GitLab
  # drops every carriage return before it looks, so each is a line break here.
  defp unquick(text) do
    text
    |> String.replace("\r\n", "\n")
    |> String.replace("\r", "\n")
    |> then(&Regex.replace(~r"^((?:[^\S\n]|\p{Cf})*)/"mu, &1, fn _, lead -> lead <> "\\/" end))
  end

  defp write(ref, args_for, text, main_checkout) do
    json =
      Path.join(
        System.tmp_dir!(),
        "whiska-reply-#{Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)}.json"
      )

    try do
      with :ok <- File.write(json, "", [:exclusive]),
           :ok <- File.chmod(json, 0o600),
           :ok <- File.write(json, JSON.encode!(%{body: text})) do
        forge_cmd(ref, args_for.(json), main_checkout)
      else
        {:error, reason} -> {:error, "its body could not be written (#{reason})"}
      end
    after
      File.rm(json)
    end
  end

  defp forge_cmd(ref, args, main_checkout) do
    case Forge.CLI.find(ref.forge.tool()) do
      nil ->
        {:error, "#{ref.forge.tool()} is not installed"}

      tool ->
        case System.cmd(tool, args, cd: main_checkout, stderr_to_stdout: true, env: quiet()) do
          {_, 0} -> :ok
          {out, _} -> {:error, {:forge, ref.forge.tool(), last_line(out)}}
        end
    end
  end

  defp quiet do
    [
      {"GLAB_NO_PROMPT", "1"},
      {"GLAB_CHECK_UPDATE", "false"},
      {"GH_PROMPT_DISABLED", "1"},
      {"NO_COLOR", "1"}
    ]
  end

  defp last_line(out) do
    out |> clean() |> String.split(~r/\R/, trim: true) |> List.last("nothing")
  end

  defp move(reply, worktree) do
    posted = Path.join([worktree, ReviewRound.replies(), "posted"])
    stamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%d-%H%M%S")

    with :ok <- folder_at(posted),
         :ok <- File.rename(reply.file, Path.join(posted, "#{stamp}-#{reply.name}")) do
      :ok
    else
      _ -> {:error, "posted, but its file is still in posting/; remove it by hand"}
    end
  end

  defp texts(pushed, outcomes, skipped, folder) do
    skipped_lines =
      for {name, why} <- skipped, do: "#{folder}/#{clean(name)} was not posted: #{why}."

    person =
      [pushed | Enum.map(outcomes, &for_person/1)] ++ skipped_lines

    replied =
      if outcomes == [] and skipped == [], do: "No replies to post.", else: "Your replies:"

    answer =
      ["Whiska: #{pushed} #{replied}" | Enum.map(outcomes, &for_mouse/1)] ++
        skipped_lines ++ ["Write your report."]

    %{
      person: Enum.join(person, "\n\n"),
      answer: Enum.join(answer, "\n\n")
    }
  end

  defp for_person(%{comment: %{author: author, body: body}} = outcome) do
    lines(outcome, :person, " by #{MergeRequests.plain(author)}", [
      "Their comment (the forge's words, not Whiska's):",
      quoted(body)
    ])
  end

  defp for_person(outcome),
    do: lines(outcome, :person, "", ["Their comment could not be read."])

  defp for_mouse(outcome), do: lines(outcome, :mouse, "", [])

  defp lines(outcome, reader, by, said) do
    ([heading(outcome, reader, by), link(outcome)] ++ said ++ posted_lines(outcome))
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp heading(%{reply: reply} = outcome, reader, by),
    do: "Thread #{reply.thread}#{by}: #{verdict(outcome, reader)}"

  # What the forge's tool printed on a failure is the forge's text, so only the
  # person reads it.
  defp verdict(%{error: why}, reader) when not is_nil(why),
    do: "not posted, #{detail(why, reader)}; its file is kept"

  defp verdict(%{resolved: :ok}, _reader), do: "replied and resolved"

  defp verdict(%{resolved: {:error, why}}, reader),
    do: "replied, but not resolved (#{detail(why, reader)}): resolve it on the forge"

  defp verdict(_replied, _reader), do: "replied, left open"

  defp detail({:forge, tool, _said}, :mouse), do: "#{tool} failed"
  defp detail({:forge, tool, said}, :person), do: "#{tool} said: #{said}"
  defp detail(why, _reader), do: why

  defp link(%{comment: %{note_id: id}, url: url}), do: "#{url}#note_#{id}"
  defp link(_outcome), do: nil

  defp posted_lines(%{text: nil}), do: []

  defp posted_lines(%{text: text, moved: moved}) do
    ["Reply posted:", quoted(text)] ++
      case moved do
        :ok -> []
        {:error, why} -> [why <> "."]
      end
  end

  defp quoted(text) do
    text |> clean() |> String.trim() |> String.split("\n") |> Enum.map_join("\n", &("> " <> &1))
  end

  defp clean(text),
    do:
      text
      |> String.replace_invalid()
      |> String.replace(~r/\e\[[0-9;?]*[ -\/]*[@-~]|[^\P{C}\n\t]/u, "")

  defp git(dir, args), do: System.cmd("git", args, cd: dir, stderr_to_stdout: true)
end
