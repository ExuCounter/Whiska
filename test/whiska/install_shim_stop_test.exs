defmodule Whiska.InstallShimStopTest do
  @moduledoc """
  The shim's `stop` path, which chains the review loop in front of Whiska's own
  hook (ADR-0042, ADR-0036's addendum).

  Claude Code runs `Stop` hooks in parallel, so registering the review loop as
  its own entry meant Whiska put a `done` on the doorstep while the loop was
  still blocking the turn. One entry, and the shim decides the order: the loop
  runs first, and `whiska hook stop` is simply not called when the turn did not
  end. `Whiska.Hook.Stop` is untouched — still unconditional, still never
  classifying, just not invoked.

  Everything here runs the real shim with a stub binary standing in for Whiska,
  because the ordering only exists in shell.
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

    test "re-running init drops the separate entry an earlier version wrote" do
      # The review loop was briefly its own Stop entry. Recognising it as ours
      # is what replaces it rather than leaving it to fire in parallel again.
      stale = %{
        "hooks" => %{
          "Stop" => [
            %{
              "hooks" => [
                %{
                  "type" => "command",
                  "command" => ~s|bash "$CLAUDE_PROJECT_DIR/#{Install.review_loop_path()}"|
                }
              ]
            }
          ]
        }
      }

      assert Install.merge(stale) == Install.merge(%{})
    end
  end

  describe "the stop path" do
    test "a block from the loop is passed through, and Whiska is never called", %{root: root} do
      sandbox = sandbox(root, "exit 1")

      assert %{out: out, called: []} = run(sandbox, "stop", @done)
      assert %{"decision" => "block"} = JSON.decode!(out)
    end

    test "a stop the loop is content with reaches Whiska, payload intact", %{root: root} do
      # Green checks still block once for the review pass, so the second stop of
      # the turn is the one that gets through.
      sandbox = sandbox(root, "exit 0")

      assert %{out: out} = run(sandbox, "stop", @done)
      assert %{"decision" => "block"} = JSON.decode!(out)

      assert %{out: "", called: [call]} = run(sandbox, "stop", @done, active: true)
      assert call.args == ["hook", "stop"]
      assert JSON.decode!(call.stdin)["last_assistant_message"] == @done
    end

    test "a turn waiting on the person goes straight to the doorstep", %{root: root} do
      sandbox = sandbox(root, "exit 1")

      assert %{out: "", called: [call]} = run(sandbox, "stop", @needs_decision)
      assert JSON.decode!(call.stdin)["last_assistant_message"] == @needs_decision
    end

    test "the loop still runs when Whiska is not installed", %{root: root} do
      # The loop is the repo's and needs nothing of Whiska's, so it has to run
      # before the shim's fail-open — otherwise a missing binary would silently
      # disable the repo's own gate as well.
      sandbox = sandbox(root, "exit 1")

      assert %{out: out, err: err} = run(%{sandbox | whiska: nil}, "stop", @done)
      assert %{"decision" => "block"} = JSON.decode!(out)
      refute err =~ "whiska: not found"
    end

    test "no review loop on disk means the stop just goes to Whiska", %{root: root} do
      sandbox = sandbox(root, "exit 1")
      File.rm!(Path.join(root, "review-loop.sh"))

      assert %{out: "", called: [_]} = run(sandbox, "stop", @done)
    end
  end

  describe "the pre-tool-use path" do
    test "never runs the review loop, and still passes stdin through", %{root: root} do
      # The hot path (ADR-0033) is untouched: no capture, no loop, no extra
      # process. A loop that failed here would deny tool calls.
      sandbox = sandbox(root, "exit 1")
      payload = JSON.encode!(%{"cwd" => root, "tool_name" => "Read"})

      assert %{out: "", called: [call]} = run_raw(sandbox, "pre-tool-use", payload)
      assert call.args == ["hook", "pre-tool-use"]
      assert call.stdin == payload
    end
  end

  describe "whiska doctor" do
    test "its stop probe does not set the review loop running", %{root: root} do
      # The probe used to send a payload ending in `[worktree-status: done]`.
      # Chained, that would make `whiska doctor` run the repo's whole suite and
      # then report the block as an unexpected probe output. ADR-0038: the
      # doctor checks, it never sets anything going.
      hooks = Path.join(root, ".claude/hooks")
      File.mkdir_p!(hooks)
      sandbox = sandbox(root, "echo the-loop-ran; exit 1")
      File.cp!(sandbox.shim, Path.join(hooks, "whiska.sh"))
      File.cp!(Path.join(root, "review-loop.sh"), Path.join(hooks, "review-loop.sh"))
      File.chmod!(Path.join(hooks, "review-loop.sh"), 0o755)

      env = %{
        "PATH" => System.get_env("PATH"),
        "HOME" => System.get_env("HOME"),
        "TMPDIR" => Path.join(root, "state"),
        "WHISKA_BIN" => sandbox.whiska,
        "WHISKA_ESCRIPT" => sandbox.escript
      }

      assert %Whiska.Doctor.Check{status: :ok} = Whiska.Doctor.probe(root, "stop", env)
    end
  end

  # A directory holding the real shim, the real review loop, and a stub that
  # records what Whiska would have been given.
  defp sandbox(root, check) do
    shim = Path.join(root, "whiska.sh")
    loop = Path.join(root, "review-loop.sh")
    whiska = Path.join(root, "fake-whiska")
    escript = Path.join(root, "fake-escript")
    log = Path.join(root, "calls")

    File.write!(shim, Install.shim())

    File.write!(
      loop,
      Install.review_loop()
      |> replace_line("CHECK=", "CHECK='#{check}'")
      |> replace_line("TIMEOUT=", "TIMEOUT=60")
    )

    # Records its arguments and everything on its stdin, one JSON line per call.
    File.write!(whiska, """
    #!/usr/bin/env bash
    stdin="$(cat)"
    printf '%s\\n' "$(jq -c -n --arg s "$stdin" --args '{stdin: $s, args: $ARGS.positional}' "$@")" \\
      >> "#{log}"
    """)

    # Stands in for the Erlang runtime: runs the escript it is handed.
    File.write!(escript, """
    #!/usr/bin/env bash
    exec "$@"
    """)

    for f <- [shim, loop, whiska, escript], do: File.chmod!(f, 0o755)

    %{root: root, shim: shim, whiska: whiska, escript: escript, log: log}
  end

  defp run(sandbox, hook, message, opts \\ []) do
    payload =
      JSON.encode!(%{
        "cwd" => sandbox.root,
        "session_id" => Keyword.get(opts, :session, "session-one"),
        "stop_hook_active" => Keyword.get(opts, :active, false),
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

    env = [
      {"TMPDIR", Path.join(sandbox.root, "state")},
      {"WHISKA_ESCRIPT", sandbox.escript},
      # An unset WHISKA_BIN would let the shim find a real whiska on PATH, so
      # "not installed" is spelled as a path to nothing.
      {"WHISKA_BIN", sandbox.whiska || Path.join(sandbox.root, "no-whiska-here")}
    ]

    {out, _status} =
      System.cmd(
        "bash",
        ["-c", ~s|bash "#{sandbox.shim}" #{hook} < "#{payload_file}" 2> "#{err_file}"|],
        env: env
      )

    called =
      case File.read(sandbox.log) do
        {:ok, text} ->
          text
          |> String.split("\n", trim: true)
          |> Enum.map(fn line ->
            decoded = JSON.decode!(line)
            %{stdin: decoded["stdin"], args: decoded["args"]}
          end)

        _ ->
          []
      end

    %{out: String.trim(out), err: File.read!(err_file), called: called}
  end

  defp replace_line(body, prefix, replacement) do
    body
    |> String.split("\n")
    |> Enum.map(fn line -> if String.starts_with?(line, prefix), do: replacement, else: line end)
    |> Enum.join("\n")
  end
end
