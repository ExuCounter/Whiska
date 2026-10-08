defmodule Whiska.E2ETest do
  @moduledoc """
  The real `whiska` binary, a real herdr, a real SQLite file and the repo's
  real hook wiring, with a scripted Claude in each pane
  (`test/support/fake_claude/claude`).

  Every other test here stands in for herdr (ADR-0031), the clock or the
  screen. This one stands in for the model alone. herdr's own detection rules
  read the fake's screen and decide idle or working, the owl's gate reads the
  same screen through `pane.read`, and a turn's end reaches the doorstep
  through `.claude/settings.json` and the shim `whiska init` wrote.

  herdr runs as a private named session, so nothing appears in the person's own
  herdr, and is stopped and deleted afterwards. Its session directory lives
  under `~/.config/herdr/sessions/` while the test runs — herdr has no way to
  put it anywhere else. A run killed before its cleanup leaves the session
  running: `herdr session list` names it `whiska-e2e-…`.

  Excluded by default: it costs about fifty seconds, most of it the owl's real
  round wait (ADR-0008). `mix test.e2e` runs it.
  """

  use ExUnit.Case, async: false

  @moduletag :e2e
  @moduletag timeout: 180_000

  @root Path.expand("../..", __DIR__)
  @binary Path.join(@root, "whiska")
  @fake_claude Path.join(@root, "test/support/fake_claude/claude")
  @done_marker String.duplicate("\u2063", 3)

  setup_all do
    herdr = System.find_executable("herdr") || flunk("herdr is not on PATH")

    {_, 0} =
      System.cmd("mix", ["escript.build"],
        cd: @root,
        env: [{"MIX_ENV", "dev"}],
        stderr_to_stdout: true
      )

    # Resolved, because macOS's temp folder is behind a symlink and git and
    # herdr report the resolved path: given the other spelling, `whiska owl`
    # opens the same house twice.
    id = 6 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    run = Path.join(System.tmp_dir!(), "whiska-e2e-#{id}")
    File.mkdir_p!(run)
    {resolved, 0} = System.cmd("pwd", ["-P"], cd: run)
    run = String.trim(resolved)
    bin = Path.join(run, "bin")
    File.mkdir_p!(bin)
    File.ln_s!(@fake_claude, Path.join(bin, "claude"))
    File.ln_s!(@binary, Path.join(bin, "whiska"))
    fake_notifier(Path.join(bin, "terminal-notifier"))
    no_service_manager(Path.join(bin, "launchctl"))
    no_service_manager(Path.join(bin, "systemctl"))

    # The person's own herdr config chooses their shell and its profile, and a
    # profile can put the real `claude` ahead of the fake on PATH.
    config = Path.join(run, "herdr.toml")

    File.write!(config, """
    [terminal]
    default_shell = "/bin/sh"
    shell_mode = "non_login"
    """)

    session = "whiska-e2e-#{id}"

    # Everything a pane and the owl inherit. `claude` and `whiska` resolve to
    # the fake and to the binary under test.
    env = [
      {"PATH", bin <> ":" <> System.get_env("PATH")},
      {"SHELL", "/bin/sh"},
      {"HERDR_CONFIG_PATH", config},
      {"LANG", "en_US.UTF-8"},
      {"LC_ALL", "en_US.UTF-8"},
      {"WHISKA_BIN", @binary},
      {"HERDR_SOCKET_PATH", nil},
      {"HERDR_PANE_ID", nil},
      {"HERDR_ENV", nil}
    ]

    server =
      Port.open({:spawn_executable, herdr}, [
        :binary,
        :stderr_to_stdout,
        args: ["--session", session, "server"],
        env: port_env(env)
      ])

    on_exit(fn ->
      System.cmd(herdr, ["session", "stop", session], stderr_to_stdout: true)
      System.cmd(herdr, ["session", "delete", session], stderr_to_stdout: true)
      if Port.info(server), do: Port.close(server)
      File.rm_rf!(run)
    end)

    socket = wait_for_socket(herdr, session)
    env = List.keystore(env, "HERDR_SOCKET_PATH", 0, {"HERDR_SOCKET_PATH", socket})
    {:ok, herdr: herdr, env: env, run: run}
  end

  setup context do
    dir = Path.join(context.run, "t#{System.unique_integer([:positive])}")
    main = Path.join(dir, "myrepo")
    File.mkdir_p!(main)

    # A home of its own per test, where the owl keeps its hoots.
    home = Path.join(dir, "home")
    env = List.keystore(context.env, "WHISKA_HOME", 0, {"WHISKA_HOME", home})

    git!(main, ["init", "-q", "-b", "main"])
    File.write!(Path.join(main, "README.md"), "e2e\n")
    {_, 0} = System.cmd(@binary, ["init"], cd: main, env: env, stderr_to_stdout: true)
    git!(main, ["add", "-A"])
    git!(main, ["commit", "-q", "-m", "init"])

    worktree = Path.join(main, "worktrees/feat-x")
    git!(main, ["worktree", "add", "-q", "-b", "feat-x", worktree])

    {:ok, dir: dir, main: main, worktree: worktree, env: env, home: home}
  end

  test "a finished turn reaches the main session through the real owl, in a house built by an older Whiska",
       c do
    # The house as the last release left it: schema 6, before ADR-0069, with
    # mice in it. Whatever opens it first under this binary runs migration 7.
    older = seed_schema_6(c.main, ["old-1", "old-2", "old-3"])

    main = start_main_session(c)
    mouse = start_mouse(c)
    owl = start_owl(c)

    finish_turn(c, mouse, "The search box filters as you type.\n#{@done_marker}")

    line = await_line(c, main, &String.starts_with?(&1, "🐱 feat-x finished"), 40_000)
    assert line =~ ~r/^🐱 feat-x finished · #\d+$/
    assert query(c.main, "select count(*) from questions") == ["1"], diagnostics(c)

    assert File.read!(Path.join(c.home, "hoots")) =~ "feat-x",
           "no hoot went out with the line (ADR-0062)"

    assert shaped_at(c.main, older) == [
             "2026-09-01T10:00:00Z",
             "2026-09-02T10:00:00Z",
             "2026-09-03T10:00:00Z"
           ],
           "migration 7 did not stamp the mice the house already had"

    stop_owl(owl)
  end

  test "a draft in the main session's box holds the line until the person sends it", c do
    main = start_main_session(c)
    mouse = start_mouse(c)
    owl = start_owl(c)

    herdr!(c, ["pane", "send-text", main.pane, "half a thought"])
    await_screen(c, main.pane, &(&1 =~ "❯ half a thought"))

    finish_turn(c, mouse, "Which colour for the badge?\n\u2063\u2063")

    # The main checkout's sidebar line says so only once the hold has outlasted
    # its fuse (ADR-0082), so this is the owl having tried and held, not merely
    # the owl being slow.
    await(
      fn -> sidebar(c)["main"]["whiska"] == "⏳ gated: you're typing" end,
      40_000,
      fn ->
        "the sidebar never said the draft held delivery.\n" <>
          "received: #{inspect(received(main))}\n" <> diagnostics(c)
      end
    )

    # The mouse's own workspace carries the question it is waiting on.
    assert %{"whiska" => "🐭 #" <> said, "whiska_q" => "Which colour for the badge?"} =
             sidebar(c)["mouse"],
           diagnostics(c)

    assert said =~ ~r/^\d+ · waiting on you$/

    assert received(main) == []

    herdr!(c, ["pane", "send-keys", main.pane, "Enter"])

    await_line(c, main, &String.starts_with?(&1, "🐱 feat-x needs a decision"), 20_000)
    assert [draft, line] = received(main)
    assert draft == "half a thought", "the owl's line landed inside the person's draft"
    assert line =~ ~r/^🐱 feat-x needs a decision · #\d+ · /

    stop_owl(owl)
  end

  # -- the panes -----------------------------------------------------------------

  # `whiska start` typed at the main checkout's shell, exactly as the person
  # runs it: it records the pane and types `claude` itself (ADR-0066).
  defp start_main_session(c) do
    pane = open_workspace(c, c.main, "main")
    herdr!(c, ["pane", "run", pane.pane, "whiska start"])
    await_agent(c, pane.pane)
    pane
  end

  # What spawn-worktree types into a new mouse's pane (ADR-0069).
  defp start_mouse(c) do
    pane = open_workspace(c, c.worktree, "mouse")
    herdr!(c, ["pane", "run", pane.pane, "whiska shape build && claude"])
    await_agent(c, pane.pane)
    pane
  end

  defp open_workspace(c, cwd, role) do
    control = Path.join(c.dir, role)
    File.mkdir_p!(control)

    reply =
      herdr!(c, [
        "workspace",
        "create",
        "--cwd",
        cwd,
        "--label",
        role,
        "--no-focus",
        "--env",
        "FAKE_CLAUDE_DIR=#{control}",
        "--env",
        "FAKE_CLAUDE_ROLE=#{role}",
        "--env",
        "WHISKA_HOME=#{c.home}"
      ])

    %{"result" => %{"root_pane" => %{"pane_id" => pane}}} = JSON.decode!(reply)
    %{pane: pane, control: control}
  end

  defp finish_turn(c, mouse, message) do
    File.write!(Path.join(mouse.control, "message"), message)
    herdr!(c, ["agent", "prompt", mouse.pane, "go"])
  end

  defp received(pane) do
    case File.read(Path.join(pane.control, "received")) do
      {:ok, text} -> String.split(text, "\n", trim: true)
      {:error, :enoent} -> []
    end
  end

  defp await_line(c, pane, match?, timeout) do
    await(fn -> Enum.find(received(pane), match?) end, timeout, fn ->
      "nothing matching reached the main session.\n" <>
        "received: #{inspect(received(pane))}\n" <> diagnostics(c)
    end)
  end

  defp await_agent(c, pane) do
    await(
      fn ->
        case pane(c, pane) do
          %{"agent" => "claude", "terminal_title_stripped" => title}
          when title not in ["", "fake claude"] ->
            flunk("#{pane} is running a claude that is not the fake: #{screen(c, pane)}")

          %{"agent" => "claude", "agent_status" => status} ->
            status in ~w(idle done)

          _ ->
            false
        end
      end,
      15_000,
      fn ->
        "herdr never saw an idle claude in #{pane}: #{inspect(pane(c, pane))}\n" <>
          screen(c, pane)
      end
    )
  end

  defp await_screen(c, pane, match?) do
    await(fn -> match?.(screen(c, pane)) end, 5_000, fn -> screen(c, pane) end)
  end

  defp pane(c, pane) do
    %{"result" => %{"pane" => info}} = JSON.decode!(herdr!(c, ["pane", "get", pane]))
    info
  end

  defp screen(c, pane), do: herdr!(c, ["pane", "read", pane, "--source", "visible"])

  # -- the owl ---------------------------------------------------------------------

  # `whiska owl <repo>` in the foreground, the way a person runs it by hand.
  defp start_owl(c) do
    log = Path.join(c.dir, "owl.log")

    port =
      Port.open({:spawn_executable, "/bin/sh"}, [
        :binary,
        args: ["-c", ~s(exec "$0" owl "$1" > "$2" 2>&1), @binary, c.main, log],
        cd: c.main,
        env: port_env(c.env)
      ])

    {:os_pid, pid} = Port.info(port, :os_pid)
    on_exit(fn -> System.cmd("kill", [to_string(pid)], stderr_to_stdout: true) end)
    %{port: port, pid: pid, log: log}
  end

  defp stop_owl(owl), do: System.cmd("kill", [to_string(owl.pid)], stderr_to_stdout: true)

  # What herdr is showing under each workspace, by the label the test gave it.
  defp sidebar(c) do
    %{"result" => %{"workspaces" => workspaces}} = JSON.decode!(herdr!(c, ["workspace", "list"]))
    Map.new(workspaces, &{&1["label"], Map.get(&1, "tokens", %{})})
  end

  defp diagnostics(c) do
    files =
      for name <- ["owl.log", "mouse/hooks.log"],
          path = Path.join(c.dir, name),
          File.exists?(path),
          do: "--- #{name}\n#{File.read!(path)}"

    Enum.join(files ++ ["--- sidebar\n#{inspect(sidebar(c))}"], "\n")
  end

  # -- the house -------------------------------------------------------------------

  # A house at schema 6, written by the migrations that built it, with mice in
  # it. Returns their ids.
  defp seed_schema_6(main, mouse_ids) do
    path = Whiska.Storage.database_path(main)
    File.mkdir_p!(Path.dirname(path))

    migrations = [
      {1, Whiska.Migrations.V001CreateMiceAndQuestions},
      {2, Whiska.Migrations.V002OwlCollection},
      {3, Whiska.Migrations.V003Delivery},
      {4, Whiska.Migrations.V004Cleanup},
      {5, Whiska.Migrations.V005Landing},
      {6, Whiska.Migrations.V006Pickup}
    ]

    {:ok, repo} =
      Whiska.Repo.start_link(
        name: nil,
        database: path,
        pool_size: 1,
        journal_mode: :wal,
        log: false
      )

    Ecto.Migrator.run(Whiska.Repo, migrations, :up, all: true, dynamic_repo: repo, log: false)
    Whiska.Repo.put_dynamic_repo(repo)

    for {id, n} <- Enum.with_index(mouse_ids, 1) do
      Whiska.Repo.query!(
        "INSERT INTO mice (mouse_id, path, branch, mode, created_at) VALUES (?, ?, ?, 'build', ?)",
        [id, Path.join(main, "worktrees/#{id}"), id, "2026-09-0#{n}T10:00:00Z"]
      )
    end

    Whiska.Storage.close(repo)
    mouse_ids
  end

  defp shaped_at(main, ids) do
    in_list = Enum.map_join(ids, ",", &"'#{&1}'")
    query(main, "select shaped_at from mice where mouse_id in (#{in_list}) order by mouse_id")
  end

  # Read with the sqlite3 CLI, a reader that shares nothing with the binary.
  defp query(main, sql) do
    {out, 0} = System.cmd("sqlite3", [Whiska.Storage.database_path(main), sql <> ";"])
    String.split(out, "\n", trim: true)
  end

  # -- plumbing ----------------------------------------------------------------------

  defp herdr!(c, args) do
    case System.cmd(c.herdr, args, env: c.env, stderr_to_stdout: true) do
      {out, 0} -> out
      {out, status} -> flunk("herdr #{Enum.join(args, " ")} exited #{status}: #{out}")
    end
  end

  # A port's env takes charlists, and `false` to unset a variable.
  defp port_env(env),
    do: Enum.map(env, fn {k, v} -> {~c"#{k}", if(v, do: ~c"#{v}", else: false)} end)

  defp git!(cwd, args) do
    {_, 0} = System.cmd("git", args, cd: cwd, stderr_to_stdout: true)
  end

  defp wait_for_socket(herdr, session) do
    await(
      fn ->
        {out, _} = System.cmd(herdr, ["session", "list"], stderr_to_stdout: true)

        Enum.find_value(String.split(out, "\n"), fn row ->
          case String.split(row) do
            [^session, "running", _dir, socket] -> socket
            _ -> nil
          end
        end)
      end,
      10_000,
      fn -> "herdr session #{session} never came up" end
    )
  end

  # The hoot falls back to the desktop when herdr shows nothing, as a private
  # session with nobody attached never does (ADR-0062). This takes the
  # desktop's place on PATH, so a test run raises nothing on the screen.
  defp fake_notifier(path) do
    File.write!(path, """
    #!/bin/sh
    printf '%s\\n' "$*" >> "$WHISKA_HOME/hoots"
    """)

    File.chmod!(path, 0o755)
  end

  # The person's own owl runs under launchd or systemd, and a foreground owl
  # yields to it (ADR-0040). The test's owl serves a home of its own, so it is
  # told the service manager has nothing — and nothing here can reach the real
  # launchctl or systemctl.
  defp no_service_manager(path) do
    File.write!(path, "#!/bin/sh\nexit 113\n")
    File.chmod!(path, 0o755)
  end

  defp await(fun, timeout, explain) do
    deadline = System.monotonic_time(:millisecond) + timeout
    poll(fun, deadline, explain)
  end

  defp poll(fun, deadline, explain) do
    case fun.() do
      falsy when falsy in [nil, false] ->
        if System.monotonic_time(:millisecond) > deadline do
          flunk(explain.())
        else
          Process.sleep(200)
          poll(fun, deadline, explain)
        end

      found ->
        found
    end
  end
end
