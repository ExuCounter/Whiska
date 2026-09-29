defmodule Whiska.CLILaunchAgentTest do
  @moduledoc """
  `whiska owl install|uninstall|stop|start`, the foreground owl's refusal to
  run beside the supervised one, and the `whiska stop` stub. The home,
  the launchctl runner and the owl probe are all injected through the
  application environment, so nothing here touches the real LaunchAgents.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import Mox

  alias Whiska.CLI
  alias Whiska.Herdr.Mock, as: Herdr
  alias Whiska.LaunchAgent

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    home =
      Path.join(System.tmp_dir!(), "whiska-cli-launchd-#{System.unique_integer([:positive])}")

    main = Path.join(home, "myrepo")
    File.mkdir_p!(Path.join(main, ".git"))

    # The test config already points every home and the launchctl runner
    # away from the real machine; this narrows them to one temp dir per test.
    previous = Application.get_all_env(:whiska)
    Application.put_env(:whiska, :user_home, home)
    Application.put_env(:whiska, :home, Path.join(home, ".whiska"))
    Application.put_env(:whiska, :uid, 501)
    Application.put_env(:whiska, :owl_pids, fn -> [] end)

    on_exit(fn ->
      for key <- [:user_home, :home, :uid, :owl_pids, :launchctl, :env],
          do: Application.delete_env(:whiska, key)

      for {k, v} <- previous, do: Application.put_env(:whiska, k, v)
      File.rm_rf!(home)
    end)

    {:ok, home: home, main: main, paths: LaunchAgent.paths(home, Path.join(home, ".whiska"))}
  end

  # launchctl as a recorder: `status` says what `print` should answer.
  defp launchctl(status) do
    me = self()

    print =
      case status do
        :not_loaded ->
          {"Could not find service\n", 113}

        :stopped ->
          {"gui/501/com.whiska.owl = {\n\tstate = not running\n}\n", 0}

        {:running, pid} ->
          {"gui/501/com.whiska.owl = {\n\tstate = running\n\tpid = #{pid}\n}\n", 0}
      end

    Application.put_env(:whiska, :launchctl, fn
      ["print" | _] = args ->
        send(me, {:launchctl, args})
        print

      args ->
        send(me, {:launchctl, args})
        {"", 0}
    end)
  end

  defp owls(pids), do: Application.put_env(:whiska, :owl_pids, fn -> pids end)

  defp run(argv, cwd \\ nil, env \\ nil) do
    holder = self()
    if env, do: Application.put_env(:whiska, :env, env)

    out =
      capture_io(fn ->
        err = capture_io(:stderr, fn -> send(holder, {:code, CLI.run(argv, cwd)}) end)
        send(holder, {:err, err})
      end)

    code = receive do: ({:code, code} -> code)
    err = receive do: ({:err, err} -> err)
    {code, out, err}
  end

  describe "whiska owl install" do
    test "writes the files and bootstraps the agent", %{paths: paths} do
      launchctl(:not_loaded)

      {code, out, _err} = run(["owl", "install"])

      assert code == 0
      assert File.exists?(paths.plist)
      assert File.exists?(paths.wrapper)
      assert_received {:launchctl, ["bootstrap", "gui/501", _plist]}
      assert out =~ "com.whiska.owl"
      assert out =~ paths.log
      assert out =~ "whiska owl stop"
    end

    test "writes the script herdr's tab bar runs, and prints the entry to paste (ADR-0048)" do
      launchctl(:not_loaded)

      {0, out, _err} = run(["owl", "install"])

      script = Whiska.Install.herdr_status_path()
      assert File.read!(script) == Whiska.Install.herdr_status_script()
      assert Bitwise.band(File.stat!(script).mode, 0o100) != 0
      assert out =~ "tab_bar_right"
      assert out =~ script
    end

    test "says when herdr's socket was not in the environment to copy" do
      launchctl(:not_loaded)
      {0, _out, err} = run(["owl", "install"], nil, %{"HOME" => "/h"})
      assert err =~ "HERDR_SOCKET_PATH"
      assert err =~ ".config/herdr/herdr.sock"
    end

    test "refuses while a foreground owl runs, and explains the handover", %{paths: paths} do
      launchctl(:not_loaded)
      owls([4242])

      {code, _out, err} = run(["owl", "install"])

      assert code == 1
      assert err =~ "4242"
      assert err =~ "Ctrl-C"
      assert err =~ "whiska owl install"
      refute File.exists?(paths.plist)
      refute_received {:launchctl, ["bootstrap" | _]}
    end

    test "refuses while the supervised owl runs, pointing at whiska owl stop" do
      launchctl({:running, 777})
      owls([777])

      {code, _out, err} = run(["owl", "install"])

      assert code == 1
      assert err =~ "whiska owl stop"
      refute err =~ "Ctrl-C"
    end

    test "reinstalls over a loaded-but-stopped agent by booting it out first", %{paths: paths} do
      launchctl(:stopped)
      :ok = LaunchAgent.install(paths, %{})

      {0, _out, _err} = run(["owl", "install"])

      assert_received {:launchctl, ["bootout", "gui/501/com.whiska.owl"]}
      assert_received {:launchctl, ["bootstrap", "gui/501", _]}
    end
  end

  describe "whiska owl uninstall" do
    test "boots the agent out and removes the files", %{paths: paths} do
      launchctl(:stopped)
      :ok = LaunchAgent.install(paths, %{})

      {code, out, _err} = run(["owl", "uninstall"])

      assert code == 0
      assert_received {:launchctl, ["bootout", "gui/501/com.whiska.owl"]}
      refute File.exists?(paths.plist)
      refute File.exists?(paths.wrapper)
      assert out =~ "whiska owl install"
    end

    test "when nothing is installed, says so and exits 0" do
      launchctl(:not_loaded)
      {0, out, _err} = run(["owl", "uninstall"])
      assert out =~ "not installed"
      refute_received {:launchctl, ["bootout" | _]}
    end
  end

  describe "whiska owl stop" do
    test "sends TERM to the supervised owl" do
      launchctl({:running, 777})
      {0, out, _err} = run(["owl", "stop"])
      assert_received {:launchctl, ["kill", "TERM", "gui/501/com.whiska.owl"]}
      assert out =~ "777"
      assert out =~ "whiska owl start"
    end

    test "when the agent is loaded but the owl is not running, says so" do
      launchctl(:stopped)
      {0, out, _err} = run(["owl", "stop"])
      assert out =~ "not running"
      refute_received {:launchctl, ["kill" | _]}
    end

    test "with no agent, points at the foreground owl" do
      launchctl(:not_loaded)
      owls([4242])
      {1, _out, err} = run(["owl", "stop"])
      assert err =~ "not installed"
      assert err =~ "4242"
      assert err =~ "Ctrl-C"
    end
  end

  describe "whiska owl start" do
    test "kickstarts the loaded agent" do
      launchctl(:stopped)
      {0, out, _err} = run(["owl", "start"])
      assert_received {:launchctl, ["kickstart", "gui/501/com.whiska.owl"]}
      assert out =~ "com.whiska.owl"
    end

    test "with no agent installed, points at install" do
      launchctl(:not_loaded)
      {1, _out, err} = run(["owl", "start"])
      assert err =~ "whiska owl install"
    end
  end

  describe "whiska owl (foreground)" do
    setup do
      stub(Herdr, :list_panes, fn _ -> {:ok, []} end)

      stub(Herdr, :subscribe, fn _, _, _ -> {:ok, spawn(fn -> receive do: (:stop -> :ok) end)} end)

      on_exit(fn -> CLI.stop_owl() end)
      :ok
    end

    test "refuses while the supervised owl is running", %{main: main} do
      launchctl({:running, 777})
      owls([777])

      err = capture_io(:stderr, fn -> assert {:error, :supervised} = CLI.start_owl([], main) end)
      assert err =~ "777"
      assert err =~ "whiska owl stop"
    end

    test "outside a repo with nothing recorded, opens no house and keeps running", %{home: home} do
      launchctl(:not_loaded)
      elsewhere = Path.join(home, "plain")
      File.mkdir_p!(elsewhere)

      err = capture_io(:stderr, fn -> assert {:ok, _} = CLI.start_owl([], elsewhere) end)

      assert Whiska.Owl.open_houses() == []
      assert err =~ "no house"
      assert err =~ "whiska owl <repo>"
    end

    test "a repo named explicitly is still refused when it is not one", %{home: home} do
      launchctl(:not_loaded)
      elsewhere = Path.join(home, "plain")
      File.mkdir_p!(elsewhere)

      err = capture_io(:stderr, fn -> assert {:error, _} = CLI.start_owl([elsewhere]) end)
      assert err =~ "not a git checkout"
    end
  end

  describe "whiska stop" do
    test "is the per-house shutdown, and says it is not built" do
      {1, _out, err} = run(["stop"])
      assert err =~ "ADR-0003"
      assert err =~ "whiska owl stop"
    end
  end

  test "help lists the owl's launchd commands" do
    out = capture_io(fn -> CLI.run(["--help"]) end)
    assert out =~ "owl install"
    assert out =~ "owl uninstall"
    assert out =~ "owl stop"
    assert out =~ "owl start"
  end
end
