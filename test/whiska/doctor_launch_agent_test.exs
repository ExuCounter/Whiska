defmodule Whiska.DoctorLaunchAgentTest do
  @moduledoc "The doctor's `launch agent` line: installed, loaded, running — and the fix for each (ADR-0038)."
  use ExUnit.Case, async: true

  alias Whiska.Doctor
  alias Whiska.Doctor.Check

  describe "launch_agent/3" do
    test "not installed is a warning that names install" do
      assert %Check{status: :warn, name: "launch agent", fix: "whiska owl install"} =
               Doctor.launch_agent(false, %{loaded: false, pid: nil}, [])
    end

    test "installed but not loaded" do
      check = Doctor.launch_agent(true, %{loaded: false, pid: nil}, [])
      assert check.status == :warn
      assert check.detail =~ "not loaded"
      assert check.fix == "whiska owl install"
    end

    test "loaded and running is ok and names the pid" do
      check = Doctor.launch_agent(true, %{loaded: true, pid: 777}, [777])
      assert check.status == :ok
      assert check.detail =~ "777"
    end

    test "loaded but stopped points at start" do
      check = Doctor.launch_agent(true, %{loaded: true, pid: nil}, [])
      assert check.status == :warn
      assert check.detail =~ "not running"
      assert check.fix == "whiska owl start"
    end

    test "a second owl beside the supervised one is a warning" do
      check = Doctor.launch_agent(true, %{loaded: true, pid: 777}, [777, 4242])
      assert check.status == :warn
      assert check.detail =~ "4242"
      assert check.detail =~ "two owls"
    end

    test "an owl running only in the foreground, with no agent, is the plain not-installed warning" do
      check = Doctor.launch_agent(false, %{loaded: false, pid: nil}, [4242])
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
        launch_agent: fn -> {false, %{loaded: false, pid: nil}} end
      )

    names = Enum.map(report.checks, & &1.name)

    assert Enum.find_index(names, &(&1 == "launch agent")) ==
             Enum.find_index(names, &(&1 == "owl")) + 1
  end
end
