defmodule Whiska.CLISystemdTest do
  @moduledoc """
  `whiska owl install|uninstall|stop|start` and the foreground owl on Linux,
  where systemd keeps the owl running. The home, the systemd runner and the
  owl probe are all injected through the application environment, so nothing
  here touches the real systemd.
  """
  # Serial: each test points the global `:home`, `:user_home`, `:uid`,
  # `:owl_pids`, `:service_manager` and `:systemd` settings at its own.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import Mox

  alias Whiska.CLI
  alias Whiska.Herdr.Mock, as: Herdr
  alias Whiska.SystemdUnit

  setup :verify_on_exit!

  setup do
    home =
      Path.join(System.tmp_dir!(), "whiska-cli-systemd-#{System.unique_integer([:positive])}")

    main = Path.join(home, "myrepo")
    File.mkdir_p!(Path.join(main, ".git"))

    keys = [:user_home, :home, :uid, :owl_pids, :service_manager, :systemd, :env]
    previous = for key <- keys, do: {key, Application.fetch_env(:whiska, key)}

    Application.put_env(:whiska, :user_home, home)
    Application.put_env(:whiska, :home, Path.join(home, ".whiska"))
    Application.put_env(:whiska, :uid, 1000)
    Application.put_env(:whiska, :owl_pids, fn -> [] end)
    Application.put_env(:whiska, :service_manager, SystemdUnit)

    on_exit(fn ->
      for {key, value} <- previous do
        case value do
          {:ok, v} -> Application.put_env(:whiska, key, v)
          :error -> Application.delete_env(:whiska, key)
        end
      end

      File.rm_rf!(home)
    end)

    {:ok, home: home, main: main, paths: SystemdUnit.paths(home, Path.join(home, ".whiska"))}
  end

  # systemd as a recorder. `unit` is what `systemctl --user show` reports,
  # `ready` whether this user's systemd answers, `linger` what logind says.
  defp systemd(unit, opts \\ []) do
    me = self()
    ready = Keyword.get(opts, :ready, true)
    linger = Keyword.get(opts, :linger, false)

    show =
      case unit do
        :not_installed -> "UnitFileState=\nMainPID=0\nExecMainStatus=0\n"
        :stopped -> "UnitFileState=enabled\nMainPID=0\nExecMainStatus=0\n"
        {:running, pid} -> "UnitFileState=enabled\nMainPID=#{pid}\nExecMainStatus=0\n"
      end

    Application.put_env(:whiska, :systemd, fn argv ->
      send(me, {:systemd, argv})

      case argv do
        ["systemctl", "--user", "show-environment"] ->
          if ready, do: {"PATH=/usr/bin\n", 0}, else: {"Failed to connect to bus\n", 1}

        ["systemctl", "--user", "show" | _] ->
          {show, 0}

        ["loginctl" | _] ->
          {if(linger, do: "yes\n", else: "no\n"), 0}

        _ ->
          {"", 0}
      end
    end)
  end

  defp owls(pids), do: Application.put_env(:whiska, :owl_pids, fn -> pids end)

  defp run(argv) do
    holder = self()

    out =
      capture_io(fn ->
        err = capture_io(:stderr, fn -> send(holder, {:code, CLI.run(argv, nil)}) end)
        send(holder, {:err, err})
      end)

    code = receive do: ({:code, code} -> code)
    err = receive do: ({:err, err} -> err)
    {code, out, err}
  end

  describe "whiska owl install" do
    test "writes the unit, enables it for every login and starts it", %{paths: paths} do
      systemd(:not_installed)

      {code, out, _err} = run(["owl", "install"])

      assert code == 0
      assert File.read!(paths.job) =~ ~s(ExecStart="#{paths.wrapper}")
      assert File.exists?(paths.wrapper)
      assert_received {:systemd, ["systemctl", "--user", "daemon-reload"]}
      assert_received {:systemd, ["systemctl", "--user", "enable", "--now", "whiska-owl.service"]}
      assert out =~ "whiska-owl.service"
      assert out =~ "under systemd"
      assert out =~ paths.job
      assert out =~ paths.log
    end

    test "says how to keep the owl past a logout, without turning lingering on" do
      systemd(:not_installed, linger: false)

      {0, out, _err} = run(["owl", "install"])

      assert out =~ "loginctl enable-linger"
      refute_received {:systemd, ["loginctl", "enable-linger" | _]}
    end

    test "says nothing about logout when lingering is already on" do
      systemd(:not_installed, linger: true)
      {0, out, _err} = run(["owl", "install"])
      refute out =~ "enable-linger"
    end

    test "where this user has no systemd, refuses and points at the foreground owl", %{
      paths: paths
    } do
      systemd(:not_installed, ready: false)

      {code, _out, err} = run(["owl", "install"])

      assert code == 1
      assert err =~ "systemd is not running for this user"
      assert err =~ "`whiska owl`"
      refute File.exists?(paths.job)
      refute_received {:systemd, ["systemctl", "--user", "enable" | _]}
    end

    test "refuses while systemd's owl runs, pointing at whiska owl stop" do
      systemd({:running, 777})
      owls([777])

      {1, _out, err} = run(["owl", "install"])

      assert err =~ "under systemd (pid 777)"
      assert err =~ "whiska owl stop"
    end
  end

  describe "whiska owl uninstall" do
    test "disables and stops the unit, then removes the files", %{paths: paths} do
      systemd(:stopped)
      :ok = SystemdUnit.install(paths, %{})

      {0, out, _err} = run(["owl", "uninstall"])

      assert_received {:systemd,
                       ["systemctl", "--user", "disable", "--now", "whiska-owl.service"]}

      refute File.exists?(paths.job)
      refute File.exists?(paths.wrapper)
      assert out =~ "whiska owl install"
    end
  end

  describe "whiska owl stop and start" do
    test "stop asks systemd to stop the running owl" do
      systemd({:running, 777})
      {0, out, _err} = run(["owl", "stop"])
      assert_received {:systemd, ["systemctl", "--user", "stop", "whiska-owl.service"]}
      assert out =~ "777"
      # With lingering on, systemd's user session outlives every login, so
      # nothing brings a stopped owl back at the next one.
      assert out =~ "systemd starts it again when it next starts your user session"
      refute out =~ "next login"
    end

    test "start asks systemd to start the stopped owl" do
      systemd(:stopped)
      {0, out, _err} = run(["owl", "start"])
      assert_received {:systemd, ["systemctl", "--user", "start", "whiska-owl.service"]}
      assert out =~ "under systemd"
    end

    test "with no unit installed, start points at install" do
      systemd(:not_installed)
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

    test "starts where systemctl is not installed", %{main: main} do
      Application.put_env(:whiska, :systemd, fn [_program | args] ->
        System.cmd("whiska-test-no-such-systemctl", args, stderr_to_stdout: true)
      end)

      capture_io(:stderr, fn -> assert {:ok, _} = CLI.start_owl([], main) end)
    end

    test "refuses while systemd's owl is running", %{main: main} do
      systemd({:running, 777})
      owls([777])

      err = capture_io(:stderr, fn -> assert {:error, :supervised} = CLI.start_owl([], main) end)
      assert err =~ "under systemd (pid 777)"
    end
  end
end
