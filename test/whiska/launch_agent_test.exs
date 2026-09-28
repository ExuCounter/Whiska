defmodule Whiska.LaunchAgentTest do
  @moduledoc """
  The owl's LaunchAgent as pure values and as files under a temp home.
  Nothing here touches ~/Library/LaunchAgents or calls launchctl for real:
  the launchctl calls are captured through an injected runner.
  """
  use ExUnit.Case, async: true

  alias Whiska.Install
  alias Whiska.LaunchAgent

  setup do
    home = Path.join(System.tmp_dir!(), "whiska-launchd-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    on_exit(fn -> File.rm_rf!(home) end)
    {:ok, home: home, paths: LaunchAgent.paths(home, Path.join(home, ".whiska"))}
  end

  describe "paths/2" do
    test "the plist under the user's LaunchAgents, the rest in the whiska home", %{home: home} do
      paths = LaunchAgent.paths(home, "/w")

      assert LaunchAgent.label() == "com.whiska.owl"
      assert paths.plist == Path.join(home, "Library/LaunchAgents/com.whiska.owl.plist")
      assert paths.wrapper == "/w/owl.sh"
      assert paths.log == "/w/owl.log"
    end
  end

  describe "plist/2" do
    test "runs the wrapper, at load, and restarts only a crash", %{paths: paths} do
      plist = LaunchAgent.plist(paths, %{})

      assert plist =~ "<string>com.whiska.owl</string>"
      assert plist =~ "<string>/bin/bash</string>"
      assert plist =~ "<string>#{paths.wrapper}</string>"
      assert plist =~ ~r/<key>RunAtLoad<\/key>\s*<true\/>/
      assert plist =~ ~r/<key>KeepAlive<\/key>\s*<dict>\s*<key>SuccessfulExit<\/key>\s*<false\/>/
      assert plist =~ ~r/<key>StandardOutPath<\/key>\s*<string>#{paths.log}<\/string>/
      assert plist =~ ~r/<key>StandardErrorPath<\/key>\s*<string>#{paths.log}<\/string>/
      refute plist =~ "escript"
    end

    test "copies herdr's socket and the whiska overrides from the installing shell", %{
      paths: paths
    } do
      env = %{
        "HERDR_SOCKET_PATH" => "/tmp/h.sock",
        "WHISKA_BIN" => "/opt/whiska",
        "WHISKA_ESCRIPT" => "/opt/escript",
        "WHISKA_HOME" => "/w",
        "PATH" => "/usr/bin",
        "SECRET" => "no"
      }

      plist = LaunchAgent.plist(paths, env)

      assert plist =~ ~r/<key>HERDR_SOCKET_PATH<\/key>\s*<string>\/tmp\/h.sock<\/string>/
      assert plist =~ ~r/<key>WHISKA_BIN<\/key>\s*<string>\/opt\/whiska<\/string>/
      assert plist =~ ~r/<key>WHISKA_ESCRIPT<\/key>\s*<string>\/opt\/escript<\/string>/
      assert plist =~ ~r/<key>WHISKA_HOME<\/key>\s*<string>\/w<\/string>/
      refute plist =~ "SECRET"
      refute plist =~ "<key>PATH</key>"
    end

    test "with nothing to pass through, there is no EnvironmentVariables dict", %{paths: paths} do
      refute LaunchAgent.plist(paths, %{"PATH" => "/usr/bin", "WHISKA_BIN" => ""}) =~
               "EnvironmentVariables"
    end

    test "escapes XML in values", %{home: home} do
      paths = LaunchAgent.paths(home, "/a&b")
      plist = LaunchAgent.plist(paths, %{"HERDR_SOCKET_PATH" => "/x<y>"})
      assert plist =~ "/a&amp;b/owl.sh"
      assert plist =~ "/x&lt;y&gt;"
    end

    test "is a plist launchd accepts", %{home: home, paths: paths} do
      file = Path.join(home, "check.plist")
      File.write!(file, LaunchAgent.plist(paths, %{"HERDR_SOCKET_PATH" => "/tmp/h.sock"}))
      assert {_, 0} = System.cmd("plutil", ["-lint", file], stderr_to_stdout: true)
    end
  end

  describe "wrapper/0" do
    test "resolves the binary and runtime exactly as the hook shim does" do
      assert LaunchAgent.wrapper() =~ Install.resolve_whiska()
      assert LaunchAgent.wrapper() =~ Install.resolve_escript()
      assert Install.shim() =~ Install.resolve_whiska()
      assert Install.statusline_script() =~ Install.resolve_escript()
      assert String.starts_with?(LaunchAgent.wrapper(), "#!/usr/bin/env bash\n")
    end

    test "execs the owl with no arguments, and fails loudly with no binary" do
      assert LaunchAgent.wrapper() =~ ~s|exec "$escript_bin" "$whiska_bin" owl\n|
      assert LaunchAgent.wrapper() =~ ~s|exec "$whiska_bin" owl\n|
      assert LaunchAgent.wrapper() =~ "exit 1"
      refute LaunchAgent.wrapper() =~ "exit 0"
    end
  end

  describe "install/2 and uninstall/1" do
    test "writes the wrapper (executable) and the plist", %{paths: paths} do
      assert :ok = LaunchAgent.install(paths, %{})

      assert File.read!(paths.plist) == LaunchAgent.plist(paths, %{})
      assert File.read!(paths.wrapper) == LaunchAgent.wrapper()
      assert {:ok, %File.Stat{mode: mode}} = File.stat(paths.wrapper)
      assert Bitwise.band(mode, 0o100) != 0
    end

    test "is idempotent", %{paths: paths} do
      assert :ok = LaunchAgent.install(paths, %{})
      assert :ok = LaunchAgent.install(paths, %{})
    end

    test "uninstall removes both and keeps the log", %{paths: paths} do
      :ok = LaunchAgent.install(paths, %{})
      File.write!(paths.log, "kept\n")

      assert :ok = LaunchAgent.uninstall(paths)
      refute File.exists?(paths.plist)
      refute File.exists?(paths.wrapper)
      assert File.read!(paths.log) == "kept\n"
    end

    test "uninstall of nothing says so", %{paths: paths} do
      assert {:error, :not_installed} = LaunchAgent.uninstall(paths)
    end

    test "installed?/1 means the plist is there", %{paths: paths} do
      refute LaunchAgent.installed?(paths)
      :ok = LaunchAgent.install(paths, %{})
      assert LaunchAgent.installed?(paths)
    end
  end

  describe "launchctl" do
    # A runner receives launchctl's arguments and returns {output, status}.
    defp recorder(reply \\ {"", 0}) do
      me = self()

      fn args ->
        send(me, {:launchctl, args})
        reply
      end
    end

    test "bootstrap loads the plist into the user's gui domain", %{paths: paths} do
      assert :ok = LaunchAgent.bootstrap(paths, 501, recorder())
      assert_received {:launchctl, ["bootstrap", "gui/501", plist]}
      assert plist == paths.plist
    end

    test "bootout, stop and start name the service" do
      assert :ok = LaunchAgent.bootout(501, recorder())
      assert_received {:launchctl, ["bootout", "gui/501/com.whiska.owl"]}

      assert :ok = LaunchAgent.stop(501, recorder())
      assert_received {:launchctl, ["kill", "TERM", "gui/501/com.whiska.owl"]}

      assert :ok = LaunchAgent.start(501, recorder())
      assert_received {:launchctl, ["kickstart", "gui/501/com.whiska.owl"]}
    end

    test "a failing launchctl is reported with its output" do
      assert {:error, "Bootstrap failed: 5: Input/output error"} =
               LaunchAgent.bootout(
                 501,
                 recorder({"Bootstrap failed: 5: Input/output error\n", 5})
               )
    end

    test "status: not loaded when launchctl print fails" do
      runner =
        recorder({"Could not find service \"com.whiska.owl\" in domain for user gui: 501\n", 113})

      assert %{loaded: false, pid: nil} = LaunchAgent.status(501, runner)
      assert_received {:launchctl, ["print", "gui/501/com.whiska.owl"]}
    end

    test "status: loaded and running carries the pid" do
      out = """
      gui/501/com.whiska.owl = {
      \tactive count = 1
      \tpath = /Users/me/Library/LaunchAgents/com.whiska.owl.plist
      \tstate = running
      \tpid = 4242
      \tprogram = /bin/bash
      }
      """

      assert %{loaded: true, pid: 4242} = LaunchAgent.status(501, recorder({out, 0}))
    end

    test "status: loaded but not running" do
      out = "gui/501/com.whiska.owl = {\n\tstate = not running\n\tlast exit code = 0\n}\n"

      assert %{loaded: true, pid: nil, last_exit_code: 0} =
               LaunchAgent.status(501, recorder({out, 0}))
    end

    # A job launchd keeps restarting says so in the same print: no pid, a
    # non-zero last exit code, and a rising run count.
    test "status: a crash-looping job carries its last exit code" do
      out = """
      gui/501/com.whiska.owl = {
      \tstate = spawn scheduled
      \truns = 4
      \tlast exit code = 1
      }
      """

      assert %{loaded: true, pid: nil, last_exit_code: 1} =
               LaunchAgent.status(501, recorder({out, 0}))
    end

    test "status: a job that has never exited has no last exit code" do
      out =
        "gui/501/com.whiska.owl = {\n\tstate = running\n\tlast exit code = (never exited)\n}\n"

      assert %{last_exit_code: nil} = LaunchAgent.status(501, recorder({out, 0}))
    end
  end
end
