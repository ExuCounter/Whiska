defmodule Whiska.Test.ClaudeTree do
  @moduledoc """
  Real processes named `claude`, for the nested-session check
  (ADR-next-a-nested-session-speaks-for-nobody).

  Nothing is mocked (ADR-0031): each `claude` is a symlink to a system binary,
  which `ps` reports under the symlink's name. `lone/1` is one `claude`, the way
  a mouse runs. `nested/1` is a `claude` running a `claude`, the way a mouse's
  test script does. Both return the pid a hook would see as `CLAUDE_PID`, and
  stop with the test.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  @doc """
  One `claude` with no other above it. Its launching shell has exited by the
  time this returns, and the kernel re-parents an orphan as its parent exits,
  so it hangs off init (or a subreaper), not off the test run.
  """
  @spec lone(Path.t()) :: String.t()
  def lone(dir) do
    inner = link(dir, "lone", "/bin/sleep")
    spawn_sh("exec #{inner} 60")
  end

  @doc """
  A `claude` in a herdr pane, where that herdr was itself started under a
  `claude`: the walk stops at the pane, so this one is the mouse.
  """
  @spec under_herdr(Path.t()) :: String.t()
  def under_herdr(dir) do
    outer = link(dir, "outer", "/bin/sh")
    herdr = link(dir, "herdr", "/bin/sh", "herdr")
    inner = link(dir, "inner", "/bin/sleep")
    outer_pid = spawn_sh(~s(exec #{outer} -c "#{herdr} -c '#{inner} 60; :'; :"))
    outer_pid |> child_of(200) |> child_of(200)
  end

  @doc "A pid that named a process a moment ago and names none now."
  @spec gone() :: String.t()
  def gone do
    {out, 0} = System.cmd("/bin/sh", ["-c", "true & echo $!; wait"])
    String.trim(out)
  end

  @doc "A `claude` running under another `claude`; the inner one's pid."
  @spec nested(Path.t()) :: String.t()
  def nested(dir) do
    outer = link(dir, "outer", "/bin/sh")
    inner = link(dir, "inner", "/bin/sleep")
    outer_pid = spawn_sh("exec #{outer} -c '#{inner} 60; :'")
    child_of(outer_pid, 200)
  end

  defp link(dir, name, target, as \\ "claude") do
    path = Path.join([dir, name, as])
    File.mkdir_p!(Path.dirname(path))
    File.ln_s!(target, path)
    path
  end

  # Started detached through a shell that prints the pid, so the process
  # outlives the port and is killed explicitly when the test ends.
  defp spawn_sh(command) do
    {out, 0} = System.cmd("/bin/sh", ["-c", "(#{command}) >/dev/null 2>&1 & echo $!"])
    pid = String.trim(out)
    on_exit(fn -> System.cmd("kill", ["-9", pid], stderr_to_stdout: true) end)
    pid
  end

  defp child_of(pid, 0), do: raise("no child under #{pid}")

  defp child_of(pid, tries) do
    case System.cmd("pgrep", ["-P", pid]) do
      {out, 0} ->
        child = out |> String.split() |> hd()
        on_exit(fn -> System.cmd("kill", ["-9", child], stderr_to_stdout: true) end)
        child

      _ ->
        Process.sleep(10)
        child_of(pid, tries - 1)
    end
  end
end
