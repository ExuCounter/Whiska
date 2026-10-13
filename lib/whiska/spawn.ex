defmodule Whiska.Spawn do
  @moduledoc """
  `whiska spawn`: a fresh worktree with a mouse working in it, in one command.

  The main session names the mode, the branch and a file holding the task, and
  Whiska does the rest in a fixed order: herdr creates the worktree at
  `worktrees/<branch>` and opens it without moving the person's view; the
  mouse is recorded and shaped before Claude exists (ADR-0069), so its first
  tool call is already judged by its mode; Whiska's hooks are carried into a
  worktree whose repo never committed them; then Claude starts in the
  worktree's pane with the shape's flags and is handed its task.

  `--from <id>` builds what a finished investigation proposed (ADR-0074). Its
  task is fixed text naming the question, so nothing a mouse wrote reaches the
  new session as anything but what `whiska show` prints; the person's comments
  on the research document travel as a file in the new worktree.

  Everything that can be refused is refused before herdr is asked: a branch
  name outside `a-z`, `0-9`, `-` and `/`, longer than herdr's 32-character
  agent name, or already taken, and a task that cannot be read.
  """

  alias Whiska.Brief
  alias Whiska.Clone
  alias Whiska.Git
  alias Whiska.Letters
  alias Whiska.Layout
  alias Whiska.Marker
  alias Whiska.Schema.Question
  alias Whiska.Shape
  alias Whiska.Storage

  @kickoff "Start on the task in your Whiska brief."

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
  @spec run(Path.t(), request(), %{herdr: module(), socket: Path.t(), workspace: String.t() | nil}) ::
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
    with {:ok, text} <- Letters.read(file), do: {:ok, {:words, text}}
  end

  defp read_task({:from, id, comments}) do
    with {:ok, question} <- question(id),
         {:ok, _} <- comments_readable(comments) do
      {:ok, {:from, question.id, comments}}
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
      label: branch,
      workspace_id: via[:workspace]
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
         {:ok, _} <- record(mouse_id, layout, created.pane_id),
         {:ok, text} <- task_text(task, main_checkout, layout.worktree_root),
         {:ok, shaped} <- shape(mouse_id, layout, request.shape, text),
         :ok <- carry_hooks(main_checkout, layout.worktree_root),
         {:ok, _argv} <- start_claude(via, created.pane_id, request.branch, shaped.flags),
         :ok <- hand_over(via, created.pane_id, @kickoff) do
      {:ok, report(request, shaped)}
    else
      {:error, reason} ->
        {:error,
         "#{request.branch}'s worktree is at #{path}, but its mouse did not start: " <>
           "#{describe(reason)} `whiska drop #{request.branch}` takes it down."}
    end
  end

  defp record(mouse_id, layout, pane) do
    Storage.record_mouse(%{
      mouse_id: mouse_id,
      path: layout.worktree_root,
      branch: layout.branch_label,
      pane: pane
    })
  end

  @doc """
  Record a mouse's shape and get its worktree ready (ADR-0069, ADR-0083): its
  mode's brief written with `task` in it, git ignoring Whiska's files there,
  and the main checkout's dependencies cloned in. Answers the flags to start
  Claude with and the lines that say what was done; a failed clone or ignore
  is said, never a failure.
  """
  @spec shape(String.t(), Layout.t(), Shape.t(), String.t() | nil) ::
          {:ok, %{flags: [String.t()], said: [String.t()]}} | {:error, term()}
  def shape(mouse_id, layout, shape, task) do
    base = cut_from(layout.main_checkout)
    main = layout.main_checkout

    with {:ok, _} <- Storage.shape(mouse_id, shape.mode, shape.model, shape.effort, base),
         {:ok, brief_said} <- Brief.write(main, layout.worktree_root, shape.mode, task) do
      said =
        ["#{layout.branch_label} is #{Shape.describe(shape)}."] ++
          ignore_files(main) ++
          brief_said ++
          ["whiska: #{Clone.run(main, layout.worktree_root)}."]

      {:ok, %{flags: Shape.claude_args(shape) ++ Brief.claude_args(), said: said}}
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

  @doc """
  Make git ignore, in every worktree of this checkout, the files a mouse writes
  that are never committed. Answers a line for each that could not be.
  """
  @spec ignore_files(Path.t()) :: [String.t()]
  def ignore_files(main_checkout) do
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
  carried in from the main checkout's install and still as carried: local
  setup, not the mouse's work.
  """
  @spec carried?(Path.t(), Path.t(), String.t()) :: boolean()
  def carried?(main_checkout, worktree, rel) do
    (rel == ".claude/settings.json" or String.starts_with?(rel, ".claude/hooks/")) and
      same_file?(Path.join(main_checkout, rel), Path.join(worktree, rel))
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

  defp task_text({:words, text}, _main_checkout, _worktree), do: {:ok, String.trim(text)}

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

  defp hand_over(via, pane, text), do: via.herdr.prompt(via.socket, pane, text)

  @doc "herdr's name for the agent on `branch`: no `/`, which herdr refuses."
  @spec agent_name(String.t()) :: String.t()
  def agent_name(branch), do: String.replace(branch, "/", "-")

  defp report(%{branch: branch, shape: shape}, %{said: said}) do
    can =
      if shape.mode == "sniff",
        do: "it can only look, not change files",
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
