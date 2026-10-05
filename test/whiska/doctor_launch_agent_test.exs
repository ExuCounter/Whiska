defmodule Whiska.DoctorLaunchAgentTest do
  @moduledoc """
  The doctor's line for the job that keeps the owl running — `launch agent` on
  macOS, `systemd unit` on Linux: installed, loaded, running, and the fix for
  each (ADR-0038). And, on Linux, whether the owl outlives a logout.
  """
  use ExUnit.Case, async: true

  alias Whiska.Doctor
  alias Whiska.Doctor.Check
  alias Whiska.LaunchAgent
  alias Whiska.SystemdUnit

  describe "service_manager/4" do
    test "not installed is a warning that names install" do
      assert %Check{status: :warn, name: "launch agent", fix: "whiska owl install"} =
               Doctor.service_manager(LaunchAgent, false, %{loaded: false, pid: nil}, [])
    end

    test "installed but not loaded" do
      check = Doctor.service_manager(LaunchAgent, true, %{loaded: false, pid: nil}, [])
      assert check.status == :warn
      assert check.detail =~ "not loaded"
      assert check.fix == "whiska owl install"
    end

    test "loaded and running is ok and names the pid" do
      check = Doctor.service_manager(LaunchAgent, true, %{loaded: true, pid: 777}, [777])
      assert check.status == :ok
      assert check.detail =~ "777"
    end

    test "loaded but stopped points at start" do
      check = Doctor.service_manager(LaunchAgent, true, %{loaded: true, pid: nil}, [])
      assert check.status == :warn
      assert check.detail =~ "not running"
      assert check.fix == "whiska owl start"
    end

    test "loaded and crash-looping says so, with the exit code and the log" do
      check =
        Doctor.service_manager(
          LaunchAgent,
          true,
          %{loaded: true, pid: nil, last_exit_code: 1},
          []
        )

      assert check.status == :warn
      assert check.detail =~ "crash-looping"
      assert check.detail =~ "last exit code 1"
      assert check.detail =~ "owl.log"
    end

    test "loaded, stopped and cleanly exited is not called crash-looping" do
      check =
        Doctor.service_manager(
          LaunchAgent,
          true,
          %{loaded: true, pid: nil, last_exit_code: 0},
          []
        )

      assert check.status == :warn
      assert check.detail =~ "not running"
      refute check.detail =~ "crash-looping"
      assert check.fix == "whiska owl start"
    end

    test "a second owl beside the supervised one is a warning" do
      check = Doctor.service_manager(LaunchAgent, true, %{loaded: true, pid: 777}, [777, 4242])
      assert check.status == :warn
      assert check.detail =~ "4242"
      assert check.detail =~ "two owls"
    end

    test "an owl running only in the foreground, with no agent, is the plain not-installed warning" do
      check = Doctor.service_manager(LaunchAgent, false, %{loaded: false, pid: nil}, [4242])
      assert check.status == :warn
      assert check.detail =~ "foreground"
      assert check.fix == "whiska owl install"
    end
  end

  test "run/2 includes the line, after the owl line" do
    root = Path.join(System.tmp_dir!(), "whiska-doctor-la-#{System.unique_integer([:positive])}")
    main = Path.join(root, "myrepo")
    File.mkdir_p!(Path.join(main, ".git"))
    on_exit(fn -> File.rm_rf!(root) end)

    report =
      Doctor.run(main,
        env: %{"HOME" => root, "PATH" => ""},
        owl_pids: fn -> [] end,
        supervision: fn -> {false, %{loaded: false, pid: nil}} end
      )

    names = Enum.map(report.checks, & &1.name)

    assert Enum.find_index(names, &(&1 == "launch agent")) ==
             Enum.find_index(names, &(&1 == "owl")) + 1

    refute "logout" in names
  end

  describe "under systemd" do
    test "the line is named for the unit, and names it" do
      check = Doctor.service_manager(SystemdUnit, true, %{loaded: true, pid: 777}, [777])
      assert %Check{status: :ok, name: "systemd unit"} = check
      assert check.detail =~ "whiska-owl.service"
    end

    test "two owls name systemd's" do
      check = Doctor.service_manager(SystemdUnit, true, %{loaded: true, pid: 777}, [777, 4242])
      assert check.detail =~ "systemd's (pid 777)"
    end

    test "lingering off is a warning that names the fix" do
      assert [%Check{status: :warn, name: "logout", fix: "loginctl enable-linger"} = check] =
               Doctor.linger(SystemdUnit, false)

      assert check.detail =~ "stops the owl"
    end

    test "lingering on is ok" do
      assert [%Check{status: :ok, name: "logout"}] = Doctor.linger(SystemdUnit, true)
    end

    test "launchd has no logout line" do
      assert Doctor.linger(LaunchAgent, :not_applicable) == []
    end

    test "run/2 puts the logout line right after the unit's" do
      root =
        Path.join(System.tmp_dir!(), "whiska-doctor-sd-#{System.unique_integer([:positive])}")

      main = Path.join(root, "myrepo")
      File.mkdir_p!(Path.join(main, ".git"))
      on_exit(fn -> File.rm_rf!(root) end)

      report =
        Doctor.run(main,
          env: %{"HOME" => root, "PATH" => ""},
          owl_pids: fn -> [] end,
          service_manager: SystemdUnit,
          ready: fn -> :ok end,
          supervision: fn -> {true, %{loaded: true, pid: nil, last_exit_code: 0}} end,
          linger: fn -> false end
        )

      names = Enum.map(report.checks, & &1.name)
      unit = Enum.find_index(names, &(&1 == "systemd unit"))

      assert unit == Enum.find_index(names, &(&1 == "owl")) + 1
      assert Enum.at(names, unit + 1) == "logout"
      refute "launch agent" in names
    end

    test "where this user has no systemd, says so and offers only the fix that works" do
      root =
        Path.join(System.tmp_dir!(), "whiska-doctor-nosd-#{System.unique_integer([:positive])}")

      main = Path.join(root, "myrepo")
      File.mkdir_p!(Path.join(main, ".git"))
      on_exit(fn -> File.rm_rf!(root) end)

      report =
        Doctor.run(main,
          env: %{"HOME" => root, "PATH" => ""},
          owl_pids: fn -> [] end,
          service_manager: SystemdUnit,
          ready: fn -> {:error, "systemd is not running for this user here (no bus)"} end,
          supervision: fn -> {false, %{loaded: false, pid: nil}} end,
          linger: fn -> false end
        )

      check = Enum.find(report.checks, &(&1.name == "systemd unit"))

      assert check.status == :warn
      assert check.detail =~ "not running for this user"
      assert check.detail =~ "foreground"
      assert check.fix == "whiska owl  (in a pane)"
      refute Enum.any?(report.checks, &(&1.name == "logout"))
    end
  end
end
