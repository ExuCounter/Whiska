defmodule Whiska.InstallShimStopTest do
  @moduledoc """
  The shim's `stop` path: one `Stop` entry, straight through to `whiska hook stop`.

  Nothing runs in front of it (ADR-0048), so a turn's final message reaches the
  doorstep on the first stop of the turn, whatever the message says.
  `Whiska.Hook.Stop` stays what ADR-0036 describes: unconditional, never classifying.

  Everything here runs the real shim with a stub binary standing in for Whiska,
  because the path only exists in shell.
  """
  use ExUnit.Case, async: true

  alias Whiska.Install

  @done "All finished.\n\n[worktree-status: done]"
  @needs_decision "One question.\n\n[worktree-status: needs-decision] which?"

  setup do
    root = Path.join(System.tmp_dir!(), "whiska-shim-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "state"))
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  describe "settings.json" do
    test "there is one Stop entry, and it is the shim" do
      assert [entry] = Install.merge(%{})["hooks"]["Stop"]
      assert [%{"command" => command}] = entry["hooks"]
      assert command == Install.stop_command()
    end
  end

  describe "the stop path" do
    test "a finished turn reaches Whiska on the first stop, payload intact", %{root: root} do
      sandbox = sandbox(root)

      assert %{out: "", called: [call]} = run(sandbox, "stop", @done)
      assert call.args == ["hook", "stop"]
      assert JSON.decode!(call.stdin)["last_assistant_message"] == @done
    end

    test "carries the hook's own exit status out, which the doctor reads", %{root: root} do
      sandbox = sandbox(root, exit_status: 2)

      assert %{status: 2} = run(sandbox, "stop", @done)
    end

    test "a turn waiting on the person goes to the doorstep the same way", %{root: root} do
      sandbox = sandbox(root)

      assert %{out: "", called: [call]} = run(sandbox, "stop", @needs_decision)
      assert JSON.decode!(call.stdin)["last_assistant_message"] == @needs_decision
    end
  end

  describe "the pre-tool-use path" do
    test "passes stdin through untouched", %{root: root} do
      sandbox = sandbox(root)
      payload = JSON.encode!(%{"cwd" => root, "tool_name" => "Read"})

      assert %{out: "", called: [call]} = run_raw(sandbox, "pre-tool-use", payload)
      assert call.args == ["hook", "pre-tool-use"]
      assert call.stdin == payload
    end
  end

  # A directory holding the real shim and a stub that records what Whiska would
  # have been given.
  defp sandbox(root, opts \\ []) do
    shim = Path.join(root, "whiska.sh")
    whiska = Path.join(root, "fake-whiska")
    escript = Path.join(root, "fake-escript")
    log = Path.join(root, "calls")

    File.write!(shim, Install.shim())

    # Records its arguments, one a line, and everything on its stdin.
    File.write!(whiska, """
    #!/usr/bin/env bash
    cat > "#{log}.stdin"
    printf '%s\\n' "$@" > "#{log}"
    exit #{Keyword.get(opts, :exit_status, 0)}
    """)

    # Stands in for the Erlang runtime: runs the escript it is handed.
    File.write!(escript, """
    #!/usr/bin/env bash
    exec "$@"
    """)

    for f <- [shim, whiska, escript], do: File.chmod!(f, 0o755)

    %{root: root, shim: shim, whiska: whiska, escript: escript, log: log}
  end

  defp run(sandbox, hook, message) do
    payload =
      JSON.encode!(%{
        "cwd" => sandbox.root,
        "session_id" => "session-one",
        "stop_hook_active" => false,
        "last_assistant_message" => message
      })

    run_raw(sandbox, hook, payload)
  end

  defp run_raw(sandbox, hook, payload) do
    n = System.unique_integer([:positive])
    payload_file = Path.join(sandbox.root, "payload-#{n}.json")
    err_file = Path.join(sandbox.root, "err-#{n}.txt")
    File.write!(payload_file, payload)
    File.rm(sandbox.log)
    File.rm(sandbox.log <> ".stdin")

    env = [
      {"TMPDIR", Path.join(sandbox.root, "state")},
      {"WHISKA_ESCRIPT", sandbox.escript},
      # An unset WHISKA_BIN would let the shim find a real whiska on PATH, so
      # "not installed" is spelled as a path to nothing.
      {"WHISKA_BIN", sandbox.whiska || Path.join(sandbox.root, "no-whiska-here")}
    ]

    {out, status} =
      System.cmd(
        "bash",
        ["-c", ~s|bash "#{sandbox.shim}" #{hook} < "#{payload_file}" 2> "#{err_file}"|],
        env: env
      )

    called =
      case File.read(sandbox.log) do
        {:ok, args} ->
          [
            %{
              stdin: File.read!(sandbox.log <> ".stdin"),
              args: String.split(args, "\n", trim: true)
            }
          ]

        _ ->
          []
      end

    %{out: String.trim(out), err: File.read!(err_file), called: called, status: status}
  end
end
