defmodule Whiska.SystemdUnitTest do
  @moduledoc """
  The owl's systemd unit as pure values and as files under a temp home.
  Nothing here touches ~/.config/systemd or runs systemctl for real: the
  calls are captured through an injected runner.
  """
  # Serial: the runner is the global `:systemd` setting.
  use ExUnit.Case, async: false

  alias Whiska.ServiceManager
  alias Whiska.SystemdUnit

  setup do
    home = Path.join(System.tmp_dir!(), "whiska-systemd-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    previous = Application.get_env(:whiska, :systemd)
    Application.put_env(:whiska, :uid, 1000)

    on_exit(fn ->
      Application.put_env(:whiska, :systemd, previous)
      Application.delete_env(:whiska, :uid)
      File.rm_rf!(home)
    end)

    {:ok, home: home, paths: SystemdUnit.paths(home, Path.join(home, ".whiska"))}
  end

  # A runner that records each command line and answers `reply` for it.
  defp systemd(reply \\ fn _argv -> {"", 0} end) do
    me = self()

    Application.put_env(:whiska, :systemd, fn argv ->
      send(me, {:systemd, argv})
      reply.(argv)
    end)
  end

  # Every command line the runner has received so far, in the order it ran.
  defp recorded(acc \\ []) do
    receive do
      {:systemd, argv} -> recorded([argv | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "paths/2" do
    test "the unit under the user's systemd directory, the rest in the whiska home", %{
      home: home
    } do
      paths = SystemdUnit.paths(home, "/w")

      assert SystemdUnit.label() == "whiska-owl.service"
      assert paths.job == Path.join(home, ".config/systemd/user/whiska-owl.service")
      assert paths.wrapper == "/w/owl.sh"
      assert paths.log == "/w/owl.log"
    end
  end

  describe "unit/2" do
    test "runs the wrapper, starts at login, restarts only a crash, logs where launchd does",
         %{paths: paths} do
      unit = SystemdUnit.unit(paths, %{})

      # The wrapper itself, through its own `#!/usr/bin/env bash`: NixOS and Guix
      # run systemd with no /bin/bash.
      assert unit =~ ~s(ExecStart="#{paths.wrapper}"\n)
      refute unit =~ "/bin/bash"
      assert unit =~ "Restart=on-failure\n"
      assert unit =~ "RestartSec=10\n"
      assert unit =~ "StandardOutput=append:#{paths.log}\n"
      assert unit =~ "StandardError=append:#{paths.log}\n"
      assert unit =~ "[Install]\nWantedBy=default.target\n"
      refute unit =~ ~r/\bescript\b/
      refute unit =~ "Environment="
    end

    test "copies herdr's socket and the whiska overrides from the installing shell", %{
      paths: paths
    } do
      env = %{
        "HERDR_SOCKET_PATH" => "/tmp/h.sock",
        "WHISKA_BIN" => "/opt/whiska",
        "PATH" => "/usr/bin",
        "SECRET" => "no"
      }

      unit = SystemdUnit.unit(paths, env)

      assert unit =~ ~s(Environment="HERDR_SOCKET_PATH=/tmp/h.sock"\n)
      assert unit =~ ~s(Environment="WHISKA_BIN=/opt/whiska"\n)
      refute unit =~ "SECRET"
      refute unit =~ "PATH=/usr/bin"
    end

    test "quotes what systemd would otherwise read as a split, a specifier or a variable",
         %{home: home} do
      paths = SystemdUnit.paths(home, "/a b/100%/$x")
      unit = SystemdUnit.unit(paths, %{"HERDR_SOCKET_PATH" => "/s\"q\\"})

      assert unit =~ ~s(ExecStart="/a b/100%%/$$x/owl.sh"\n)
      assert unit =~ "StandardOutput=append:/a b/100%%/$x/owl.log\n"
      assert unit =~ ~S(Environment="HERDR_SOCKET_PATH=/s\"q\\") <> "\n"
    end

    @tag :systemd
    test "is a unit systemd accepts, running the wrapper install wrote", %{
      home: home,
      paths: paths
    } do
      :ok = SystemdUnit.install(paths, %{"HERDR_SOCKET_PATH" => "/tmp/h.sock"})
      # A user manager's runtime directory, which a session without one lacks.
      runtime = Path.join(home, "runtime")
      File.mkdir_p!(runtime)
      File.chmod!(runtime, 0o700)

      assert {out, 0} =
               System.cmd("systemd-analyze", ["verify", "--user", paths.job],
                 stderr_to_stdout: true,
                 env: [{"XDG_RUNTIME_DIR", runtime}]
               )

      refute out =~ "whiska-owl.service:"
    end
  end

  describe "install/2 refuses what would end a line of the unit" do
    # systemd ends a line at a newline, a carriage return or a NUL, and reads
    # `append:` paths with no unescaping, so no quoting can carry one.
    test "in a value from the installing shell", %{paths: paths} do
      for bad <- ["/s\nExecStartPre=/bin/evil", "/s\rExecStartPre=/bin/evil", "/s\0x"] do
        assert {:error, {:control_character, "HERDR_SOCKET_PATH"}} =
                 SystemdUnit.install(paths, %{"HERDR_SOCKET_PATH" => bad})

        refute File.exists?(paths.job)
      end
    end

    test "in the whiska home the wrapper and the log live in", %{home: home} do
      paths = SystemdUnit.paths(home, "/x\nExecStartPre=/bin/evil")

      assert {:error, {:control_character, "the whiska home"}} = SystemdUnit.install(paths, %{})
      refute File.exists?(paths.job)
    end
  end

  describe "install/2 and uninstall/1" do
    test "writes the wrapper (executable) and the unit", %{paths: paths} do
      assert :ok = SystemdUnit.install(paths, %{})

      assert File.read!(paths.job) == SystemdUnit.unit(paths, %{})
      assert File.read!(paths.wrapper) == ServiceManager.wrapper()
      assert {:ok, %File.Stat{mode: mode}} = File.stat(paths.wrapper)
      assert Bitwise.band(mode, 0o100) != 0
      assert SystemdUnit.installed?(paths)
    end

    test "uninstall removes both, keeps the log, and has systemd forget the unit", %{
      paths: paths
    } do
      systemd()
      :ok = SystemdUnit.install(paths, %{})
      File.write!(paths.log, "kept\n")

      assert :ok = SystemdUnit.uninstall(paths)
      refute File.exists?(paths.job)
      refute File.exists?(paths.wrapper)
      assert File.read!(paths.log) == "kept\n"
      assert_received {:systemd, ["systemctl", "--user", "daemon-reload"]}
    end

    test "uninstall of nothing says so", %{paths: paths} do
      assert {:error, :not_installed} = SystemdUnit.uninstall(paths)
    end
  end

  describe "systemctl" do
    test "load reads the unit afresh, then enables it for every login and starts it", %{
      paths: paths
    } do
      systemd()

      assert :ok = SystemdUnit.load(paths, %{loaded: true, pid: nil, last_exit_code: 0})

      assert recorded() == [
               ["systemctl", "--user", "daemon-reload"],
               ["systemctl", "--user", "enable", "--now", "whiska-owl.service"]
             ]
    end

    test "unload, stop and start name the unit" do
      systemd()

      assert :ok = SystemdUnit.unload()

      assert_received {:systemd,
                       ["systemctl", "--user", "disable", "--now", "whiska-owl.service"]}

      assert :ok = SystemdUnit.stop()
      assert_received {:systemd, ["systemctl", "--user", "stop", "whiska-owl.service"]}

      assert :ok = SystemdUnit.start()
      assert_received {:systemd, ["systemctl", "--user", "start", "whiska-owl.service"]}
    end

    test "a failing systemctl is reported with its output" do
      systemd(fn _ -> {"Failed to start whiska-owl.service: Unit not found.\n", 5} end)
      assert {:error, "Failed to start whiska-owl.service: Unit not found."} = SystemdUnit.start()
    end

    test "ready when this user's systemd answers" do
      systemd()
      assert :ok = SystemdUnit.ready()
      assert_received {:systemd, ["systemctl", "--user", "show-environment"]}
    end

    test "not ready where there is no systemd for this user, and says why" do
      systemd(fn _ -> {"Failed to connect to bus: No medium found\n", 1} end)
      assert {:error, reason} = SystemdUnit.ready()
      assert reason =~ "systemd is not running for this user"
      assert reason =~ "No medium found"
    end

    test "not ready where systemctl is not installed at all" do
      Application.put_env(:whiska, :systemd, fn [_program | args] ->
        System.cmd("whiska-test-no-such-systemctl", args)
      end)

      assert {:error, _} = SystemdUnit.ready()
    end
  end

  describe "status/0" do
    test "a unit that is not installed is not loaded" do
      systemd(fn _ -> {"MainPID=0\nUnitFileState=\nExecMainStatus=0\n", 0} end)

      assert %{loaded: false, pid: nil} = SystemdUnit.status()

      assert_received {:systemd,
                       [
                         "systemctl",
                         "--user",
                         "show",
                         "whiska-owl.service",
                         "--property=UnitFileState,MainPID,ExecMainStatus"
                       ]}
    end

    test "enabled and running carries the pid" do
      systemd(fn _ -> {"MainPID=4242\nUnitFileState=enabled\nExecMainStatus=0\n", 0} end)
      assert %{loaded: true, pid: 4242} = SystemdUnit.status()
    end

    test "enabled and crash-looping carries the last exit status" do
      systemd(fn _ -> {"MainPID=0\nUnitFileState=enabled\nExecMainStatus=1\n", 0} end)
      assert %{loaded: true, pid: nil, last_exit_code: 1} = SystemdUnit.status()
    end

    test "written but disabled is not loaded" do
      systemd(fn _ -> {"MainPID=0\nUnitFileState=disabled\nExecMainStatus=0\n", 0} end)
      assert %{loaded: false} = SystemdUnit.status()
    end

    test "no systemd to ask, or no systemctl at all, is not loaded" do
      systemd(fn _ -> {"Failed to connect to bus\n", 1} end)
      assert %{loaded: false, pid: nil} = SystemdUnit.status()

      Application.put_env(:whiska, :systemd, fn [_program | args] ->
        System.cmd("whiska-test-no-such-systemctl", args)
      end)

      assert %{loaded: false, pid: nil} = SystemdUnit.status()
    end
  end

  describe "linger/0" do
    test "asks logind about this user" do
      systemd(fn _ -> {"yes\n", 0} end)
      assert SystemdUnit.linger()

      assert_received {:systemd,
                       ["loginctl", "show-user", "1000", "--property=Linger", "--value"]}
    end

    test "off, or unknown, is not lingering" do
      systemd(fn _ -> {"no\n", 0} end)
      refute SystemdUnit.linger()

      systemd(fn _ -> {"Failed to get user: User ID 1000 is not logged in or lingering\n", 1} end)
      refute SystemdUnit.linger()
    end
  end
end
