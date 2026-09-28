defmodule Whiska.InstallReviewLoopTest do
  @moduledoc """
  The review loop `whiska init` writes (ADR-0042).

  The script is the repo's, not Whiska's, so the only thing asserted about its
  contents is the shape `init` promises: a `CHECK` line the person edits, a
  `TIMEOUT` beside it, and nothing naming the machine that ran `init`.
  Everything else here runs the real file with a fake `Stop` payload, because a
  hook that is never executed in a test is a hook nobody has checked.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Whiska.CLI
  alias Whiska.Install

  @done "Finished the thing.\n\n[worktree-status: done]"
  @needs_decision "Two options, see above.\n\n[worktree-status: needs-decision] 2 questions"
  @unmarked "I did some work and forgot the marker entirely."

  setup do
    root = Path.join(System.tmp_dir!(), "whiska-loop-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "state"))
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  describe "how the loop is reached" do
    test "it gets no settings.json entry of its own — the shim chains it" do
      # Its own Stop entry would run in parallel with Whiska's, which is the
      # race ADR-0042's addendum to ADR-0036 closes. Whiska.InstallShimStopTest
      # covers the chaining itself.
      commands =
        Install.merge(%{})["hooks"]["Stop"]
        |> Enum.flat_map(fn entry -> Enum.map(entry["hooks"], & &1["command"]) end)

      assert commands == [Install.stop_command()]
      assert Install.shim() =~ Path.basename(Install.review_loop_path())
    end

    test "names nothing specific to the machine that ran init" do
      refute Install.review_loop() =~ System.user_home!()
      refute Install.review_loop() =~ "/Users/"
      refute Install.review_loop() =~ "/home/"
    end
  end

  describe "whiska init writes it" do
    test "writes the script, executable, where settings.json says it is", %{root: root} do
      File.mkdir_p!(Path.join(root, ".git"))
      capture_io(fn -> CLI.run(["init"], root) end)

      path = Path.join(root, Install.review_loop_path())

      assert File.read!(path) == Install.review_loop()
      assert %File.Stat{mode: mode} = File.stat!(path)
      assert Bitwise.band(mode, 0o100) == 0o100, "the hook has to be executable"
    end

    test "never overwrites one that is already there", %{root: root} do
      File.mkdir_p!(Path.join(root, ".git"))
      path = Path.join(root, Install.review_loop_path())
      File.mkdir_p!(Path.dirname(path))
      # The CHECK line in here is the person's, and running init again — or
      # `whiska update` — must not throw it away.
      File.write!(path, "#!/usr/bin/env bash\n# mine\nCHECK='make ci'\n")

      capture_io(fn -> CLI.run(["init"], root) end)

      assert File.read!(path) =~ "make ci"
    end
  end

  describe "review_loop/0 — the shape the person edits" do
    test "the check command is one line the person can find" do
      lines = String.split(Install.review_loop(), "\n")

      assert Enum.count(lines, &String.starts_with?(&1, "CHECK=")) == 1
      assert Enum.count(lines, &String.starts_with?(&1, "TIMEOUT=")) == 1
    end

    test "is a shell script that reads the payload on stdin" do
      script = Install.review_loop()

      assert script =~ ~r/\A#!/
      assert script =~ "last_assistant_message"
      assert script =~ "stop_hook_active"
    end
  end

  describe "which turns the loop is interested in" do
    test "a turn waiting on the person is never blocked", %{root: root} do
      path = install(root, "exit 1")

      assert %{out: ""} = run(root, path, @needs_decision)
    end

    test "a turn with no marker at all is never blocked", %{root: root} do
      # An unmarked turn is already something the owl reports (ADR-0009).
      # Blocking it here would talk over that.
      path = install(root, "exit 1")

      assert %{out: ""} = run(root, path, @unmarked)
    end
  end

  describe "a turn that says it is done" do
    test "failing checks block the stop and carry the output", %{root: root} do
      path = install(root, "echo the-suite-is-red; exit 1")

      assert %{"decision" => "block", "reason" => reason} = blocked(run(root, path, @done))
      assert reason =~ "the-suite-is-red"
    end

    test "passing checks still block once, for the review pass", %{root: root} do
      path = install(root, "exit 0")

      assert %{"decision" => "block", "reason" => reason} = blocked(run(root, path, @done))
      assert reason =~ "docs/adr/"
      assert reason =~ "specs/"
    end

    test "the review pass is asked for once per turn, not every stop", %{root: root} do
      path = install(root, "exit 0")

      assert %{"decision" => "block"} = blocked(run(root, path, @done))
      assert %{out: ""} = run(root, path, @done, active: true)
    end

    test "checks that go green after failing still get their review pass", %{root: root} do
      red = install(root, "exit 1")
      green = install(root, "exit 0")

      assert %{"decision" => "block"} = blocked(run(root, red, @done))

      assert %{"decision" => "block", "reason" => reason} =
               blocked(run(root, green, @done, active: true))

      assert reason =~ "docs/adr/"
    end
  end

  describe "the loop is bounded (ADR-0011's shape)" do
    test "two blocks for failing checks, then the stop goes through", %{root: root} do
      path = install(root, "exit 1")

      assert %{"decision" => "block"} = blocked(run(root, path, @done))
      assert %{"decision" => "block"} = blocked(run(root, path, @done, active: true))

      # Third time: the person needs to see this, not the mouse again.
      assert %{out: "", err: err} = run(root, path, @done, active: true)
      assert err =~ "letting the stop through"
    end

    test "a new turn starts the count over", %{root: root} do
      path = install(root, "exit 1")

      for active <- [false, true, true], do: run(root, path, @done, active: active)

      # stop_hook_active false means a fresh turn, so the ceiling resets with it.
      assert %{"decision" => "block"} = blocked(run(root, path, @done))
    end

    test "two sessions do not share a count", %{root: root} do
      path = install(root, "exit 1")

      run(root, path, @done, session: "a")
      run(root, path, @done, session: "a", active: true)

      assert %{"decision" => "block"} = blocked(run(root, path, @done, session: "b"))
    end
  end

  describe "a check that hangs" do
    @tag timeout: 60_000
    test "is killed, and the pane is not held for ever", %{root: root} do
      path = install(root, "sleep 30", timeout: 1)

      {micros, result} = :timer.tc(fn -> run(root, path, @done) end)

      assert %{"decision" => "block", "reason" => reason} = blocked(result)
      assert reason =~ "timed out"
      assert micros < 20_000_000, "the hook waited #{div(micros, 1_000_000)}s on a 1s timeout"
    end
  end

  # The real script, with only the two lines the person is meant to edit
  # rewritten — so what these tests exercise is what `whiska init` writes.
  defp install(root, check, opts \\ []) do
    path = Path.join(root, "review-loop-#{System.unique_integer([:positive])}.sh")

    body =
      Install.review_loop()
      |> replace_line("CHECK=", "CHECK='#{check}'")
      |> replace_line("TIMEOUT=", "TIMEOUT=#{Keyword.get(opts, :timeout, 60)}")

    File.write!(path, body)
    path
  end

  defp replace_line(body, prefix, replacement) do
    body
    |> String.split("\n")
    |> Enum.map(fn line -> if String.starts_with?(line, prefix), do: replacement, else: line end)
    |> Enum.join("\n")
  end

  defp run(root, path, message, opts \\ []) do
    payload =
      JSON.encode!(%{
        "session_id" => Keyword.get(opts, :session, "session-one"),
        "stop_hook_active" => Keyword.get(opts, :active, false),
        "last_assistant_message" => message
      })

    payload_file = Path.join(root, "payload-#{System.unique_integer([:positive])}.json")
    err_file = Path.join(root, "err-#{System.unique_integer([:positive])}.txt")
    File.write!(payload_file, payload)

    {out, _status} =
      System.cmd(
        "bash",
        ["-c", ~s|bash "#{path}" < "#{payload_file}" 2> "#{err_file}"|],
        env: [{"TMPDIR", Path.join(root, "state")}]
      )

    %{out: String.trim(out), err: File.read!(err_file)}
  end

  defp blocked(%{out: out}), do: JSON.decode!(out)
end
