defmodule Whiska.ServiceManagerTest do
  use ExUnit.Case, async: true

  alias Whiska.ServiceManager

  test "launchd keeps the owl on macOS, systemd everywhere else" do
    assert ServiceManager.for_os({:unix, :darwin}) == Whiska.LaunchAgent
    assert ServiceManager.for_os({:unix, :linux}) == Whiska.SystemdUnit
  end

  test "a program that is not installed answers exit 127 rather than raising" do
    assert {out, 127} = ServiceManager.cmd("whiska-test-no-such-program", ["--version"])
    assert out =~ "not found"
  end

  test "a runner that raises answers as a failed call" do
    run = fn args -> System.cmd("whiska-test-no-such-program", args) end
    assert {_, 127} = ServiceManager.call(run, ["print"])
  end

  test "a job carries herdr's socket and the whiska overrides, nothing else" do
    env = %{
      "HERDR_SOCKET_PATH" => "/tmp/h.sock",
      "WHISKA_BIN" => "",
      "WHISKA_HOME" => "/w",
      "PATH" => "/usr/bin"
    }

    assert ServiceManager.passthrough(env) == [
             {"HERDR_SOCKET_PATH", "/tmp/h.sock"},
             {"WHISKA_HOME", "/w"}
           ]
  end
end
