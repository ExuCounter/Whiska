defmodule Whiska.Spawn do
  @moduledoc """
  `whiska spawn`: a fresh worktree with a mouse working in it, in one command.

  The main session names the mode, the branch and a file holding the task, and
  Whiska does the rest in a fixed order: herdr creates the worktree at
  `worktrees/<branch>` and opens it without moving the person's view; the
  mouse is recorded and shaped before Claude exists (ADR-0069), so it starts
  with its mode's deny list; Whiska's hooks are carried into a
  worktree whose repo never committed them; then Claude starts in the
  worktree's pane with the shape's flags and the brief, and its task is typed
  there as its first prompt.

  `--from <id>` builds what a finished investigation proposed (ADR-0074). Its
  task is fixed text naming the question, so nothing a mouse wrote reaches the
  new session as anything but what `whiska show` prints; the person's comments
  on the research document travel as a file in the new worktree.

  Everything that can be refused is refused before herdr is asked: a branch
  name outside `a-z`, `0-9`, `-` and `/`, longer than herdr's 32-character
  agent name, or already taken, and a task that cannot be read or typed.
  """

  alias Whiska.Brief
  alias Whiska.Clone
  alias Whiska.DenyList
  alias Whiska.Git
  alias Whiska.Letters
  alias Whiska.Layout
  alias Whiska.Marker
  alias Whiska.Schema.Question
  alias Whiska.Shape
  alias Whiska.Storage

  # Claude Code reads a prompt that opens with `!` as a shell command, run
  # outside every hook, and one that opens with `/` as a slash command: no
  # task opens the prompt.
  @lead_in "Your task:\n\n"

  @branch ~r/\A[a-z][a-z0-9-]*(\/[a-z0-9][a-z0-9-]*)*\z/
  @longest 32

  @usage "expected whiska spawn build|sniff <branch> <task-file>, or " <>
           "whiska spawn build|sniff <branch> --from <id> [--comments <file>], " <>
           "each with [--model <name>] [--effort <level>]."

  @type task :: {:file, Path.t()} | {:from, String.t(), Path.t() | nil}
  @type request :: %{shape: Shape.t(), branch: String.t(), task: task()}

  @doc "Read `whiska spawn`'s arguments. Flags may come anywhere."
  @spec parse([String.t()]) :: {:ok, request()} | {:error, String.t()}
  def parse(args) do
    with {:ok, flags, positional} <- split(args, %{}, []),
         {:ok, mode, branch, task} <- positional(positional, flags),
         {:ok, shape} <- Shape.parse([mode | shape_flags(flags)]) do
      {:ok, %{shape: shape, branch: branch, task: task}}
    end
  end

  defp split([], flags, positional), do: {:ok, flags, Enum.reverse(positional)}

  defp split([flag, value | rest], flags, positional)
       when flag in ~w(--model --effort --from --comments) do
    if Map.has_key?(flags, flag),
      do: {:error, "#{flag} is named twice."},
      else: split(rest, Map.put(flags, flag, value), positional)
  end

  defp split(["-" <> _ = flag | _], _flags, _positional),
    do: {:error, "#{flag} is not a flag spawn takes; #{@usage}"}

  defp split([word | rest], flags, positional), do: split(rest, flags, [word | positional])

  defp positional([mode, branch, file], flags) when not is_map_key(flags, "--from") do
    if Map.has_key?(flags, "--comments"),
      do: {:error, "--comments goes with --from: they are comments on its research document."},
      else: {:ok, mode, branch, {:file, file}}
  end

  defp positional([mode, branch], %{"--from" => id} = flags),
    do: {:ok, mode, branch, {:from, id, flags["--comments"]}}

  defp positional(_other, _flags), do: {:error, @usage}

  defp shape_flags(flags) do
    for {flag, value} <- flags, flag in ~w(--model --effort), reduce: [] do
      acc -> acc ++ [flag, value]
    end
  end

  @doc """
  Spawn the mouse `request` describes, from `main_checkout`, whose house is
  open. Answers the report for the person, or why nothing was started.
  """
  @spec run(Path.t(), request(), %{herdr: module(), socket: Path.t()}) ::
          {:ok, String.t()} | {:error, String.t()}
  def run(main_checkout, %{branch: branch} = request, via) do
    path = Path.join([main_checkout, "worktrees", branch])

    with :ok <- plain_branch(branch),
         :ok <- free(main_checkout, branch, path),
         {:ok, task} <- read_task(request.task),
         {:ok, created} <- create(via, main_checkout, branch, path) do
      start(main_checkout, path, request, task, created, via)
    end
  end

  defp plain_branch(branch) do
    cond do
      not Regex.match?(@branch, branch) ->
        {:error,
         "#{inspect(branch)} is not a branch name spawn takes: lowercase letters, digits, " <>
           "- and /, starting with a letter."}

      String.length(branch) > @longest ->
        {:error, "#{branch} is longer than #{@longest} characters, which herdr shows."}

      true ->
        :ok
    end
  end

  defp free(main_checkout, branch, path) do
    cond do
      match?({:ok, _}, Git.branch_head(main_checkout, branch)) ->
        {:error,
         "#{branch} already exists. Every task gets a fresh branch; name another, " <>
           "or `whiska send` it to the mouse already on #{branch}."}

      File.exists?(path) ->
        {:error, "#{path} is already there. Name another branch."}

      true ->
        :ok
    end
  end

  defp read_task({:file, file}) do
    with {:ok, text} <- Letters.read(file),
         :ok <- typeable(text, file),
         do: {:ok, {:words, text}}
  end

  defp read_task({:from, id, comments}) do
    with {:ok, question} <- question(id),
         {:ok, _} <- comments_readable(comments) do
      {:ok, {:from, question.id, comments}}
    end
  end

  # herdr types the task as a bracketed paste while Claude Code takes one,
  # which a control character could end early, reaching Claude Code as
  # keystrokes rather than text.
  @untypeable ~r/[\x{0}-\x{8}\x{B}\x{C}\x{E}-\x{1F}\x{7F}-\x{9F}]/u

  defp typeable(text, file) do
    cond do
      not String.valid?(text) ->
        {:error, "#{file} is not UTF-8 text."}

      Regex.match?(@untypeable, text) ->
        {:error,
         "#{file} holds a control character, which would reach the mouse as keystrokes; " <>
           "only tabs and line breaks can be typed."}

      true ->
        :ok
    end
  end

  defp question(id) do
    with {n, ""} <- Integer.parse(id),
         %Question{} = question <- Storage.question(n) do
      {:ok, question}
    else
      _ -> {:error, "there is no question ##{id} in this house to build from."}
    end
  end

  defp comments_readable(nil), do: {:ok, nil}
  defp comments_readable(file), do: Letters.read(file)

  defp create(via, main_checkout, branch, path) do
    new = %{
      cwd: main_checkout,
      path: path,
      branch: branch,
      label: branch
    }

    case via.herdr.create_worktree(via.socket, new) do
      {:ok, created} -> {:ok, created}
      {:error, reason} -> {:error, "herdr could not create the worktree (#{inspect(reason)})."}
    end
  end

  # From here the worktree exists, so a failure says where it is: the person
  # decides whether to drop it or start Claude there by hand.
  defp start(main_checkout, path, request, task, created, via) do
    with {:ok, layout} <- Layout.resolve(path),
         {:ok, mouse_id} <- Marker.read_or_mint(layout.worktree_root),
         {:ok, _} <- record(mouse_id, layout, created.pane_id, built_from(request.shape, task)),
         {:ok, text} <- task_text(task, main_checkout, layout.worktree_root),
         {:ok, shaped} <- shape(mouse_id, layout, request.shape),
         :ok <- carry_hooks(main_checkout, layout.worktree_root),
         {:ok, _argv} <- start_claude(via, created.pane_id, request.branch, shaped.flags) do
      case hand_over(via, created.pane_id, @lead_in <> text) do
        :ok -> {:ok, report(request, shaped)}
        {:error, reason} -> {:error, untyped(request, path, reason)}
      end
    else
      {:error, reason} ->
        {:error,
         "#{request.branch}'s worktree is at #{path}, but its mouse did not start: " <>
           "#{describe(reason)} `whiska drop #{request.branch}` takes it down."}
    end
  end

  defp untyped(%{branch: branch, task: task}, path, reason) do
    file =
      case task do
        {:file, file} -> file
        {:from, _id, _comments} -> "<file>, the task written to it,"
      end

    "#{branch}'s mouse started in #{path}, but Whiska could not hand it its task: " <>
      "#{describe(reason)} If its pane does not show the task, once anything Claude shows " <>
      "there is answered, `whiska send #{branch} #{file}` hands it over; " <>
      "`whiska drop #{branch}` takes it down."
  end

  defp record(mouse_id, layout, pane, built_from) do
    Storage.record_mouse(%{
      mouse_id: mouse_id,
      path: layout.worktree_root,
      branch: layout.branch_label,
      pane: pane,
      built_from: built_from
    })
  end

  defp built_from(%{mode: "build"}, {:from, id, _comments}), do: id
  defp built_from(_shape, _task), do: nil

  @doc """
  Record a mouse's shape and get its worktree ready (ADR-0069, ADR-0083): its
  mode's brief written, its mode's deny list beside it (ADR-0090), git ignoring
  Whiska's files there, and the main checkout's dependencies cloned in. Answers
  the flags to start Claude with and the lines that say what was done; a failed
  clone or ignore is said, never a failure.
  """
  @spec shape(String.t(), Layout.t(), Shape.t()) ::
          {:ok, %{flags: [String.t()], said: [String.t()]}} | {:error, term()}
  def shape(mouse_id, layout, shape) do
    base = cut_from(layout.main_checkout)
    main = layout.main_checkout
    worktree = layout.worktree_root

    # Recorded last, so a mouse is never shaped on record without its deny list.
    with {:ok, brief_said} <- Brief.write(main, worktree, shape.mode),
         {:ok, deny_said} <- DenyList.write(main, worktree, shape.mode),
         {:ok, _} <- Storage.shape(mouse_id, shape.mode, shape.model, shape.effort, base) do
      said =
        ["#{layout.branch_label} is #{Shape.describe(shape)}."] ++
          ignore_files(main) ++
          brief_said ++
          deny_said ++
          ["whiska: #{Clone.run(main, worktree)}."]

      flags = Shape.claude_args(shape) ++ DenyList.claude_args() ++ Brief.claude_args()
      {:ok, %{flags: flags, said: said}}
    end
  end

  # The branch the main checkout is on is the one the worktree was just cut
  # from, which is what the mouse's branch is measured against. A detached
  # head names none, and the mouse is read against the default branch.
  defp cut_from(main_checkout) do
    case Git.head_branch(main_checkout) do
      {:ok, branch} -> branch
      {:error, _} -> nil
    end
  end

  # Makes git ignore, in every worktree of this checkout, the files a mouse
  # writes that are never committed. Answers a line for each that could not be.
  defp ignore_files(main_checkout) do
    for {name, line} <- [
          {Whiska.Spec.filename(), Whiska.Spec.exclude_line()},
          {Whiska.Research.filename(), Whiska.Research.exclude_line()},
          {Whiska.BuildPlan.filename(), Whiska.BuildPlan.exclude_line()}
        ],
        {:error, reason} <- [Whiska.Spec.ignore(main_checkout, line)] do
      "whiska: could not make git ignore #{name} (#{inspect(reason)})."
    end
  end

  # A worktree holds only committed files, so where the repo never committed
  # its `.claude/`, a mouse there would have no `Stop` hook and the owl would
  # never see it finish or ask. The hooks and their settings, nothing else.
  defp carry_hooks(main_checkout, worktree) do
    from = Path.join(main_checkout, ".claude")
    to = Path.join(worktree, ".claude")

    if File.regular?(Path.join(main_checkout, Whiska.Install.shim_path())) and
         File.regular?(Path.join(from, "settings.json")) and
         not File.exists?(Path.join(to, "settings.json")) do
      with :ok <- File.mkdir_p(to),
           {:ok, _} <- File.cp_r(Path.join(from, "hooks"), Path.join(to, "hooks")),
           do: File.cp(Path.join(from, "settings.json"), Path.join(to, "settings.json"))
    else
      :ok
    end
  end

  @doc """
  Whether `rel`, a file not committed in `worktree`, is one of the hook files
  carried in from the main checkout's install, untracked and still as carried: local
  setup, not the mouse's work.
  """
  @spec carried?(Path.t(), Path.t(), String.t()) :: boolean()
  def carried?(main_checkout, worktree, rel) do
    (rel == ".claude/settings.json" or String.starts_with?(rel, ".claude/hooks/")) and
      same_file?(Path.join(main_checkout, rel), Path.join(worktree, rel)) and
      not Git.tracked?(worktree, rel)
  end

  defp same_file?(a, b) do
    with {:ok, %File.Stat{type: :regular}} <- File.lstat(a),
         {:ok, %File.Stat{type: :regular}} <- File.lstat(b),
         {:ok, text} <- File.read(a),
         {:ok, ^text} <- File.read(b) do
      true
    else
      _ -> false
    end
  end

  # Outside a bracketed paste a carriage return is Enter.
  defp task_text({:words, text}, _main_checkout, _worktree),
    do: {:ok, text |> String.replace(~r/\r\n?/, "\n") |> String.trim()}

  defp task_text({:from, id, comments}, main_checkout, worktree) do
    proposal =
      "Build what question ##{id} proposes under \"What to change\", in the research " <>
        "document `whiska show #{id}` links: its Build line is the task, Found is fact to " <>
        "take as given, Open is what to grill."

    case comments do
      nil ->
        {:ok, proposal}

      file ->
        with {:ok, copy} <- Letters.put(main_checkout, worktree, file) do
          {:ok,
           proposal <>
             " Then read the person's comments on that research document, in their own " <>
             "words, in #{copy}."}
        end
    end
  end

  defp start_claude(via, pane, branch, flags),
    do: via.herdr.start_agent(via.socket, pane, agent_name(branch), flags)

  # herdr answers agent.start a moment before it lists the new claude under
  # its name, and refuses a prompt in between: the kickoff waits that out.
  @kickoff_tries 20
  @kickoff_pause 250

  defp hand_over(via, pane, text, tries \\ @kickoff_tries) do
    case via.herdr.prompt(via.socket, pane, text) do
      {:error, {:herdr, %{"code" => "agent_not_ready"}}} when tries > 1 ->
        Process.sleep(@kickoff_pause)
        hand_over(via, pane, text, tries - 1)

      answer ->
        answer
    end
  end

  @doc "herdr's name for the agent on `branch`: no `/`, which herdr refuses."
  @spec agent_name(String.t()) :: String.t()
  def agent_name(branch), do: String.replace(branch, "/", "-")

  defp report(%{branch: branch, shape: shape}, %{said: said}) do
    can =
      if shape.mode == "sniff",
        do: "it is told only to look, and has no tools to edit files",
        else: "it can change files"

    cloned = said |> List.last() |> String.replace_prefix("whiska: ", "")

    "Spawned #{branch} in worktrees/#{branch}: #{Shape.describe(shape)}; #{can}. " <>
      "Whiska #{cloned} It works on its own, and Whiska delivers its question when it has one."
  end

  defp describe({:herdr, %{"code" => code, "message" => message}}),
    do: "herdr said #{code}: #{message}."

  defp describe(:not_in_worktree), do: "Whiska does not read it as a worktree."
  defp describe(reason), do: "#{inspect(reason)}."
end
