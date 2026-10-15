defmodule Whiska.Restart do
  @moduledoc """
  Starting a mouse again that herdr restored without its launch flags
  (ADR-0044's exception for it, ADR-0069, ADR-0090).

  When herdr's server restarts it resumes every Claude pane as a bare
  `claude --resume <id>`. The session keeps its conversation and loses the
  rest of the launch line: bypass mode, the deny list, the model, the effort,
  the auto-compact window and the brief. A mouse that comes back that way runs
  under the person's default mode, where Claude Code's classifier blocks work
  a mouse is meant to do. No Whiska path resumes a mouse: `whiska spawn` and a
  review mouse's start launch with the full flags, and everything else only
  types a line into a pane that exists.

  So one pass over this house's mice, run before anything is typed into them:
  a shaped mouse whose Claude runs without its flags gets `/exit` typed into
  its pane and is started again as `claude --resume <its session> <its flags>`,
  the flags rebuilt as spawn builds them (`Whiska.Spawn.launch_flags/1`) from
  its record and the brief and deny list already in its worktree. Neither file
  is written again, so a review mouse keeps its review brief.

  **Unknown is never permission**, as for a pickup (ADR-0061, ADR-0067): a
  pane that is not idle, has no session id of a plain shape, shows a draft in
  its prompt box or one that cannot be read, or has no `claude` process whose
  arguments herdr gives is left alone, and so is a worktree herdr does not list
  for this checkout. Each verdict is taken again, from herdr's own word on the
  pane, just before `/exit`, since the restarts before it take seconds. A mouse
  seen with its flags is forgotten, so a second herdr restart in one owl run is
  repaired too. The main session's pane is never
  touched. One attempt per mouse per owl run, whatever came of it, and at most
  `@per_sweep` mice in a sweep (a pane that turns out busy at the re-check costs
  none of them), since each blocks the owl while Claude exits
  and boots; the rest follow on the next backstop.
  """

  alias Whiska.Brief
  alias Whiska.DenyList
  alias Whiska.Delivery.Draft
  alias Whiska.MousePane
  alias Whiska.Schema.Mouse
  alias Whiska.Spawn
  alias Whiska.Storage

  @ready ~w(idle done)
  @per_sweep 3
  @exit_tries 40
  @start_tries 40

  @typedoc "What one sweep did about one mouse."
  @type outcome ::
          :restarted
          | {:left,
             atom()
             | {:not_ready, String.t()}
             | {:refused, term()}
             | {:start_refused, term()}}

  @doc """
  One pass over every mouse of this house, answering what became of each.

  Keys: `:main_checkout`, `:herdr`, `:socket`, `:panes` (herdr's last full
  answer, which the house already holds), `:main_pane`, `:restarted` (the mouse
  ids already tried by this owl), and optionally `:pause_ms` between polls.
  """
  @spec sweep(map()) :: [{String.t(), outcome()}]
  def sweep(%{panes: {:ok, panes}} = house) do
    judged =
      for mouse <- Enum.reject(Storage.alive_mice(), & &1.removed_at) do
        {mouse, verdict(mouse, panes, house)}
      end

    ours =
      if Enum.any?(judged, &match?({_mouse, {:ok, _pane}}, &1)),
        do: MousePane.our_worktrees(house),
        else: :unknown

    {outcomes, _done} =
      Enum.map_reduce(judged, 0, fn {mouse, v}, done ->
        {outcome, done} = act(mouse, v, ours, done, house)
        {{mouse.mouse_id, outcome}, done}
      end)

    outcomes
  end

  def sweep(_no_panes), do: []

  @doc "The launch line with the resume id in front, as `claude` is started again."
  @spec args(String.t(), Mouse.t()) :: [String.t()]
  def args(session, %Mouse{mode: mode, model: model, effort: effort}),
    do: ["--resume", session | Spawn.launch_flags(%{mode: mode, model: model, effort: effort})]

  # Cheapest first; the first to refuse is the answer.
  defp verdict(mouse, panes, house) do
    with :ok <- shaped(mouse),
         :ok <- files(mouse),
         {:ok, pane} <- one_pane(mouse, panes),
         :ok <- ready(pane),
         :ok <- not_the_person(pane, house),
         :ok <- session(pane),
         :ok <- flagless(pane, house),
         :ok <- untried(mouse, house),
         :ok <- empty_box(pane, house),
         do: {:ok, pane}
  end

  defp shaped(%Mouse{shaped_at: %DateTime{}, branch: branch}) when is_binary(branch), do: :ok
  defp shaped(_mouse), do: {:leave, :unshaped}

  defp files(%Mouse{path: path}) when is_binary(path) do
    if plain?(Path.join(path, Brief.filename())) and plain?(Path.join(path, DenyList.filename())),
      do: :ok,
      else: {:leave, :no_files}
  end

  defp files(_mouse), do: {:leave, :no_files}

  defp plain?(path), do: match?({:ok, %File.Stat{type: :regular}}, File.lstat(path))

  defp untried(%Mouse{mouse_id: id}, house),
    do:
      if(MapSet.member?(Map.get(house, :restarted, MapSet.new()), id),
        do: {:leave, :tried},
        else: :ok
      )

  defp one_pane(mouse, panes) do
    case MousePane.agent_panes(mouse, panes) do
      [%{agent: "claude"} = pane] -> {:ok, pane}
      [] -> {:leave, :no_pane}
      [_] -> {:leave, :no_claude}
      _many -> {:leave, :many_panes}
    end
  end

  defp ready(%{agent_status: status}) when status in @ready, do: :ok
  defp ready(%{agent_status: status}), do: {:leave, {:not_ready, status}}

  defp not_the_person(%{pane_id: pane_id}, %{main_pane: pane_id}), do: {:leave, :main_session}
  defp not_the_person(_pane, _house), do: :ok

  defp session(%{session: id}) when is_binary(id) do
    if id =~ ~r/\A[0-9A-Za-z][0-9A-Za-z_-]{0,63}\z/, do: :ok, else: {:leave, :no_session}
  end

  defp session(_pane), do: {:leave, :no_session}

  # Only a process herdr named `claude` and gave arguments for is evidence: a
  # process it cannot read the arguments of, or no claude in the list, is not
  # a Claude without its flags.
  defp flagless(pane, house) do
    case house.herdr.processes(house.socket, pane.pane_id) do
      {:ok, processes} ->
        case Enum.filter(processes, &readable_claude?/1) do
          [] ->
            {:leave, :unreadable}

          claudes ->
            if Enum.any?(claudes, &launched_with_flags?/1), do: {:leave, :flagged}, else: :ok
        end

      {:error, _reason} ->
        {:leave, :unreadable}
    end
  end

  defp readable_claude?(%{argv: [argv0 | _], name: name}),
    do: name == "claude" or Path.basename(argv0) == "claude"

  defp readable_claude?(_process), do: false

  defp launched_with_flags?(%{argv: argv}) do
    "--dangerously-skip-permissions" in argv and
      argv |> Enum.chunk_every(2, 1) |> Enum.member?(Brief.claude_args())
  end

  # An unreadable screen is no empty box: this types into the pane.
  defp empty_box(pane, house) do
    with {:ok, screen} <- house.herdr.read_screen(house.socket, pane.pane_id) do
      case Draft.read(screen) do
        :empty -> :ok
        :unknown -> {:leave, :unreadable}
        held -> {:leave, held}
      end
    else
      {:error, _reason} -> {:leave, :unreadable}
    end
  end

  defp act(_mouse, {:leave, reason}, _ours, done, _house), do: {{:left, reason}, done}
  defp act(_mouse, {:ok, _pane}, :unknown, done, _house), do: {{:left, :no_herdr}, done}

  defp act(_mouse, {:ok, _pane}, _ours, done, _house) when done >= @per_sweep,
    do: {{:left, :later}, done}

  defp act(mouse, {:ok, pane}, {:ok, ours}, done, house) do
    if MousePane.ours?(mouse, ours),
      do: restart(mouse, pane, house, done),
      else: {{:left, :not_our_worktree}, done}
  end

  # The verdicts were all taken before the first restart, which blocks for
  # seconds: the pane is judged again, as herdr has it now, before `/exit`.
  defp restart(mouse, pane, house, done) do
    case recheck(pane, house) do
      {:ok, fresh} -> {typed_over(mouse, fresh, house), done + 1}
      {:error, outcome} -> {outcome, done}
    end
  end

  defp typed_over(mouse, fresh, house) do
    with :ok <- exit_claude(fresh, house),
         :ok <- start(mouse, fresh, house, @start_tries) do
      :restarted
    else
      {:error, outcome} -> outcome
    end
  end

  defp recheck(pane, house) do
    with {:ok, fresh} <- house.herdr.pane(house.socket, pane.pane_id),
         :ok <- one_claude(fresh),
         :ok <- ready(fresh),
         :ok <- session(fresh),
         :ok <- flagless(fresh, house),
         :ok <- empty_box(fresh, house) do
      {:ok, fresh}
    else
      {:leave, reason} -> {:error, {:left, reason}}
      {:error, _reason} -> {:error, {:left, :unreadable}}
    end
  end

  defp one_claude(%{agent: "claude"}), do: :ok
  defp one_claude(_pane), do: {:leave, :no_claude}

  defp exit_claude(pane, house) do
    case house.herdr.prompt(house.socket, pane.pane_id, "/exit") do
      :ok -> gone?(pane, house, @exit_tries)
      {:error, reason} -> {:error, {:left, {:refused, reason}}}
    end
  end

  defp gone?(_pane, _house, 0), do: {:error, {:left, :exit_timeout}}

  defp gone?(pane, house, tries) do
    case house.herdr.pane(house.socket, pane.pane_id) do
      {:ok, %{agent: nil}} ->
        :ok

      _still_there ->
        Process.sleep(Map.get(house, :pause_ms, 250))
        gone?(pane, house, tries - 1)
    end
  end

  # herdr answers `agent_pane_busy` while the shell has not drawn its prompt.
  defp start(mouse, pane, house, tries) do
    result =
      house.herdr.start_agent(
        house.socket,
        pane.pane_id,
        Spawn.agent_name(mouse.branch),
        args(pane.session, mouse)
      )

    case result do
      {:ok, _argv} ->
        :ok

      {:error, {:herdr, %{"code" => "agent_pane_busy"}}} when tries > 1 ->
        Process.sleep(Map.get(house, :pause_ms, 250))
        start(mouse, pane, house, tries - 1)

      {:error, reason} ->
        {:error, {:left, {:start_refused, reason}}}
    end
  end
end
