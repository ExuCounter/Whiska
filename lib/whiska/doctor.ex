defmodule Whiska.Doctor do
  @moduledoc """
  `whiska doctor`: is Whiska working for this repo right now, and if not, what
  exactly is wrong.

  Built for the case where everything was set up once and has drifted since —
  a binary rebuilt but not reinstalled, a hook that a later version wires but
  this repo's `init` predates, an owl that never got started, a main session
  never recorded. First-time setup is the degenerate case where everything
  fails. Delivery cannot report the cases where it cannot deliver, and the
  statusline (ADR-0027) has one line to say it in, so this is the command the
  person runs when the mice have gone quiet and they want to know whether that
  is real quiet.

  Two rules (ADR-0038):

  - **It checks and never repairs.** Every failing check prints the exact
    command that fixes it. Rewriting `settings.json` is `init`'s job; replacing
    the binary is the installer's. The doctor touches nothing.
  - **It probes rather than inspects.** Reading `settings.json` proves a hook is
    wired; it does not prove the shim finds a runtime or that the installed
    binary knows the hook. So the doctor runs the shim in force, for every
    hook, with a payload whose `cwd` is outside any worktree — which makes each
    hook a no-op that writes nothing (ADR-0035 already says the shim is verified
    by running it, not by unit test).

  Scoped to one repo, run from its main checkout or any worktree. The binary,
  runtime, herdr and owl are reported too, because they are that repo's
  prerequisites: a wired Stop hook is worth nothing if the installed binary
  cannot serve it.
  """

  alias Whiska.AnswerFlag
  alias Whiska.Backstop
  alias Whiska.Delivery.Draft
  alias Whiska.Delivery.Mode
  alias Whiska.Doctor.Check
  alias Whiska.Doctor.Report
  alias Whiska.Doorstep
  alias Whiska.Doorstep.Entry
  alias Whiska.Herdr
  alias Whiska.Install
  alias Whiska.Layout
  alias Whiska.Marker
  alias Whiska.OpenHouses
  alias Whiska.Schema.Mouse
  alias Whiska.Schema.Question
  alias Whiska.ServiceManager
  alias Whiska.Storage
  alias Whiska.Transcript

  @reinstall "mix escript.build && cp whiska ~/.local/bin/whiska"
  @init "whiska init"
  @init_global "whiska init --global"
  @owl "whiska owl"
  @install "whiska owl install"
  # Where Homebrew puts escript on Apple silicon, on Intel, and on Linux.
  @homebrew_escripts [
    "/opt/homebrew/bin/escript",
    "/usr/local/bin/escript",
    "/home/linuxbrew/.linuxbrew/bin/escript"
  ]
  @restart "whiska start --force  (from the main checkout's pane)"
  @restart_owl "whiska owl stop && whiska owl start"

  @doc """
  Examine one repo. `main_checkout` is its main checkout.

  Options exist so the environment can be pinned in tests: `:env` (a map, the
  process environment by default), `:owl_pids` (a function returning the pids
  of running owls, the process table by default), `:herdr` (the herdr module,
  ADR-0031's boundary), `:open_houses` (the record's path, the real one by
  default), `:service_manager` (the module that keeps the owl running,
  `Whiska.ServiceManager.impl/0` by default), `:supervision` (a function
  returning `{installed?, status}` for its job, the manager's own answer by
  default), `:ready` (whether the manager is there at all, its own answer by
  default), `:linger` (whether the owl outlives a logout, the manager's own
  answer by default), `:owl_started_at`
  (a function giving when a pid started, `ps` by default), `:desktop` (where a
  hoot herdr will not show is raised, `Whiska.Desktop.impl/0` by default).
  """
  @spec run(Path.t(), keyword()) :: Report.t()
  def run(main_checkout, opts \\ []) do
    env = Keyword.get(opts, :env, System.get_env())
    owl_pids = Keyword.get(opts, :owl_pids, &Whiska.Owl.pids/0)
    herdr = Keyword.get(opts, :herdr, Herdr.impl())
    record = Keyword.get_lazy(opts, :open_houses, &OpenHouses.path/0)
    manager = Keyword.get(opts, :service_manager, ServiceManager.impl())
    ready = Keyword.get(opts, :ready, &manager.ready/0)
    supervision = Keyword.get(opts, :supervision, fn -> supervision_state(manager) end)
    lingers = Keyword.get(opts, :linger, &manager.linger/0)
    owl_started_at = Keyword.get(opts, :owl_started_at, &Whiska.Owl.started_at/1)
    desktop = Keyword.get(opts, :desktop, Whiska.Desktop.impl())
    now = DateTime.utc_now()
    pids = owl_pids.()
    {installed?, agent} = supervision.()

    {binary, binary_path} = binary(env)
    installed_at = changed_at(binary_path)
    {herdr_check, panes} = herdr(env, herdr)
    settings = read_settings(main_checkout)
    global_state = Install.global_state()
    hooks = hooks(settings, global_state) ++ [statusline(settings, global_state)]
    {shim_scope, shim_root} = shim_in_force(main_checkout, global_state)
    shim = shim(read_shim(shim_root), shim_scope)

    probes =
      if binary_path != nil and shim.status == :ok,
        do:
          for(
            hook <- ["pre-tool-use", "stop", "session-start", "user-prompt-submit"],
            do: probe(main_checkout, hook, env, shim_root, shim_scope)
          ),
        else: []

    {house, in_house} =
      house(main_checkout, panes, herdr, env["HERDR_SOCKET_PATH"], now, env)

    checks =
      [binary] ++
        built(main_checkout, installed_at, binary_path) ++
        [
          runtime(env),
          herdr_check,
          owl(pids, Map.new(pids, &{&1, owl_started_at.(&1)}), installed_at, binary_path)
        ] ++
        supervision(manager, ready.(), installed?, agent, pids, lingers) ++
        [
          open_houses(OpenHouses.read(record), main_checkout, pids),
          tab_bar(
            read_herdr_config(env),
            File.exists?(Install.herdr_status_path()),
            File.read(Install.herdr_status_path()) == {:ok, Install.herdr_status_script()}
          ),
          hoot_probe(herdr, desktop, env),
          global(global_state),
          commands(Install.commands_dir(), env)
        ] ++
        hooks ++
        [shim] ++
        repo_statusline_script(main_checkout) ++
        retired(main_checkout) ++
        probes ++
        [
          house,
          doorstep(Doorstep.waiting(main_checkout), now),
          backstop(Backstop.read(main_checkout), now)
        ] ++ in_house

    %Report{repo: main_checkout, checks: checks}
  end

  # -- prerequisites -----------------------------------------------------------

  # Mirrors the shim's own search (ADR-0035): WHISKA_BIN, then PATH, then
  # ~/.local/bin. Finding it only in the fallback is worth a warning, since a
  # plain `whiska` at the prompt will not work there.
  defp binary(env) do
    override = env["WHISKA_BIN"]
    fallback = Path.join(home(env), ".local/bin/whiska")

    cond do
      executable?(override) ->
        {Check.ok("binary", "#{override} (WHISKA_BIN)"), override}

      path = find_on_path(env, "whiska") ->
        {Check.ok("binary", path), path}

      executable?(fallback) ->
        {Check.warn(
           "binary",
           "#{fallback} — not on PATH; the shim falls back here",
           ~s|export PATH="$HOME/.local/bin:$PATH"|
         ), fallback}

      true ->
        {Check.fail("binary", "no whiska binary found", @reinstall), nil}
    end
  end

  defp runtime(env) do
    override = env["WHISKA_ESCRIPT"]

    cond do
      executable?(override) ->
        Check.ok("runtime", "#{override} (WHISKA_ESCRIPT)")

      path = find_on_path(env, "escript") ->
        Check.ok("runtime", path)

      path = asdf_escript(env) ->
        Check.ok("runtime", "#{path} (asdf install, not on PATH — the shim finds it)")

      path = Enum.find(@homebrew_escripts, &executable?/1) ->
        Check.ok("runtime", path)

      true ->
        Check.warn(
          "runtime",
          "no escript found — only a native whiska binary would run (ADR-0033)"
        )
    end
  end

  defp asdf_escript(env) do
    data_dir = env["ASDF_DATA_DIR"] || Path.join(home(env), ".asdf")

    data_dir
    |> Path.join("installs/erlang/*/bin/escript")
    |> Path.wildcard()
    |> Enum.filter(&executable?/1)
    |> Enum.sort_by(&Path.basename(Path.dirname(Path.dirname(&1))), &version_gte?/2)
    |> List.first()
  end

  defp version_gte?(a, b), do: version_parts(a) >= version_parts(b)

  defp version_parts(v),
    do: v |> String.split(".") |> Enum.map(fn p -> Integer.parse(p) |> elem(0) end)

  defp herdr(env, herdr) do
    socket = env["HERDR_SOCKET_PATH"]

    cond do
      is_nil(socket) or socket == "" ->
        {Check.warn("herdr", "HERDR_SOCKET_PATH is not set — run this from a herdr pane"),
         :unknown}

      not File.exists?(socket) ->
        {Check.warn("herdr", "no socket at #{socket} — is herdr running?"), :unknown}

      true ->
        case herdr.list_panes(socket) do
          {:ok, panes} ->
            {Check.ok("herdr", "reachable at #{socket} (#{length(panes)} panes)"), {:ok, panes}}

          {:error, reason} ->
            {Check.warn("herdr", "not answering at #{socket} (#{inspect(reason)})"), :unknown}
        end
    end
  end

  @doc """
  Is an owl running — and is it running the binary that is installed now?

  `pids` are the owl processes found, `started_at` when each of them started,
  `installed_at` when the binary on disk was last written. Each owl is judged
  on its own: beside a fresh one, a stale foreground owl is the one named, and
  the one to stop. A process
  older than its own binary is the gap this moduledoc already claimed to cover
  and did not: nothing about a running owl changes when the escript under it is
  replaced, so a fix lands, the board keeps drawing the behaviour from before
  it, and the owl line says `running` throughout. Either time being unknown
  leaves the plain line, never a guess.

  A warning, not a failure: the old owl collects and delivers perfectly well
  (ADR-0038), it is just not the code the person thinks they are running. The
  binary is named rather than implied, because the supervised owl resolves it
  in its service manager's environment and the doctor in this shell's: where
  `WHISKA_BIN` is exported in one and not the other, the two are different
  files and the person can see that here.
  """
  @spec owl(
          [pos_integer()],
          %{pos_integer() => DateTime.t() | nil},
          DateTime.t() | nil,
          Path.t() | nil
        ) :: Check.t()
  def owl(pids, started_at \\ %{}, installed_at \\ nil, installed \\ nil)

  def owl([], _started_at, _installed_at, _installed),
    do: Check.warn("owl", "not running — nothing collects the doorstep", @owl)

  def owl(pids, started_at, %DateTime{} = installed_at, installed) do
    known = for pid <- pids, %DateTime{} = at <- [started_at[pid]], do: {pid, at}

    case for(
           {pid, at} <- known,
           (behind = DateTime.diff(installed_at, at)) > 0,
           do: {pid, behind}
         ) do
      [] when known == [] ->
        owl(pids, %{}, nil, installed)

      [] ->
        Check.ok("owl", "running (pid #{Enum.join(pids, ", ")}), from the installed binary")

      stale ->
        Check.warn(
          "owl",
          "running (pid #{Enum.join(pids, ", ")}); " <>
            Enum.map_join(stale, "; ", fn {pid, behind} ->
              "pid #{pid} started #{age(behind)} before " <>
                "#{installed || "the binary it runs"} was installed"
            end) <> " — serving the code that replaced it",
          stale_fix(pids, stale)
        )
    end
  end

  def owl(pids, _started_at, _installed_at, _installed),
    do: Check.ok("owl", "running (pid #{Enum.join(pids, ", ")})")

  # Every owl stale is the restart; some of them stale leaves the current one
  # running and stops the rest.
  defp stale_fix(pids, stale) when length(pids) == length(stale), do: @restart_owl
  defp stale_fix(_pids, stale), do: "kill #{Enum.map_join(stale, " ", &elem(&1, 0))}"

  @doc """
  The escript built in this checkout, against the one on PATH (ADR-0038).

  `built_at` is when `mix escript.build` last wrote `./whiska` here,
  `installed_at` when `installed` was last written. A build newer than the
  installed binary is the half-finished step everything downstream inherits:
  the hooks, the statusline and the owl all run the installed one, so a fix
  built and not copied is a fix nobody is running — including the person
  reading this report to find out why it is missing.

  A warning: what is installed still works, it is simply not what was built
  here. Only ever reported where there is a build to compare — a checkout
  nobody has built in gets no line (the `review loop` check's rule). Both paths
  are absolute, because `whiska doctor` runs from any worktree of the repo and
  a relative `cp whiska` pasted from there would copy a different build.
  """
  @spec build(DateTime.t(), DateTime.t(), Path.t(), Path.t()) :: Check.t()
  def build(%DateTime{} = built_at, %DateTime{} = installed_at, built, installed) do
    case DateTime.diff(built_at, installed_at, :second) do
      ahead when ahead > 0 ->
        Check.warn(
          "build",
          "#{built} was built #{age(ahead)} after #{installed} was installed — " <>
            "nothing runs this build until it is copied over",
          "cp #{built} #{installed}"
        )

      _current ->
        Check.ok("build", "#{built} is no newer than #{installed}")
    end
  end

  @doc """
  The main session, against the wiring it loaded (ADR-0038).

  Claude Code reads its settings files once, when the session starts, so a
  session older than a change to one of them is running what they said before
  it, and nothing in that session ever says so. `started_at` is when it
  started, read from its own transcript file
  (`Whiska.Transcript.started_at/1`, found through herdr's session id for the
  recorded pane); `changes` are the settings files it loads, each with when it
  last changed.

  The line says what the clock can know and no more: that a settings file
  changed after this session started, and that hooks are read at startup. It
  does not claim the hooks themselves changed — only an mtime is compared, and
  a model, a permission or an MCP server moves it exactly as a hook does. The
  person knows which they edited; the doctor knows only that the session
  predates it.

  Only the settings files are compared. The shim and the statusline script are
  run afresh every time they are needed, so a change to either is live the
  moment it lands and would be a false alarm here. A session whose transcript
  cannot be found says it was not checked rather than guessing: a check that
  cries wolf about a restart the person has already done is worse than none.
  """
  @spec session_wiring(DateTime.t() | nil, [{String.t(), DateTime.t()}]) :: Check.t()
  def session_wiring(nil, _changes),
    do:
      Check.ok(
        "session wiring",
        "not checked — herdr did not name the main session, or its transcript is gone"
      )

  def session_wiring(%DateTime{} = started_at, changes) do
    case changes
         |> Enum.filter(&(DateTime.compare(elem(&1, 1), started_at) == :gt))
         |> newest() do
      nil ->
        Check.ok("session wiring", "started after the last change to it")

      {file, at} ->
        Check.warn(
          "session wiring",
          "#{file} changed #{age(DateTime.diff(at, started_at, :second))} after the main " <>
            "session started — hooks load at startup, so if that change touched hooks, " <>
            "restart Claude there",
          "restart Claude in the main session's pane"
        )
    end
  end

  defp newest([]), do: nil
  defp newest(changes), do: Enum.max_by(changes, &DateTime.to_unix(elem(&1, 1)))

  defp supervision_state(manager),
    do: {manager.installed?(manager.paths()), manager.status()}

  # Where the manager is not there at all, its own fixes would not work: the
  # one line left says so, and points at the foreground owl.
  defp supervision(manager, :ok, installed?, agent, pids, lingers),
    do:
      [service_manager(manager, installed?, agent, pids, wrapper_current?(manager, installed?))] ++
        linger(manager, lingers.())

  defp supervision(manager, {:error, reason}, _installed?, _agent, _pids, _lingers) do
    [
      Check.warn(
        manager.noun(),
        "#{reason} — the owl runs only in the foreground, and dies with its pane",
        "whiska owl  (in a pane)"
      )
    ]
  end

  defp wrapper_current?(_manager, false), do: true

  defp wrapper_current?(manager, true),
    do: File.read(manager.paths().wrapper) == {:ok, ServiceManager.wrapper()}

  @doc """
  The job that keeps the owl running (ADR-0040) — a LaunchAgent on macOS, a
  systemd unit on Linux, whichever `manager` is: is it installed, loaded, and
  is the owl it runs alive — and is that the only owl. A loaded job with no
  owl and a non-zero last exit code is crash-looping, not merely stopped.
  `installed?` is whether the job file is there, `agent` is the manager's word
  on the job, `pids` every owl in the process table, `wrapper_current?` whether
  the wrapper the job runs is the one this build writes. An owl running only in
  the foreground is a warning: it dies with its pane and nothing restarts it.
  Two owls is the one state nothing else can explain, and the doctor names
  both. The line is named for the manager's own kind of job.
  """
  @spec service_manager(
          module(),
          boolean(),
          ServiceManager.status(),
          [pos_integer()],
          boolean()
        ) :: Check.t()
  def service_manager(manager, installed?, agent, pids, wrapper_current? \\ true) do
    case {job(manager, installed?, agent, pids), wrapper_current?} do
      {%Check{status: :ok, detail: detail}, false} ->
        Check.warn(
          manager.noun(),
          "#{detail}, but #{manager.paths().wrapper} differs from what this whiska ships",
          @install
        )

      {check, _current} ->
        check
    end
  end

  defp job(manager, false, _agent, []),
    do: Check.warn(manager.noun(), "not installed — the owl is not supervised", @install)

  defp job(manager, false, _agent, pids) do
    Check.warn(
      manager.noun(),
      "not installed — the owl (pid #{Enum.join(pids, ", ")}) runs in the foreground and " <>
        "dies with its pane",
      @install
    )
  end

  defp job(manager, true, %{loaded: false}, _pids),
    do: Check.warn(manager.noun(), "#{manager.label()} is written but not loaded", @install)

  defp job(manager, true, %{pid: nil, last_exit_code: code}, _pids)
       when is_integer(code) and code != 0 do
    Check.warn(
      manager.noun(),
      "#{manager.label()} loaded but crash-looping (last exit code #{code}) — " <>
        "see #{manager.paths().log}",
      "whiska owl start"
    )
  end

  defp job(manager, true, %{pid: nil}, _pids) do
    Check.warn(
      manager.noun(),
      "#{manager.label()} loaded, owl not running — see #{manager.paths().log}",
      "whiska owl start"
    )
  end

  defp job(manager, true, %{pid: pid}, pids) do
    case Enum.reject(pids, &(&1 == pid)) do
      [] ->
        Check.ok(manager.noun(), "#{manager.label()} loaded, owl running (pid #{pid})")

      others ->
        Check.warn(
          manager.noun(),
          "two owls — #{manager.name()}'s (pid #{pid}) and another " <>
            "(pid #{Enum.join(others, ", ")}) collect the same doorsteps",
          "Ctrl-C the foreground owl"
        )
    end
  end

  @doc """
  Whether the owl outlives the person's last login session. systemd stops a
  user's services at logout unless lingering is on — a machine setting, so
  `whiska owl install` only says how, and this line keeps saying it while it is
  off. No line where the question does not arise, as under launchd.
  """
  @spec linger(module(), boolean() | :not_applicable) :: [Check.t()]
  def linger(_manager, :not_applicable), do: []

  def linger(_manager, true),
    do: [Check.ok("logout", "lingering is on — the owl keeps running after you log out")]

  def linger(manager, false) do
    [
      Check.warn(
        "logout",
        "#{manager.name()} stops the owl when your last session ends",
        "loginctl enable-linger"
      )
    ]
  end

  @doc """
  The open-houses record (ADR-0039): which houses the owl has open, and
  whether this repo is one of them. `record` is what the file says; `pids`
  are the owl processes found, because the record is only in force while one
  is alive. A repo not in it is not a whiska and nothing collects its
  doorstep, however live its main session is — the case the statusline's count
  cannot explain and this line does.
  """
  @spec open_houses([Path.t()], Path.t(), [pos_integer()]) :: Check.t()
  def open_houses([], _main, _pids),
    do: Check.warn("open houses", "none recorded — the owl has not opened a house yet", @owl)

  def open_houses(record, _main, []) do
    Check.warn(
      "open houses",
      "record lists #{count(record)} (#{names(record)}); none is open while the owl is down",
      @owl
    )
  end

  def open_houses(record, main, _pids) do
    main = Path.expand(main)

    case Enum.reject(record, &(&1 == main)) do
      ^record ->
        Check.warn(
          "open houses",
          "this repo is not open — the owl has #{names(record)}; it is not a whiska and its doorstep is not collected",
          "#{@owl} #{main}  (restart the owl with this repo added)"
        )

      [] ->
        Check.ok("open houses", "this repo")

      others ->
        Check.ok("open houses", "this repo, with #{count(others)} more: #{names(others)}")
    end
  end

  defp count([_]), do: "1 house"
  defp count(houses), do: "#{length(houses)} houses"
  defp names(houses), do: Enum.map_join(houses, ", ", &Path.basename/1)

  # -- this repo's hooks -------------------------------------------------------

  @doc """
  Whether the global install is there, and whole (ADR-0056).

  Not being installed is not a failure: a repo that carries its own `.claude/`
  needs none of it. A half-written one is, because the person meant to have it
  and part of it is not working — the hooks without the skills is a question
  nothing can read back, and an install without `SessionStart` starts every
  session without Whiska's rules.
  """
  @global_pieces [
    {:hooks?, "hooks"},
    {:session_start?, "SessionStart hook"},
    {:statusline?, "statusline"},
    {:skills?, "skills"}
  ]

  @spec global(map()) :: Check.t()
  def global(state) do
    case {Enum.split_with(@global_pieces, &state[elem(&1, 0)]), drifted(state)} do
      {{[], _missing}, _drift} ->
        Check.ok("global install", "not installed — this repo carries its own")

      {{_there, []}, []} ->
        Check.ok(
          "global install",
          "~/.claude — every repo on this machine is covered" <> linked(state)
        )

      {{_there, []}, drift} ->
        Check.warn(
          "global install",
          "~/.claude: " <> Enum.join(drift, "; ") <> linked(state),
          @init_global
        )

      {{_there, missing}, drift} ->
        Check.warn(
          "global install",
          Enum.join(
            ["half there in ~/.claude: no #{Enum.map_join(missing, ", ", &elem(&1, 1))}" | drift],
            "; "
          ) <> linked(state),
          @init_global
        )
    end
  end

  defp drifted(state) do
    stale = state[:stale_skills] || []
    retired = state[:retired_present] || []

    if(stale != [],
      do: [
        "#{Enum.join(stale, ", ")} #{verb(stale, "differs", "differ")} from what this whiska ships"
      ],
      else: []
    ) ++
      if retired != [],
        do: [
          "#{Enum.join(retired, ", ")} #{verb(retired, "is", "are")} retired and nothing reads it"
        ],
        else: []
  end

  defp verb([_], one, _many), do: one
  defp verb(_list, _one, many), do: many

  # Said because it changes where the person commits, not because anything is
  # wrong: a linked file is written through the link, and the change is in
  # whatever repo owns it.
  defp linked(state) do
    case state[:links] || [] do
      [] -> ""
      links -> " · written through symlinks: #{Enum.map_join(links, ", ", &elem(&1, 0))}"
    end
  end

  @doc """
  What wires this repo's hooks: its own `.claude/settings.json`, or the global
  install standing in for it.

  A repo with neither is the failure. A repo with both is fine and says so: the
  global shim stands down where the repo wires Whiska itself, so nothing fires
  twice (ADR-0056).
  """
  @spec hooks(map(), map()) :: [Check.t()]
  def hooks(settings, global \\ %{}) when is_map(settings) do
    # Where the repo wires Whiska itself the global copy stands down for every
    # hook, so a hook the repo's older install lacks is covered by nothing.
    global = if wires_whiska?(settings), do: %{}, else: global

    [
      hook_check(
        "PreToolUse",
        settings,
        Install.command(),
        Install.matcher(),
        "not wired — nothing is enforced for mice here",
        global[:hooks?]
      ),
      hook_check(
        "Stop",
        settings,
        Install.stop_command(),
        nil,
        "not wired — mice here cannot leave questions",
        global[:hooks?]
      ),
      hook_check(
        "UserPromptSubmit",
        settings,
        Install.prompt_command(),
        nil,
        "not wired — mice here are rung for answers they can never take",
        global[:hooks?]
      ),
      session_start_check(settings, global)
    ]
  end

  # A global install written before SessionStart existed still enforces and
  # delivers, so only this row fails — and its fix is the global init, not
  # one for this repo.
  defp session_start_check(settings, global) do
    check =
      hook_check(
        "SessionStart",
        settings,
        Install.session_start_command(),
        nil,
        "not wired — sessions here start without Whiska's rules",
        global[:session_start?]
      )

    case {check, global[:hooks?]} do
      {%Check{status: :fail}, true} -> %{check | fix: "whiska init --global"}
      {check, _global} -> check
    end
  end

  defp wires_whiska?(%{"hooks" => hooks}) when is_map(hooks) do
    Enum.any?(hooks, fn {_event, entries} -> is_list(entries) and Enum.any?(entries, &ours?/1) end)
  end

  defp wires_whiska?(_settings), do: false

  defp hook_check(event, settings, expected_command, expected_matcher, missing, global?) do
    entries = get_in(settings, ["hooks", event]) || []

    case Enum.find(entries, &ours?/1) do
      nil when global? ->
        Check.ok(event, "wired globally, in ~/.claude")

      nil ->
        Check.fail(event, missing, @init)

      entry ->
        command = our_command(entry)
        matcher = entry["matcher"]

        cond do
          command != expected_command ->
            Check.fail(event, "older version of the hook command: #{command}", @init)

          expected_matcher && matcher != expected_matcher ->
            Check.fail(
              event,
              "matcher is #{inspect(matcher)} — the rules never fire for the tools it leaves out",
              @init
            )

          expected_matcher ->
            Check.ok(event, "wired in this repo, matcher #{matcher}")

          true ->
            Check.ok(event, "wired in this repo")
        end
    end
  end

  @doc """
  The project statusline: ours, and redrawn on a timer (ADR-0027, ADR-0044).

  Nothing is lost when this is wrong — questions are still collected and still
  delivered — so the worst it goes is a warning. What is lost is this repo's own
  view of itself: with no `refreshInterval`, Claude Code re-runs the line only
  when this session's own conversation changes, and a mouse that spawns, dies or
  asks a second question while the person sits still changes nothing in it.

  Any interval of a second or more reads as ok: this reports and never argues
  with a number the person typed. `whiska init` is the other half of ADR-0044's
  decision and does replace the whole entry, interval included, every time it
  runs.
  """
  @spec statusline(map(), map()) :: Check.t()
  def statusline(settings, global \\ %{}) when is_map(settings) do
    case settings["statusLine"] do
      %{"command" => command} = entry when is_binary(command) ->
        ours_statusline(entry, command)

      _ when not is_map_key(global, :statusline?) or not :erlang.map_get(:statusline?, global) ->
        Check.warn(
          "statusLine",
          "no project statusLine — nothing here says what is waiting",
          @init
        )

      _ ->
        Check.ok("statusLine", "drawn globally, from ~/.claude")
    end
  end

  defp ours_statusline(entry, command) do
    interval = entry["refreshInterval"]

    cond do
      not String.contains?(command, Install.statusline_path()) ->
        Check.warn(
          "statusLine",
          "somebody else's script — this repo's line is not shown here",
          @init
        )

      is_integer(interval) and interval >= 1 ->
        Check.ok("statusLine", "wired, redrawn every #{interval}s")

      true ->
        Check.warn(
          "statusLine",
          "wired, but with no refreshInterval — a mouse that spawns or asks " <>
            "stays invisible while this session is idle",
          @init
        )
    end
  end

  @doc """
  The copy of the statusline script this repo carries (ADR-0059).

  `contents` is the repo's own `.claude/hooks/whiska-statusline.sh`, which is
  committed and shared with whoever else works here, so nothing rewrites it.
  A copy an older `whiska init` wrote still runs, and what it leaves out is
  silent: the one this build ships falls back to the base line the global
  install kept beside it (ADR-0056), and without that fallback the person's
  own model-and-branch line disappears along with the board.

  So the stamp is compared and the answer is an upgrade notice rather than a
  fault — nothing here is broken, there is simply a newer script to write. A
  repo whose copy is *newer* than this build is the other direction: somebody
  else ran a newer `whiska init` and committed it, and running this one would
  write the older script back over a shared file, so the fix named is the
  binary rather than `init`.
  """
  @spec statusline_script(String.t()) :: Check.t()
  def statusline_script(contents) when is_binary(contents) do
    shipped = Install.statusline_version()

    case Install.statusline_version_of(contents) do
      ^shipped ->
        Check.ok("statusline script", "up to date (v#{shipped})")

      nil ->
        Check.warn("statusline script", "whiska upgrade is available", @init)

      newer when newer > shipped ->
        Check.warn(
          "statusline script",
          "v#{newer} — newer than this whiska (v#{shipped}); `whiska init` would write " <>
            "the older one back over it",
          @reinstall
        )

      older ->
        Check.warn("statusline script", "v#{older}; whiska upgrade is available", @init)
    end
  end

  @doc """
  Whether the hoot the owl raises on every delivery is seen (ADR-0062).

  `probe` is what `Whiska.Herdr.notify/2` answered to a notification sent for
  this check, or `:no_socket` when there was no herdr to send one to; `desktop`
  is what the desktop did when herdr's answer sent the hoot there
  (ADR-0071), or `:not_needed`. Both are asked
  rather than read from config, so the person sees the notification exactly
  when it works, which is the answer and the demonstration in one (ADR-0038).

  A warning, never a failure: the question is delivered either way, the line is
  in the main session, and `whiska questions` still lists it. What is lost is
  hearing about it while looking at something else. herdr's config is the
  person's and machine-global, so the fix says what to change in the table they
  already have and never writes it (ADR-0016).
  """
  @spec hoot(Herdr.notify_result() | :no_socket, Whiska.Desktop.result() | :not_needed) ::
          Check.t()
  def hoot(probe, desktop \\ :not_needed)

  def hoot({:ok, :shown}, _desktop),
    do: Check.ok("hoot", "a delivered question is shown by herdr")

  def hoot({:ok, {:not_shown, reason}}, {:ok, notifier}),
    do:
      Check.ok(
        "hoot",
        "herdr does not show it (#{reason}), so Whiska raises it with #{notifier} — " <>
          "if nothing appeared, #{notifications_off(notifier)}"
      )

  def hoot({:ok, {:not_shown, reason}}, {:error, :no_notifier}),
    do:
      Check.warn(
        "hoot",
        "herdr did not show it (#{reason}), and there is no terminal-notifier, osascript " <>
          "or notify-send to raise it instead, so a delivered question is silent",
        hoot_fix(reason)
      )

  def hoot({:ok, {:not_shown, reason}}, {:error, why}),
    do:
      Check.warn(
        "hoot",
        "herdr did not show it (#{reason}), and raising it on the desktop failed " <>
          "(#{inspect(why)}), so a delivered question is silent",
        hoot_fix(reason)
      )

  def hoot({:ok, {:not_shown, reason}}, :not_needed),
    do:
      Check.warn(
        "hoot",
        "herdr did not show it (#{reason}), so a delivered question is silent",
        hoot_fix(reason)
      )

  def hoot({:error, reason}, _desktop),
    do: Check.warn("hoot", "could not ask herdr to show one (#{inspect(reason)})")

  def hoot(:no_socket, _desktop),
    do: Check.warn("hoot", "no herdr to ask — a delivered question is silent")

  # Never a block to paste. `[ui.toast]` and `[ui.sound]` are in herdr's own
  # stock config, and a second table of either name is a TOML duplicate key,
  # which herdr refuses — dropping the whole file back to defaults, the tab bar
  # entry that draws the owl's line (ADR-0048) with it.
  # The probe (ADR-0038): ask herdr to show one and read what it says it did.
  # The person sees it exactly when the hoot works, so the check is its own
  # demonstration — and when it does not work there is nothing to see, which is
  # the finding.
  # It goes out through `Whiska.Delivery.Hoot.send_out/4`, the owl's own path,
  # so the desktop fallback is probed exactly as a delivery would take it.
  defp hoot_probe(herdr, desktop, env) do
    case Herdr.socket(env) do
      {:ok, socket} ->
        {answer, raised} =
          Whiska.Delivery.Hoot.send_out(herdr, socket, desktop, %{
            title: "🐱 whiska doctor",
            body: "this is what a delivered question looks like",
            sound: :none
          })

        hoot(answer, raised)

      {:error, {:no_socket, _}} ->
        hoot(:no_socket)
    end
  end

  defp notifications_off("notify-send"),
    do: "the desktop has notifications off, or no notification server is running"

  defp notifications_off(notifier), do: "macOS has notifications off for #{notifier}"

  # Only popups switched off are fixed in herdr's config; nobody attached, or
  # herdr pacing itself, is not.
  defp hoot_fix("disabled"), do: hoot_fix()
  defp hoot_fix(_reason), do: nil

  defp hoot_fix do
    ~s(in #{Herdr.config_path()}, set delivery = "system" under the ) <>
      ~s([ui.toast] table and enabled = true under [ui.sound])
  end

  @doc """
  The herdr entry that draws the owl's line, and the script it names
  (ADR-0048).

  `config` is the contents of herdr's `config.toml`, or `nil` when there is
  none; `script?` says whether the shipped script is on disk, and `current?`
  whether it is the one this build ships.

  Nothing is lost when this is wrong — questions are still collected, recorded
  and delivered — so the worst it goes is a warning (ADR-0038). What is lost is
  the one place the owl's own outage can appear, since delivery cannot report
  it. The config is the person's and machine-global, so the doctor prints the
  entry to paste and never writes it (ADR-0016).
  """
  @spec tab_bar(String.t() | nil, boolean(), boolean()) :: Check.t()
  def tab_bar(config, script?, current? \\ true) do
    entry = config && entry_line(config)

    cond do
      entry && not script? ->
        Check.warn(
          "tab bar",
          "herdr runs #{Install.herdr_status_path()}, and that script is not there",
          "whiska owl install"
        )

      script? and not current? ->
        Check.warn(
          "tab bar",
          "#{Install.herdr_status_path()} differs from what this whiska ships",
          "whiska owl install"
        )

      entry ->
        Check.ok("tab bar", "wired, herdr redraws it every #{interval(entry)}s")

      not script? ->
        Check.warn(
          "tab bar",
          "nothing draws the owl's line, and the script it needs is not there either",
          "whiska owl install"
        )

      true ->
        Check.warn("tab bar", "nothing draws the owl's line", paste())
    end
  end

  # The one `tab_bar_right` entry that runs our script, whatever else the
  # person has on their tab bar. herdr runs a command entry through a login
  # shell, so `~/.whiska/herdr-status.sh` works there and counts here.
  defp entry_line(config) do
    path = Install.herdr_status_path()
    tilde = String.replace_prefix(path, ServiceManager.user_home(), "~")

    config
    |> String.split("\n")
    |> Enum.find(&(String.contains?(&1, path) or String.contains?(&1, tilde)))
  end

  defp interval(entry) do
    case Regex.run(~r/interval_seconds\s*=\s*(\d+)/, entry, capture: :all_but_first) do
      [seconds] -> seconds
      nil -> Install.herdr_status_interval()
    end
  end

  defp paste do
    "paste into #{Herdr.config_path()} and commit it:\n" <> Install.tab_bar_right_snippet()
  end

  defp read_herdr_config(env) do
    case File.read(Herdr.config_path(env)) do
      {:ok, config} -> config
      {:error, _} -> nil
    end
  end

  # The same recognition `init` uses when it replaces its own entry.
  defp ours?(%{"hooks" => hooks}) when is_list(hooks), do: our_command(%{"hooks" => hooks}) != nil
  defp ours?(_), do: false

  defp our_command(%{"hooks" => hooks}) do
    Enum.find_value(hooks, fn
      %{"command" => command} when is_binary(command) ->
        if String.contains?(command, "whiska hook") or
             String.contains?(command, "hook pre-tool-use") or
             String.contains?(command, Install.shim_path()),
           do: command

      _ ->
        nil
    end)
  end

  @doc """
  The shim in force, compared with what `init` writes today for its scope.

  Which scope that is matters: under a global install (ADR-0056) the shim lives
  in `~/.claude` and the repo deliberately has none. Reading only the repo's
  reported it missing in every repo on this machine and prescribed `whiska
  init`, which would have written a repo-local install over the global one the
  person chose — and, because the probes only run behind a passing shim check,
  silently skipped the two checks that prove a hook fires at all.

  The two shims are not the same script, so each is compared with its own:
  the global copy stands down for a repo that wires Whiska itself.
  """
  @spec shim(String.t() | nil, Install.scope()) :: Check.t()
  def shim(contents, scope \\ :repo)

  def shim(nil, scope), do: Check.fail("shim", "#{shim_path(scope)} is missing", init_fix(scope))

  def shim(contents, scope) do
    if contents == Install.shim(scope),
      do: Check.ok("shim", "#{shim_path(scope)} is current"),
      else:
        Check.fail(
          "shim",
          "#{shim_path(scope)} differs from what init writes",
          init_fix(scope)
        )
  end

  @doc """
  A review loop left over from before ADR-0048, if this repo still has one.

  Nothing runs it any more. Saying so is all the doctor does — removing it is
  the person's call (ADR-0038, ADR-0007). A repo without one gets no line at
  all: a check that can only ever say "none" is noise in every other report.
  """
  @spec review_loop(Path.t()) :: Check.t()
  def review_loop(main_checkout) do
    path = Path.join(main_checkout, Install.review_loop_path())

    if File.exists?(path),
      do:
        Check.warn(
          "review loop",
          "#{Install.review_loop_path()} is retired — nothing runs it, and finishing is the whiska-finish skill",
          "rm #{path}"
        ),
      else: Check.ok("review loop", "none")
  end

  # A repo with no copy of its own has nothing to say here: the global install
  # draws the line, and `statusline/2` already reports on that.
  defp repo_statusline_script(main_checkout) do
    case File.read(Path.join(main_checkout, Install.statusline_path())) do
      {:ok, contents} -> [statusline_script(contents)]
      {:error, _} -> []
    end
  end

  defp retired(main_checkout) do
    case review_loop(main_checkout) do
      %Check{status: :ok} -> []
      check -> [check]
    end
  end

  @doc """
  Run the repo's installed hook for real, through its shim.

  The payload's `cwd` is a fresh temporary directory outside any worktree, so
  `pre-tool-use` allows, `stop` and `user-prompt-submit` are no-ops, and
  `session-start` prints the main session's rules: nothing is minted, nothing
  lands on a doorstep, no answer is taken. What is being tested is everything
  before that point — the shim finds a binary and a runtime, and the binary
  knows this hook. For `session-start` it is also the rules themselves: a run
  that prints none is a session started without them (ADR-0081).

  The shim fails open by design (ADR-0035), so exit 0 is not enough: its
  complaint on stderr is what says the call was allowed by accident.
  """
  @spec probe(Path.t(), String.t(), map(), Path.t() | nil, Install.scope()) :: Check.t()
  def probe(repo_root, hook, env, shim_root \\ nil, scope \\ :repo) do
    name = "hook #{hook}"
    shim = Path.join(shim_root || repo_root, Install.shim_path())

    tmp =
      Path.join(System.tmp_dir!(), "whiska-doctor-probe-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp)

    try do
      payload_file = Path.join(tmp, "payload.json")
      stderr_file = Path.join(tmp, "stderr")
      File.write!(payload_file, JSON.encode!(payload(hook, tmp)))

      {out, status} =
        System.cmd(
          "sh",
          [
            ~s|-c|,
            ~s|payload=$1 stderr=$2; shift 2; bash "$0" "$@" < "$payload" 2> "$stderr"|,
            shim,
            payload_file,
            stderr_file | hook_args(hook, scope)
          ],
          env: probe_env(env, hook),
          cd: tmp
        )

      stderr = File.read!(stderr_file)
      complaint = stderr |> String.split("\n", trim: true) |> List.first()

      cond do
        status != 0 ->
          Check.fail(name, "exit #{status}: #{complaint || "no output"}", @reinstall)

        String.contains?(stderr, "whiska:") ->
          Check.fail(name, "allowed by accident — #{complaint}", @reinstall)

        hook == "session-start" ->
          if rules?(out),
            do: Check.ok(name, "runs through #{shim}, and hands out the rules"),
            else:
              Check.fail(
                name,
                "ran, and printed no rules — sessions start without them",
                @reinstall
              )

        String.trim(out) != "" ->
          Check.fail(
            name,
            "unexpected output from a no-op probe: #{String.trim(out)}",
            @reinstall
          )

        true ->
          Check.ok(name, "runs through #{shim}")
      end
    after
      File.rm_rf(tmp)
    end
  end

  # The shim leaves early where a hook has nothing to do — a project folder
  # outside a worktree, a prompt with no answer flag, a session outside herdr —
  # and a probe that leaves there proves nothing about the binary. So the
  # project folder is unset and herdr is claimed, which carries every hook
  # through to `whiska hook`, where the temporary `cwd` makes it a no-op. A nil
  # value is what unsets it: a key left out is inherited from the doctor's own
  # environment, which a Claude session sets.
  defp probe_env(env, hook) do
    env
    |> Map.put("CLAUDE_PROJECT_DIR", nil)
    |> then(&if hook == "session-start", do: Map.put(&1, "HERDR_ENV", "1"), else: &1)
    |> Map.to_list()
  end

  # What the scope's own settings entry passes the shim, so the probe takes the
  # same path through the binary as the real hook does.
  defp hook_args("session-start", :global), do: ["session-start", "--global"]
  defp hook_args(hook, _scope), do: [hook]

  defp rules?(out) do
    case JSON.decode(String.trim(out)) do
      {:ok, %{"hookSpecificOutput" => %{"additionalContext" => rules}}} when is_binary(rules) ->
        String.trim(rules) != ""

      _ ->
        false
    end
  end

  defp payload("session-start", cwd), do: %{"cwd" => cwd, "source" => "startup"}
  defp payload("user-prompt-submit", cwd), do: %{"cwd" => cwd, "prompt" => "whiska doctor probe"}

  defp payload("pre-tool-use", cwd),
    do: %{
      "cwd" => cwd,
      "tool_name" => "Read",
      "tool_input" => %{"file_path" => Path.join(cwd, "probe")}
    }

  # Deliberately not a `done` marker: a probe carrying one is a probe that looks
  # like a finished turn. The doctor checks; it never sets anything going
  # (ADR-0038).
  defp payload("stop", cwd),
    do: %{
      "cwd" => cwd,
      "last_assistant_message" => "whiska doctor probe"
    }

  # -- this repo's house -------------------------------------------------------

  defp house(main_checkout, panes, herdr, socket, now, env) do
    path = Storage.database_path(main_checkout)

    # Unnamed: the doctor only reads the house from this process, so it needs
    # no name every other opener in the VM would have to avoid.
    try do
      case Storage.open(main_checkout, name: nil) do
        {:ok, handle} ->
          try do
            version = Storage.schema_version()
            main_pane = Storage.main_pane()
            word = main_word(main_pane, panes, herdr, socket)

            mode = Mode.read()
            waiting = Storage.questions()
            open = Mode.open_count(waiting, mode)
            sent = Enum.find(waiting, &(&1.status == "sent" and Mode.deliverable?(&1, mode)))
            box = draft(main_pane, word, herdr, socket)

            in_house =
              [
                main_session(main_pane, word, env["HERDR_PANE_ID"]),
                session_wiring(
                  session_started_at(word, main_checkout, env),
                  settings_changes(main_checkout, env)
                ),
                prompt_box(box, scroll_offset(word)),
                questions(open, sent, main_pane != nil, box, now),
                set_aside(mode, focus_name(mode), held_names(mode))
              ] ++ mice(Storage.all(Mouse), panes, MapSet.new(Storage.chased(), & &1.mouse_id))

            {Check.ok("house", "#{path}, schema v#{version}"), in_house}
          after
            Storage.close(handle)
          end

        {:error, reason} ->
          {Check.fail("house", "cannot open #{path} (#{inspect(reason)})"), []}
      end
    rescue
      e -> {Check.fail("house", "cannot open #{path} (#{Exception.message(e)})"), []}
    end
  end

  # The same screen read the delivery gate makes (ADR-0047, ADR-0068), taken
  # whenever there is a main pane running Claude to ask about. It is read even
  # with nothing queued: a box the gate can no longer find stops delivery
  # whether or not anything is waiting yet, and that is the warning worth
  # arriving early.
  defp draft(pane, {:ok, %{agent: "claude"}}, herdr, socket) when is_binary(pane) do
    case herdr.read_screen(socket, pane) do
      {:ok, screen} -> Draft.read(screen)
      {:error, _reason} -> :not_checked
    end
  end

  defp draft(_pane, _word, _herdr, _socket), do: :not_checked

  defp scroll_offset({:ok, pane}), do: Map.get(pane, :scroll_offset)
  defp scroll_offset(_no_word), do: nil

  # herdr's fresh word on the main pane — the same call the delivery gate
  # makes, so the doctor and the owl agree on what "running Claude" means.
  defp main_word(nil, _panes, _herdr, _socket), do: :unknown
  defp main_word(_pane, :unknown, _herdr, _socket), do: :unknown
  defp main_word(pane, {:ok, _}, herdr, socket), do: herdr.pane(socket, pane)

  @doc """
  Where delivery would go: the pane `whiska start` recorded, judged by herdr's
  fresh word on it (`{:ok, pane}`, `{:error, reason}`, or `:unknown` when herdr
  could not be asked). Every bad state is a warning, not a failure — the owl
  holds the queue and nothing is lost — but it is the first thing to read when
  the mice have gone quiet.
  """
  @spec main_session(
          String.t() | nil,
          {:ok, Herdr.pane()} | {:error, term()} | :unknown,
          String.t() | nil
        ) :: Check.t()
  def main_session(pane, word, here \\ nil)

  def main_session(nil, _word, _here) do
    Check.warn(
      "main session",
      "not recorded — nothing is delivered until it is",
      "whiska start  (from the main checkout's pane)"
    )
  end

  def main_session(pane, :unknown, here),
    do: Check.ok("main session", "#{named(pane, here)}, not checked (herdr unreachable)")

  def main_session(pane, {:ok, %{agent: "claude", agent_status: status}}, here),
    do: Check.ok("main session", "#{named(pane, here)}, claude #{status}")

  def main_session(pane, {:ok, %{agent: nil}}, here),
    do:
      Check.warn(
        "main session",
        "#{named(pane, here)} is not running Claude — questions wait",
        @restart
      )

  def main_session(pane, {:ok, %{agent: other}}, here),
    do:
      Check.warn(
        "main session",
        "#{named(pane, here)} runs #{other}, not Claude — questions wait",
        @restart
      )

  def main_session(pane, {:error, _reason}, here),
    do:
      Check.warn(
        "main session",
        "recorded as #{named(pane, here)}, but herdr has no such pane",
        @restart
      )

  # A pane id is not something a person recognises on sight, so the line says
  # whether it is the pane they are asking from (ADR-0065). Outside a herdr
  # pane there is nothing to compare it with, and the id stands alone.
  defp named(pane, here) when here in [nil, ""], do: pane
  defp named(pane, pane), do: "#{pane} (this pane)"
  defp named(pane, _elsewhere), do: "#{pane} (not this pane)"

  @doc """
  Whether the main session is showing a prompt box at all (ADR-0068).

  The delivery gate reads this screen before every line it types, and two of
  its four answers mean nothing will be typed again until something changes.
  Neither is visible from outside: the queue simply stops moving. This is the
  line that names it, so a Claude Code that has changed how it draws the box
  reads as one warning about the box rather than as every mouse going quiet.

  `scroll_offset` is how far above the bottom the pane's viewport is sitting.
  The person scrolling up past their own prompt box is the ordinary way to have
  no box on the screen, it is nobody's fault, and it ends the moment they scroll
  back — so it is reported and not warned about. A check that cries wolf at
  someone reading their own scrollback is worse than none.

  A box on the screen is always `ok`, whatever is typed in it: a draft holds
  delivery for seconds, by design, and the queue's own line says so.
  """
  @typedoc "A `Whiska.Delivery.Draft` reading, or the screen nobody read."
  @type reading :: Draft.t() | :not_checked

  @spec prompt_box(reading(), non_neg_integer() | nil) :: Check.t()
  def prompt_box(:not_checked, _scroll_offset),
    do: Check.ok("prompt box", "not checked — herdr was not asked for the main session's screen")

  def prompt_box(:empty, _scroll_offset), do: Check.ok("prompt box", "on screen, empty")

  def prompt_box(:typing, _scroll_offset),
    do: Check.ok("prompt box", "on screen, with something typed in it")

  def prompt_box(:no_box, scrolled) when is_integer(scrolled) and scrolled > 0,
    do:
      Check.ok(
        "prompt box",
        "not on screen — the pane is scrolled #{scrolled} rows up from it, and delivery " <>
          "waits until it is back"
      )

  def prompt_box(:no_box, _at_the_bottom),
    do:
      Check.warn(
        "prompt box",
        "no prompt box on the main session's screen, and the pane is not scrolled away " <>
          "from one — either a dialog is waiting on you there, or Claude Code has changed " <>
          "how it draws the box. Questions wait until one is found",
        "look at the main session's pane: answer whatever is waiting there"
      )

  def prompt_box(:unknown, _scroll_offset),
    do:
      Check.warn(
        "prompt box",
        "the box's frame is on the main session's screen and the line inside it is not one " <>
          "Whiska can read — Claude Code has changed how it draws the box, and delivery is " <>
          "delivering anyway rather than guessing",
        "herdr pane read <main pane> --source visible --format ansi, then fix " <>
          "Whiska.Delivery.Draft against what it prints"
      )

  @doc """
  The queue as a diagnosis, not a listing (`whiska questions` is the listing):
  how many are open, whether one is sent and for how long, whether the queue is
  held because the main session's prompt box has something half-typed in it or
  is not on the screen at all (ADR-0047, ADR-0068) — and a warning for
  each combination that means nothing can move: open questions with no main
  session to deliver them to, and a sent question whose mouse is dead. The
  second holds ADR-0008's one slot with nothing behind it able to move — no
  answer can reach a dead mouse, so it is never settled by being answered.
  `mark_dead/1` takes a dead mouse's sent question out of the queue for exactly
  that reason — settled or orphaned by its branch (ADR-0064) —
  so seeing one here means the owl has not reconciled it yet, or is not running.
  """
  @spec questions(
          non_neg_integer(),
          Question.t() | nil,
          boolean(),
          reading(),
          DateTime.t()
        ) :: Check.t()
  def questions(0, nil, _main?, _draft, _now), do: Check.ok("questions", "none waiting")

  def questions(open, nil, false, _draft, _now) when open > 0 do
    Check.warn(
      "questions",
      "#{open} open, cannot be delivered — no main session",
      "whiska start  (from the main checkout's pane)"
    )
  end

  def questions(open, %Question{mouse: %Mouse{died_at: %DateTime{}}} = sent, _main?, _draft, now) do
    Check.warn(
      "questions",
      "#{open} open, #{out_for(sent, now)} — its mouse #{branch_of(sent.mouse)} is dead, " <>
        "holding the delivery slot: nothing else can be delivered until it lets go",
      @restart_owl
    )
  end

  def questions(open, sent, _main?, draft, now) do
    parts =
      ["#{open} open"] ++
        if(sent, do: [out_for(sent, now)], else: []) ++
        if(open > 0 and is_nil(sent), do: held(draft), else: [])

    Check.ok("questions", Enum.join(parts, ", "))
  end

  defp held(:typing), do: ["gated: person is typing"]
  defp held(:no_box), do: ["gated: the prompt box is not on screen"]
  defp held(_free), do: []

  @doc """
  What the person set aside (ADR-0079):
  away, this house's focus by the branch's name, and the branches on hold —
  each with the word that ends it. Never a warning: every one of them is
  something the person did on purpose.
  """
  @spec set_aside(Mode.t(), String.t() | nil, [String.t()]) :: Check.t()
  def set_aside(%{away?: away?, focus: focus}, focus_name, held) do
    parts =
      [
        if(away?, do: "away: nothing is delivered anywhere until `resume`"),
        if(focus,
          do: "focus: #{focus_name || focus} — only its questions reach the main session"
        ),
        if(held != [], do: "held: #{Enum.join(held, ", ")} — stopped until `resume <branch>`")
      ]
      |> Enum.reject(&is_nil/1)

    case parts do
      [] -> Check.ok("set aside", "nothing — every question flows")
      _ -> Check.ok("set aside", Enum.join(parts, "; "))
    end
  end

  defp focus_name(%{focus: nil}), do: nil
  defp focus_name(%{focus: id}), do: branch_of(Storage.mouse(id) || %Mouse{mouse_id: id})

  defp held_names(%{held: held}) do
    held
    |> Enum.map(&branch_of(Storage.mouse(&1) || %Mouse{mouse_id: &1}))
    |> Enum.sort()
  end

  @doc """
  The one-word commands `whiska init --global` writes under the whiska home:
  nothing written is fine (the per-repo install writes none), and so is written
  but off PATH, since the same eight are slash commands in the main session.
  Shadowed by another program that comes first, or a file Whiska did not write,
  is a warning naming what to do. `dir` is `Whiska.Install.commands_dir/0` unless a test pins it.
  """
  @spec commands(Path.t(), map()) :: Check.t()
  def commands(dir, env) do
    words = Install.commands()
    written = Enum.filter(words, &executable?(Path.join(dir, &1)))

    cond do
      written == [] and foreign(dir, words) == [] ->
        Check.ok(
          "commands",
          "not installed — `whiska init --global` writes #{Enum.join(words, ", ")} to #{dir}"
        )

      (strangers = foreign(dir, words)) != [] ->
        Check.warn(
          "commands",
          "#{dir} goes first on PATH and holds #{Enum.join(strangers, ", ")}, which " <>
            "Whiska did not write — anything that can write under the whiska home can " <>
            "put a program there",
          "look at each, and remove what you did not put there"
        )

      not on_path?(env, dir) ->
        Check.ok(
          "commands",
          "#{dir} is not on PATH — the slash commands work; add it to type " <>
            "#{Enum.join(written, ", ")} in a shell"
        )

      true ->
        case shadowed(env, dir, written) do
          [] ->
            Check.ok(
              "commands",
              "#{length(written)} of #{length(words)} on PATH" <> left_out(words -- written)
            )

          shadowed ->
            Check.warn(
              "commands",
              "another program comes first on PATH: " <> Enum.join(shadowed, ", "),
              "put #{dir} ahead of it on PATH, or use the long `whiska` names"
            )
        end
    end
  end

  # Anything in the directory that is not one of the eight, or is one by name
  # with something other than Whiska's script inside, or is a link.
  defp foreign(dir, words) do
    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.sort()
        |> Enum.reject(fn name ->
          name in words and match?({:error, _}, :file.read_link(Path.join(dir, name))) and
            File.read(Path.join(dir, name)) == {:ok, Install.command_script(name)}
        end)

      {:error, _} ->
        []
    end
  end

  defp on_path?(env, dir) do
    (env["PATH"] || "")
    |> String.split(":", trim: true)
    |> Enum.any?(&(Path.expand(&1) == Path.expand(dir)))
  end

  defp shadowed(env, dir, words) do
    for word <- words,
        found = find_on_path(env, word),
        found != nil,
        Path.expand(found) != Path.expand(Path.join(dir, word)),
        do: "#{word} → #{found}"
  end

  defp left_out([]), do: ""

  defp left_out(words),
    do: " (not written: #{Enum.join(words, ", ")} — another program had the word)"

  defp out_for(%Question{id: id, sent_at: at}, now),
    do: "1 sent (id #{id}, waiting #{age(DateTime.diff(now, at, :second))})"

  defp branch_of(%Mouse{branch: branch}) when is_binary(branch), do: branch
  defp branch_of(%Mouse{mouse_id: id}), do: id

  @doc "Uncollected entries: none is ok; any is a warning carrying the count and the oldest age."
  @spec doorstep([{Path.t(), Entry.t()} | Entry.t()], DateTime.t()) :: Check.t()
  def doorstep([], _now), do: Check.ok("doorstep", "nothing waiting")

  def doorstep(entries, now) do
    stamps =
      Enum.map(entries, fn
        {_file, %Entry{stamped_at: at}} -> at
        %Entry{stamped_at: at} -> at
      end)

    oldest = stamps |> Enum.min(DateTime) |> then(&DateTime.diff(now, &1, :second))
    Check.warn("doorstep", "#{length(entries)} waiting, oldest #{age(oldest)}", @owl)
  end

  @doc """
  Has the backstop been doing the idle trigger's job (ADR-0036)?

  The backstop is the last resort: anything it collects is something herdr's
  idle event should have brought a minute earlier, so a mark left by the house
  (`Whiska.Backstop`, cleared when the owl opens the house) means the trigger
  is not reaching the owl. Everything still arrives, a minute late and with no
  other symptom — which is exactly how a trigger that had never once fired went
  unseen for weeks. A warning, never a failure: nothing is lost.
  """
  @spec backstop(Backstop.mark() | nil, DateTime.t()) :: Check.t()
  def backstop(nil, _now),
    do: Check.ok("backstop", "nothing collected by it since the owl opened this house")

  def backstop(%{count: count, last: last}, now) do
    Check.warn(
      "backstop",
      "collected #{entries(count)} the idle trigger missed, last #{age(DateTime.diff(now, last, :second))} ago — " <>
        "the herdr idle trigger is not reaching the owl; check the subscription and the herdr version",
      @restart_owl
    )
  end

  defp entries(1), do: "1 entry"
  defp entries(n), do: "#{n} entries"

  defp age(seconds) when seconds < 60, do: "#{seconds} s"
  defp age(seconds) when seconds < 3600, do: "#{div(seconds, 60)} min"
  defp age(seconds), do: "#{div(seconds, 3600)} h #{div(rem(seconds, 3600), 60)} min"

  @doc """
  Do the live mouse records still match the world? One check per live mouse.

  A record is judged against the filesystem (is the worktree there, does its
  marker still hold this id) and against herdr's panes (`{:ok, panes}`, or
  `:unknown` when herdr could not be asked, in which case panes are not
  judged). Dead records are left out. Nothing is marked: reconciling is the
  owl's job (ADR-0026).

  `waiting` are the mice with an answer chased and not yet taken (ADR-0080).
  The hook shim hands one over only while the worktree's answer flag is up, so
  one of those with no flag gets a line of its own: that answer never reaches
  its mouse. A flag up with nothing waiting costs an escript start per prompt
  and clears itself on the next one, so it gets none.
  """
  @spec mice([Mouse.t()], {:ok, [Herdr.pane()]} | :unknown, MapSet.t(String.t())) ::
          [Check.t()]
  def mice(mice, panes, waiting \\ MapSet.new()) do
    for %Mouse{died_at: nil} = mouse <- mice,
        check <- [mouse_check(mouse, panes) | flag_check(mouse, waiting)],
        do: check
  end

  # Only a mouse the doorbell would ring: a held one is rung once resumed, and a
  # landed or removed one never (ADR-0064, ADR-0079).
  defp flag_check(%Mouse{held_at: nil, landed_at: nil, removed_at: nil} = mouse, waiting) do
    %Mouse{mouse_id: id, path: path, branch: branch} = mouse

    with true <- MapSet.member?(waiting, id),
         true <- File.dir?(path),
         {:ok, flag} <- AnswerFlag.path(path),
         false <- File.exists?(flag) do
      [
        Check.warn(
          "mice",
          "#{branch}: an answer is waiting and the answer flag is down — unless the owl " <>
            "rings again, it is never handed over"
        )
      ]
    else
      _ -> []
    end
  end

  defp flag_check(_not_rung, _waiting), do: []

  defp mouse_check(%Mouse{branch: branch, path: path, mouse_id: id}, panes) do
    cond do
      not File.dir?(path) ->
        Check.warn(
          "mice",
          "#{branch}: worktree gone (#{path}), record not marked dead",
          "#{@owl} — reconciles on open"
        )

      marker(path) != id ->
        Check.warn("mice", "#{branch}: marker in the worktree does not match the record")

      panes == :unknown ->
        Check.ok("mice", "#{branch}: worktree present, pane not checked (herdr unreachable)")

      pane = live_pane(panes, path) ->
        Check.ok("mice", "#{branch}: live pane #{pane.pane_id}")

      true ->
        Check.warn("mice", "#{branch}: no live pane — dead, or not started yet")
    end
  end

  defp marker(worktree_root) do
    case File.read(Marker.path(worktree_root)) do
      {:ok, contents} -> String.trim(contents)
      _ -> nil
    end
  end

  defp live_pane({:ok, panes}, path) do
    Enum.find(panes, &(&1.agent != nil and is_binary(&1.cwd) and Layout.inside?(&1.cwd, path)))
  end

  # -- reading the repo --------------------------------------------------------

  defp read_settings(main_checkout) do
    with {:ok, raw} <- File.read(Path.join(main_checkout, ".claude/settings.json")),
         {:ok, settings} when is_map(settings) <- JSON.decode(raw) do
      settings
    else
      _ -> %{}
    end
  end

  defp read_shim(root) do
    case File.read(Path.join(root, Install.shim_path())) do
      {:ok, contents} -> contents
      _ -> nil
    end
  end

  # Which install's shim this repo actually runs. The repo's own wins when it
  # is there (ADR-0056: a repo that wires Whiska itself keeps winning, and the
  # global shim stands down for it); otherwise a global install is what is
  # running, and its shim is the one to check. With neither, the repo is the
  # honest subject of the complaint and `whiska init` the honest fix.
  defp shim_in_force(main_checkout, global_state) do
    cond do
      File.exists?(Path.join(main_checkout, Install.shim_path())) -> {:repo, main_checkout}
      global_state[:hooks?] -> {:global, Install.root(:global)}
      true -> {:repo, main_checkout}
    end
  end

  # How the person would type the path, so the two scopes cannot be read as one.
  defp shim_path(:repo), do: Install.shim_path()
  defp shim_path(:global), do: "~/#{Install.shim_path()}"

  defp init_fix(:repo), do: @init
  defp init_fix(:global), do: @init_global

  # Only where this checkout has both a build and a binary to compare it with:
  # elsewhere the line could only ever say "nothing built here" (ADR-0038's
  # rule, as the retired review loop reads it).
  defp built(main_checkout, installed_at, installed) do
    escript = Path.join(main_checkout, "whiska")

    with true <- File.regular?(Path.join(main_checkout, "mix.exs")),
         true <- executable?(escript),
         %DateTime{} = built_at <- changed_at(escript),
         %DateTime{} <- installed_at do
      [build(built_at, installed_at, escript, installed)]
    else
      _nothing_to_compare -> []
    end
  end

  # The files Whiska wires its hooks into, which the session wiring check
  # compares itself against. The `.local` ones are left out: Whiska never writes
  # them, and Claude Code rewrites them on every permission granted. Either can
  # be absent; a repo wired globally has only the home's.
  defp settings_changes(main_checkout, env) do
    [
      {".claude/settings.json", Path.join(main_checkout, ".claude/settings.json")},
      {"~/.claude/settings.json", Path.join(home(env), ".claude/settings.json")}
    ]
    |> Enum.flat_map(fn {label, path} ->
      case changed_at(path) do
        %DateTime{} = at -> [{label, at}]
        nil -> []
      end
    end)
  end

  # herdr's answer is somebody else's string, and it is about to become a file
  # path: anything but a plain id is not a session this can find, and a `/` or a
  # `..` in one would be a read outside Claude Code's own folder.
  @session_id ~r/^[A-Za-z0-9_-]+$/

  # When the main session started, found the way ADR-0053 identifies a session:
  # herdr names the session id for the pane, and that is the transcript's name
  # inside Claude Code's folder for the directory it started in.
  defp session_started_at({:ok, %{session: session}}, main_checkout, env)
       when is_binary(session) do
    if Regex.match?(@session_id, session), do: transcript_start(session, main_checkout, env)
  end

  defp session_started_at(_word, _main_checkout, _env), do: nil

  defp transcript_start(session, main_checkout, env) do
    main_checkout
    |> Transcript.project_dir(home(env))
    |> Path.join(session <> ".jsonl")
    |> Transcript.started_at()
  end

  defp changed_at(nil), do: nil

  defp changed_at(path) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{type: :regular, mtime: at}} -> DateTime.from_unix!(at)
      _unreadable -> nil
    end
  end

  defp home(env), do: env["HOME"] || System.user_home!()

  defp executable?(nil), do: false
  defp executable?(""), do: false

  defp executable?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, mode: mode}} -> Bitwise.band(mode, 0o111) != 0
      _ -> false
    end
  end

  defp find_on_path(env, name) do
    (env["PATH"] || "")
    |> String.split(":", trim: true)
    |> Enum.map(&Path.join(&1, name))
    |> Enum.find(&executable?/1)
  end
end
