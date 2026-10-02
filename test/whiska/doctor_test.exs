defmodule Whiska.DoctorTest do
  @moduledoc """
  `whiska doctor`: is Whiska working for this repo right now, and if not, what
  exactly is wrong. Checks, never repairs; probes the installed hooks live
  rather than trusting config.

  The pure checks take plain values and are tested without a filesystem. The
  probe runs the real shim against stub binaries, the same way the shim's own
  tests do. `run/2` ties them together on a temp repo, with herdr faked at the
  one boundary that allows it (ADR-0031).
  """
  use ExUnit.Case, async: false

  import Mox

  alias Whiska.Doctor
  alias Whiska.Doctor.Check
  alias Whiska.Doorstep
  alias Whiska.Doorstep.Entry
  alias Whiska.Herdr.Mock, as: Herdr
  alias Whiska.Install
  alias Whiska.Schema.Mouse
  alias Whiska.Storage

  setup :set_mox_global
  setup :verify_on_exit!

  @stripped_path "/usr/bin:/bin"

  defp find(checks, name), do: Enum.find(checks, &(&1.name == name))

  # -- hooks -------------------------------------------------------------------

  describe "hooks/1 — what settings.json wires" do
    test "a fresh init passes both" do
      checks = Doctor.hooks(Install.merge(%{}))

      assert %Check{status: :ok} = find(checks, "PreToolUse")
      assert %Check{status: :ok} = find(checks, "Stop")
    end

    test "no hooks at all fails both, pointing at init" do
      checks = Doctor.hooks(%{})

      assert %Check{status: :fail, fix: "whiska init"} = find(checks, "PreToolUse")
      assert %Check{status: :fail, fix: "whiska init"} = find(checks, "Stop")
    end

    test "a PreToolUse entry from before the shim took an argument is a fail, named as older" do
      old = %{
        "hooks" => %{
          "PreToolUse" => [
            %{
              "matcher" => Install.matcher(),
              "hooks" => [
                %{
                  "type" => "command",
                  "command" => ~s|bash "$CLAUDE_PROJECT_DIR/.claude/hooks/whiska.sh"|
                }
              ]
            }
          ]
        }
      }

      assert %Check{status: :fail, detail: detail} = Doctor.hooks(old) |> find("PreToolUse")
      assert detail =~ "older"
    end

    test "a narrower matcher is a fail — the rules silently never fire for the missing tools" do
      narrow =
        put_in(Install.merge(%{}), ["hooks", "PreToolUse", Access.at(0), "matcher"], "Write|Edit")

      assert %Check{status: :fail, detail: detail} = Doctor.hooks(narrow) |> find("PreToolUse")
      assert detail =~ "matcher"
    end

    test "a missing Stop hook says what it costs" do
      only_pre = update_in(Install.merge(%{}), ["hooks"], &Map.delete(&1, "Stop"))

      assert %Check{status: :fail, detail: detail} = Doctor.hooks(only_pre) |> find("Stop")
      assert detail =~ "cannot leave questions"
    end
  end

  # -- statusline --------------------------------------------------------------

  describe "statusline/1 — this repo's own line in the Claude statusline (ADR-0027)" do
    test "a fresh init passes: our script, and a refresh interval" do
      check = Doctor.statusline(Install.merge(%{}))

      assert %Check{status: :ok} = check
      assert check.detail =~ "#{Install.statusline_refresh_interval()}"
    end

    test "no statusLine at all is a warning, pointing at init" do
      assert %Check{status: :warn, fix: "whiska init"} = Doctor.statusline(%{})
    end

    test "ours with no interval warns: nothing redraws while the session sits idle" do
      settings = %{
        "statusLine" => %{"type" => "command", "command" => Install.statusline_command()}
      }

      check = Doctor.statusline(settings)
      assert %Check{status: :warn, fix: "whiska init"} = check
      assert check.detail =~ "idle"
    end

    test "an interval the person chose themselves is left alone" do
      settings = %{
        "statusLine" => %{
          "type" => "command",
          "command" => Install.statusline_command(),
          "refreshInterval" => 30
        }
      }

      check = Doctor.statusline(settings)
      assert %Check{status: :ok} = check
      assert check.detail =~ "30"
    end

    test "somebody else's statusLine warns that this repo's line is not shown" do
      settings = %{"statusLine" => %{"type" => "command", "command" => "bash mine.sh"}}

      assert %Check{status: :warn} = Doctor.statusline(settings)
    end
  end

  describe "statusline_script/1 — the copy of the script this repo carries (ADR-0059)" do
    test "the shipped script is up to date" do
      assert %Check{status: :ok} = Doctor.statusline_script(Install.statusline_script())
    end

    test "a copy from an older init is an upgrade notice, not a fault" do
      stale = """
      #!/usr/bin/env bash
      # Whiska's project statusline, as an older init wrote it.
      exec whiska statusline --here
      """

      check = Doctor.statusline_script(stale)
      assert %Check{status: :warn, fix: "whiska init"} = check
      assert check.detail =~ "whiska upgrade is available"
    end

    test "a copy stamped with an older version is an upgrade notice too" do
      older =
        String.replace(
          Install.statusline_script(),
          "whiska-statusline: v#{Install.statusline_version()}",
          "whiska-statusline: v1"
        )

      assert %Check{status: :warn, fix: "whiska init"} = Doctor.statusline_script(older)
    end
  end

  # -- the tab bar -------------------------------------------------------------

  describe "tab_bar/2 — the herdr entry that draws the owl's line (ADR-0048)" do
    test "the entry the person committed, naming the shipped script, passes" do
      check = Doctor.tab_bar(Install.tab_bar_right_snippet(), true)

      assert %Check{status: :ok} = check
      assert check.detail =~ "#{Install.herdr_status_interval()}"
    end

    test "no herdr config at all is a warning, and the fix is the entry to paste" do
      check = Doctor.tab_bar(nil, true)

      assert %Check{status: :warn} = check
      assert check.fix =~ "tab_bar_right"
      assert check.fix =~ Install.herdr_status_path()
    end

    test "a herdr config without our entry is a warning, and the fix is the entry to paste" do
      check = Doctor.tab_bar("[ui]\ntab_bar_right = [{ type = \"hostname\" }]\n", true)

      assert %Check{status: :warn} = check
      assert check.fix =~ Install.herdr_status_path()
    end

    test "an entry naming a script that is not there points at owl install, not at herdr" do
      check = Doctor.tab_bar(Install.tab_bar_right_snippet(), false)

      assert %Check{status: :warn, fix: "whiska owl install"} = check
      assert check.detail =~ "script"
    end

    test "never a failure: nothing is lost when the line is missing (ADR-0038)" do
      for {config, script?} <- [{nil, false}, {nil, true}, {"[ui]\n", true}] do
        assert %Check{status: status} = Doctor.tab_bar(config, script?)
        assert status in [:ok, :warn]
      end
    end

    test "the tilde form of the path counts: herdr runs the entry through a login shell" do
      whiska_home = Path.join(Whiska.LaunchAgent.user_home(), ".whiska")
      previous = Application.get_env(:whiska, :home)
      Application.put_env(:whiska, :home, whiska_home)
      on_exit(fn -> Application.put_env(:whiska, :home, previous) end)

      config = String.replace(Install.tab_bar_right_snippet(), whiska_home, "~/.whiska")

      assert config =~ ~s(command = "~/.whiska/herdr-status.sh")
      assert %Check{status: :ok} = Doctor.tab_bar(config, true)
    end

    test "an interval the person chose themselves is reported, not argued with" do
      config =
        String.replace(
          Install.tab_bar_right_snippet(),
          "interval_seconds = 5",
          "interval_seconds = 30"
        )

      check = Doctor.tab_bar(config, true)
      assert %Check{status: :ok} = check
      assert check.detail =~ "30"
    end
  end

  # -- shim --------------------------------------------------------------------

  describe "shim/1 — the committed script beside settings.json" do
    test "identical to what init writes is ok" do
      assert %Check{status: :ok} = Doctor.shim(Install.shim())
    end

    test "missing is a fail" do
      assert %Check{status: :fail, fix: "whiska init"} = Doctor.shim(nil)
    end

    test "the old no-argument shim is a fail even though it runs" do
      # The live probe cannot catch this one: the old shim runs pre-tool-use
      # whatever it is told, and pre-tool-use outside a worktree is silent.
      old = String.replace(Install.shim(), ~s(hook "$@"), "hook pre-tool-use")

      assert %Check{status: :fail, detail: detail, fix: "whiska init"} = Doctor.shim(old)
      assert detail =~ "differs"
    end
  end

  # -- doorstep ----------------------------------------------------------------

  describe "doorstep/2" do
    test "nothing waiting is ok" do
      assert %Check{status: :ok, detail: "nothing waiting"} = Doctor.doorstep([], now())
    end

    test "waiting entries warn with the count and the oldest age" do
      now = now()
      entries = [entry(DateTime.add(now, -40 * 60)), entry(DateTime.add(now, -5 * 60))]

      assert %Check{status: :warn, detail: detail, fix: "whiska owl"} =
               Doctor.doorstep(entries, now)

      assert detail =~ "2 waiting"
      assert detail =~ "oldest 40 min"
    end
  end

  # -- backstop ----------------------------------------------------------------

  describe "backstop/2 — did the last resort do the trigger's job (ADR-0036)" do
    test "no mark means the trigger has been doing its job" do
      assert %Check{status: :ok, detail: detail} = Doctor.backstop(nil, now())
      assert detail =~ "nothing"
    end

    test "a mark warns with the count, when, and how to fix the trigger" do
      now = now()

      assert %Check{status: :warn, detail: detail, fix: fix} =
               Doctor.backstop(%{count: 4, last: DateTime.add(now, -12 * 60)}, now)

      assert detail =~ "4"
      assert detail =~ "12 min"
      assert fix =~ "whiska owl stop && whiska owl start"
    end

    test "one collection reads as one, not four" do
      now = now()

      assert %Check{status: :warn, detail: detail} =
               Doctor.backstop(%{count: 1, last: now}, now)

      assert detail =~ "1 entry"
    end
  end

  # -- owl ---------------------------------------------------------------------

  describe "owl/1" do
    test "not running warns and points at whiska owl" do
      assert %Check{status: :warn, fix: "whiska owl"} = Doctor.owl([])
    end

    test "running is ok and names the pid" do
      assert %Check{status: :ok, detail: detail} = Doctor.owl([4242])
      assert detail =~ "4242"
    end
  end

  describe "open_houses/3 — the owl's record, and whether this repo is in it (ADR-0039)" do
    test "this repo open, alone, is ok" do
      assert %Check{status: :ok, detail: detail} =
               Doctor.open_houses(["/r/myrepo"], "/r/myrepo", [4242])

      assert detail =~ "this repo"
    end

    test "this repo open with others is ok and names the others" do
      assert %Check{status: :ok, detail: detail} =
               Doctor.open_houses(["/r/dotfiles", "/r/myrepo", "/r/whiska"], "/r/myrepo", [4242])

      assert detail =~ "dotfiles"
      assert detail =~ "whiska"
      refute detail =~ "myrepo"
    end

    test "this repo missing from the record warns and says how to add it" do
      assert %Check{status: :warn, detail: detail, fix: fix} =
               Doctor.open_houses(["/r/dotfiles"], "/r/myrepo", [4242])

      assert detail =~ "not open"
      assert detail =~ "dotfiles"
      assert fix =~ "whiska owl /r/myrepo"
    end

    test "an empty record warns" do
      assert %Check{status: :warn, fix: "whiska owl"} =
               Doctor.open_houses([], "/r/myrepo", [4242])
    end

    test "with no owl alive the record is shown but not in force" do
      assert %Check{status: :warn, detail: detail, fix: "whiska owl"} =
               Doctor.open_houses(["/r/myrepo", "/r/dotfiles"], "/r/myrepo", [])

      assert detail =~ "2 houses"
      assert detail =~ "none is open"
    end
  end

  # -- mice --------------------------------------------------------------------

  describe "mice/2 — do the records still match the world" do
    setup do
      root =
        Path.join(System.tmp_dir!(), "whiska-doctor-mice-#{System.unique_integer([:positive])}")

      on_exit(fn -> File.rm_rf!(root) end)
      {:ok, root: root}
    end

    defp worktree(root, branch, marker) do
      path = Path.join([root, "worktrees", branch])
      File.mkdir_p!(path)
      if marker, do: File.write!(Path.join(path, ".whiska-mouse"), marker <> "\n")
      path
    end

    defp mouse(id, path, branch, died \\ nil),
      do: %Mouse{mouse_id: id, path: path, branch: branch, died_at: died}

    defp pane(id, cwd), do: %{pane_id: id, cwd: cwd, agent: "claude", agent_status: "working"}

    test "a live mouse with a matching marker and a pane is ok", %{root: root} do
      path = worktree(root, "feat-a", "ma")

      [check] = Doctor.mice([mouse("ma", path, "feat-a")], {:ok, [pane("w1:p1", path)]})

      assert %Check{status: :ok, detail: detail} = check
      assert detail =~ "feat-a"
      assert detail =~ "w1:p1"
    end

    test "a worktree that is gone but not marked dead warns", %{root: root} do
      gone = Path.join([root, "worktrees", "feat-gone"])

      [check] = Doctor.mice([mouse("mg", gone, "feat-gone")], {:ok, []})

      assert %Check{status: :warn, detail: detail} = check
      assert detail =~ "feat-gone"
      assert detail =~ "gone"
    end

    test "a marker that no longer matches the record warns", %{root: root} do
      path = worktree(root, "feat-b", "someone-else")

      [check] = Doctor.mice([mouse("mb", path, "feat-b")], {:ok, [pane("w1:p2", path)]})

      assert %Check{status: :warn, detail: detail} = check
      assert detail =~ "marker"
    end

    test "a worktree with no live pane warns", %{root: root} do
      path = worktree(root, "feat-c", "mc")

      [check] = Doctor.mice([mouse("mc", path, "feat-c")], {:ok, []})

      assert %Check{status: :warn, detail: detail} = check
      assert detail =~ "no live pane"
    end

    test "when herdr cannot be asked, panes are not judged", %{root: root} do
      path = worktree(root, "feat-d", "md")

      [check] = Doctor.mice([mouse("md", path, "feat-d")], :unknown)

      assert %Check{status: :ok, detail: detail} = check
      assert detail =~ "pane not checked"
    end

    test "dead records are left out", %{root: root} do
      gone = Path.join([root, "worktrees", "feat-dead"])

      assert [] = Doctor.mice([mouse("mx", gone, "feat-dead", now())], {:ok, []})
    end
  end

  # -- main session ------------------------------------------------------------

  describe "main_session/2 — where delivery would go" do
    defp claude(status), do: %{pane_id: "w1:p2", cwd: "/x", agent: "claude", agent_status: status}

    test "none recorded warns and says nothing is delivered until it is" do
      assert %Check{status: :warn, detail: detail, fix: fix} = Doctor.main_session(nil, :unknown)
      assert detail =~ "not recorded"
      assert detail =~ "nothing is delivered"
      assert fix =~ "whiska start"
    end

    test "recorded, present and running Claude is ok, with its status" do
      assert %Check{status: :ok, detail: detail} =
               Doctor.main_session("w1:p2", {:ok, claude("idle")})

      assert detail =~ "w1:p2"
      assert detail =~ "idle"
    end

    test "recorded but herdr has no such pane warns, pointing at --force" do
      assert %Check{status: :warn, detail: detail, fix: fix} =
               Doctor.main_session("w1:p2", {:error, %{"code" => "pane_not_found"}})

      assert detail =~ "no such pane"
      assert fix =~ "whiska start --force"
    end

    test "recorded but the pane is not running Claude warns" do
      pane = %{pane_id: "w1:p2", cwd: "/x", agent: nil, agent_status: "unknown"}

      assert %Check{status: :warn, detail: detail, fix: fix} =
               Doctor.main_session("w1:p2", {:ok, pane})

      assert detail =~ "not running Claude"
      assert fix =~ "whiska start --force"
    end

    test "when herdr cannot be asked, the recorded pane is shown but not judged" do
      assert %Check{status: :ok, detail: detail} = Doctor.main_session("w1:p2", :unknown)
      assert detail =~ "w1:p2"
      assert detail =~ "not checked"
    end
  end

  # -- questions ---------------------------------------------------------------

  describe "questions/5 — the queue as a diagnosis, not a listing" do
    test "nothing open and nothing sent is ok" do
      assert %Check{status: :ok, detail: "none waiting"} =
               Doctor.questions(0, nil, true, :empty, now())
    end

    test "open questions with no main session warn — they cannot be delivered" do
      assert %Check{status: :warn, detail: detail, fix: fix} =
               Doctor.questions(2, nil, false, :empty, now())

      assert detail =~ "2 open"
      assert detail =~ "cannot be delivered"
      assert fix =~ "whiska start"
    end

    test "a question held because the person is typing says so (ADR-0047)" do
      assert %Check{status: :ok, detail: detail} = Doctor.questions(2, nil, true, :typing, now())
      assert detail =~ "2 open"
      assert detail =~ "held: person is typing"
    end

    test "nothing open is not held, whatever is in the box" do
      assert %Check{status: :ok, detail: "none waiting"} =
               Doctor.questions(0, nil, true, :typing, now())
    end

    test "a sent question is out already — the box it came from says nothing about it" do
      now = now()
      sent = %Whiska.Schema.Question{id: 7, sent_at: DateTime.add(now, -60)}

      assert %Check{status: :ok, detail: detail} = Doctor.questions(0, sent, true, :typing, now)
      refute detail =~ "held"
    end

    test "open and sent are counted, with how long the sent one has waited" do
      now = now()
      sent = %Whiska.Schema.Question{id: 7, sent_at: DateTime.add(now, -40 * 60)}

      assert %Check{status: :ok, detail: detail} = Doctor.questions(3, sent, true, :empty, now)
      assert detail =~ "3 open"
      assert detail =~ "1 sent (id 7, waiting 40 min)"
    end

    # The bug this check exists for: a mouse died holding the slot, the cascade
    # missed it, and the doctor said "all checks passed" while nothing could be
    # delivered. The cascade is fixed, so this is now a state only an owl that
    # has not reconciled yet can be in — which is exactly when saying so helps.
    test "a sent question whose mouse is dead warns: it is holding the delivery slot" do
      now = now()

      sent = %Whiska.Schema.Question{
        id: 10,
        sent_at: DateTime.add(now, -3 * 3600),
        mouse: %Mouse{mouse_id: "m1", branch: "feat-a", died_at: DateTime.add(now, -3600)}
      }

      assert %Check{status: :warn, detail: detail, fix: fix} =
               Doctor.questions(1, sent, true, :empty, now)

      assert detail =~ "1 open"
      assert detail =~ "1 sent (id 10, waiting 3 h 0 min)"
      assert detail =~ "feat-a is dead"
      assert detail =~ "holding the delivery slot"
      assert fix =~ "whiska owl stop && whiska owl start"
    end
  end

  # -- probe -------------------------------------------------------------------

  describe "probe/3 — running the installed hook for real" do
    setup do
      tmp =
        Path.join(System.tmp_dir!(), "whiska-doctor-probe-#{System.unique_integer([:positive])}")

      repo = Path.join(tmp, "repo")
      File.mkdir_p!(Path.join(repo, ".claude/hooks"))
      File.write!(Path.join(repo, Install.shim_path()), Install.shim())
      File.chmod!(Path.join(repo, Install.shim_path()), 0o755)
      on_exit(fn -> File.rm_rf!(tmp) end)
      {:ok, tmp: tmp, repo: repo}
    end

    defp script(tmp, name, body) do
      path = Path.join(tmp, name)
      File.write!(path, body)
      File.chmod!(path, 0o755)
      path
    end

    defp env(tmp, whiska, escript),
      do: %{
        "WHISKA_BIN" => whiska,
        "WHISKA_ESCRIPT" => escript,
        "PATH" => @stripped_path,
        "HOME" => tmp
      }

    test "a hook that runs silently and exits 0 is ok", %{tmp: tmp, repo: repo} do
      whiska = script(tmp, "whiska", "#!/bin/sh\nexit 0\n")
      escript = script(tmp, "escript", ~s|#!/bin/sh\nexec "$@"\n|)

      assert %Check{status: :ok, name: "hook stop"} =
               Doctor.probe(repo, "stop", env(tmp, whiska, escript))
    end

    test "a binary that does not know the hook is a fail carrying its complaint", %{
      tmp: tmp,
      repo: repo
    } do
      # The installed v0.0.1 binary, exactly: `hook stop` prints usage and exits 1.
      whiska = script(tmp, "whiska", ~s|#!/bin/sh\necho "Usage: whiska <command>" >&2\nexit 1\n|)
      escript = script(tmp, "escript", ~s|#!/bin/sh\nexec "$@"\n|)

      assert %Check{status: :fail, detail: detail, fix: fix} =
               Doctor.probe(repo, "stop", env(tmp, whiska, escript))

      assert detail =~ "Usage"
      assert fix =~ "escript.build"
    end

    test "the shim failing open is a fail, not an ok — the call was allowed by accident", %{
      tmp: tmp,
      repo: repo
    } do
      env = env(tmp, Path.join(tmp, "missing"), "")

      assert %Check{status: :fail, detail: detail} = Doctor.probe(repo, "pre-tool-use", env)
      assert detail =~ "not found"
    end

    test "the probe payload is outside any worktree, so nothing is minted or left behind", %{
      tmp: tmp,
      repo: repo
    } do
      whiska = script(tmp, "whiska", ~s|#!/bin/sh\ncat > "#{tmp}/payload"\nexit 0\n|)
      escript = script(tmp, "escript", ~s|#!/bin/sh\nexec "$@"\n|)

      Doctor.probe(repo, "stop", env(tmp, whiska, escript))

      %{"cwd" => cwd} = File.read!(Path.join(tmp, "payload")) |> JSON.decode!()
      refute cwd =~ "/worktrees/"
      refute File.exists?(Path.join(repo, ".git/whiska/doorstep"))
    end
  end

  # -- run ---------------------------------------------------------------------

  describe "run/2 — everything, on one repo" do
    setup do
      root =
        Path.join(System.tmp_dir!(), "whiska-doctor-run-#{System.unique_integer([:positive])}")

      main = Path.join(root, "myrepo")
      File.mkdir_p!(Path.join(main, ".git"))
      on_exit(fn -> File.rm_rf!(root) end)

      whiska = script(root, "whiska", "#!/bin/sh\nexit 0\n")
      escript = script(root, "escript", ~s|#!/bin/sh\nexec "$@"\n|)

      env = %{
        "WHISKA_BIN" => whiska,
        "WHISKA_ESCRIPT" => escript,
        "PATH" => @stripped_path,
        "HOME" => root,
        "HERDR_SOCKET_PATH" => Path.join(root, "herdr.sock")
      }

      {:ok, root: root, main: main, env: env}
    end

    defp init(main) do
      File.mkdir_p!(Path.join(main, ".claude/hooks"))
      File.write!(Path.join(main, ".claude/settings.json"), JSON.encode!(Install.merge(%{})))
      File.write!(Path.join(main, Install.shim_path()), Install.shim())
      File.chmod!(Path.join(main, Install.shim_path()), 0o755)
    end

    test "a repo that was never initialised fails on the hooks and the shim", %{
      main: main,
      env: env
    } do
      stub(Herdr, :list_panes, fn _ -> {:error, :econnrefused} end)

      report = Doctor.run(main, env: env, owl_pids: fn -> [] end)

      assert report.repo == main
      assert %Check{status: :fail} = find(report.checks, "PreToolUse")
      assert %Check{status: :fail} = find(report.checks, "Stop")
      assert %Check{status: :fail} = find(report.checks, "shim")
      # No shim means nothing to probe; the probe must not pretend.
      refute find(report.checks, "hook stop")
    end

    test "a script an older init wrote is reported from the repo itself (ADR-0059)", %{
      main: main,
      env: env
    } do
      init(main)
      stub(Herdr, :list_panes, fn _ -> {:error, :econnrefused} end)

      File.write!(
        Path.join(main, Install.statusline_path()),
        "#!/usr/bin/env bash\n# an older init wrote this\nexit 0\n"
      )

      report = Doctor.run(main, env: env, owl_pids: fn -> [] end)

      assert %Check{status: :warn, fix: "whiska init"} =
               find(report.checks, "statusline script")
    end

    test "a repo with no copy of the script says nothing about one", %{main: main, env: env} do
      init(main)
      stub(Herdr, :list_panes, fn _ -> {:error, :econnrefused} end)

      report = Doctor.run(main, env: env, owl_pids: fn -> [] end)

      refute find(report.checks, "statusline script")
    end

    test "an initialised repo with everything reachable is all ok, owl aside", %{
      main: main,
      env: env,
      root: root
    } do
      init(main)
      File.touch!(Path.join(root, "herdr.sock"))
      stub(Herdr, :list_panes, fn _ -> {:ok, []} end)

      report = Doctor.run(main, env: env, owl_pids: fn -> [] end)

      for name <-
            ~w(binary runtime herdr PreToolUse Stop shim house doorstep backstop) ++
              ["hook pre-tool-use", "hook stop"] do
        assert %Check{status: :ok} = find(report.checks, name), "expected #{name} to be ok"
      end

      assert %Check{status: :warn} = find(report.checks, "owl")
      assert %Check{status: :warn} = find(report.checks, "open houses")
    end

    test "the open-houses record is read from the path given, right after the owl", %{
      main: main,
      env: env,
      root: root
    } do
      init(main)
      stub(Herdr, :list_panes, fn _ -> {:ok, []} end)
      record = Path.join(root, "dot-whiska/houses")
      Whiska.OpenHouses.add(main, record)

      report =
        Doctor.run(main, env: env, owl_pids: fn -> [4242] end, open_houses: record)

      assert %Check{status: :ok} = find(report.checks, "open houses")
      names = Enum.map(report.checks, & &1.name)

      # owl, then its launch agent (ADR-0040), then what it has open.
      assert Enum.find_index(names, &(&1 == "open houses")) ==
               Enum.find_index(names, &(&1 == "owl")) + 2
    end

    test "a backstop mark in the house shows up as a warning", %{main: main, env: env} do
      init(main)
      stub(Herdr, :list_panes, fn _ -> {:ok, []} end)
      :ok = Whiska.Backstop.record(main, 3, now())

      report = Doctor.run(main, env: env, owl_pids: fn -> [4242] end)

      assert %Check{status: :warn, detail: detail} = find(report.checks, "backstop")
      assert detail =~ "3"
    end

    test "no backstop mark is an ok line of its own", %{main: main, env: env} do
      init(main)
      stub(Herdr, :list_panes, fn _ -> {:ok, []} end)

      report = Doctor.run(main, env: env, owl_pids: fn -> [4242] end)

      assert %Check{status: :ok} = find(report.checks, "backstop")
    end

    test "the house is opened and reported with its schema version, then closed", %{
      main: main,
      env: env
    } do
      init(main)
      stub(Herdr, :list_panes, fn _ -> {:ok, []} end)

      report = Doctor.run(main, env: env, owl_pids: fn -> [] end)

      assert %Check{status: :ok, detail: detail} = find(report.checks, "house")
      assert detail =~ "schema v#{Storage.latest_schema_version()}"
      assert File.exists?(Storage.database_path(main))
      refute Process.whereis(Whiska.Repo)
    end

    test "waiting doorstep entries and mismatched mice show up", %{main: main, env: env} do
      init(main)
      gone = Path.join(main, "worktrees/feat-gone")
      {:ok, handle} = Storage.open(main, name: :seed)
      {:ok, _} = Storage.record_mouse(%{mouse_id: "mg", path: gone, branch: "feat-gone"})
      Storage.close(handle)
      {:ok, _} = Doorstep.leave(main, entry(now(), "mg", gone))
      stub(Herdr, :list_panes, fn _ -> {:ok, []} end)

      report = Doctor.run(main, env: env, owl_pids: fn -> [] end)

      assert %Check{status: :warn, detail: detail} = find(report.checks, "doorstep")
      assert detail =~ "1 waiting"
      assert [%Check{status: :warn}] = Enum.filter(report.checks, &(&1.name == "mice"))
    end

    test "a recorded main session is checked against herdr's fresh word on that pane", %{
      main: main,
      env: env,
      root: root
    } do
      init(main)
      File.touch!(Path.join(root, "herdr.sock"))
      {:ok, handle} = Storage.open(main, name: :seed)
      :ok = Storage.set_main_pane("w1:p2")
      Storage.close(handle)
      stub(Herdr, :list_panes, fn _ -> {:ok, []} end)
      stub(Herdr, :pane, fn _, "w1:p2" -> {:ok, claude("working")} end)

      report = Doctor.run(main, env: env, owl_pids: fn -> [] end)

      assert %Check{status: :ok, detail: detail} = find(report.checks, "main session")
      assert detail =~ "w1:p2"
      assert detail =~ "working"
      assert %Check{status: :ok} = find(report.checks, "questions")
    end

    test "an open question held because the person is typing says so on the questions line", %{
      main: main,
      env: env,
      root: root
    } do
      init(main)
      File.touch!(Path.join(root, "herdr.sock"))
      {:ok, handle} = Storage.open(main, name: :seed)
      :ok = Storage.set_main_pane("w1:p2")
      {:ok, _} = Storage.record_mouse(%{mouse_id: "m1", path: Path.join(main, "wt"), branch: "b"})
      {:ok, _} = Storage.record_question(%{mouse_id: "m1", kind: "needs-decision", text: "?"})
      Storage.close(handle)

      stub(Herdr, :list_panes, fn _ -> {:ok, []} end)
      stub(Herdr, :pane, fn _, "w1:p2" -> {:ok, claude("idle")} end)

      stub(Herdr, :read_screen, fn _, "w1:p2" ->
        {:ok, "──────\n❯\u00a0half a thought\n──────\n"}
      end)

      report = Doctor.run(main, env: env, owl_pids: fn -> [] end)

      assert %Check{status: :ok, detail: detail} = find(report.checks, "questions")
      assert detail =~ "1 open"
      assert detail =~ "held: person is typing"
    end

    test "with no main session and questions open, both lines warn", %{main: main, env: env} do
      init(main)
      {:ok, handle} = Storage.open(main, name: :seed)

      {:ok, _} =
        Storage.record_mouse(%{mouse_id: "m1", path: Path.join(main, "worktrees/a"), branch: "a"})

      {:ok, _} =
        Storage.record_question(%{
          mouse_id: "m1",
          text: "?",
          kind: "needs-decision",
          status: "open",
          asked_at: now()
        })

      Storage.close(handle)
      stub(Herdr, :list_panes, fn _ -> {:ok, []} end)

      report = Doctor.run(main, env: env, owl_pids: fn -> [] end)

      assert %Check{status: :warn} = find(report.checks, "main session")
      assert %Check{status: :warn, detail: detail} = find(report.checks, "questions")
      assert detail =~ "1 open"
    end

    test "a binary that cannot be found fails, and the probes are skipped", %{
      main: main,
      env: env,
      root: root
    } do
      init(main)
      stub(Herdr, :list_panes, fn _ -> {:ok, []} end)
      env = %{env | "WHISKA_BIN" => Path.join(root, "nope")}

      report = Doctor.run(main, env: env, owl_pids: fn -> [] end)

      assert %Check{status: :fail} = find(report.checks, "binary")
      refute find(report.checks, "hook stop")
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp entry(stamped_at, mouse_id \\ "m", root \\ "/nowhere/worktrees/x") do
    %Entry{
      mouse_id: mouse_id,
      branch: Path.basename(root),
      worktree_root: root,
      stamped_at: stamped_at,
      text: "hi"
    }
  end
end
