defmodule Whiska.EscriptTest do
  @moduledoc """
  Exercises the real `whiska` binary the way the PreToolUse hook will: a fresh
  process per call, JSON on stdin, JSON or silence on stdout.

  Everything else in this suite tests modules in-process. This is the only test
  that proves the thing actually shipped — an escript with `app: nil` starts no
  applications for itself, so a missing `Application.ensure_all_started` shows up
  here and nowhere else.
  """

  use ExUnit.Case, async: true

  @binary Path.expand("../../whiska", __DIR__)

  setup_all do
    {_, 0} =
      System.cmd("mix", ["escript.build"],
        cd: Path.expand("../..", __DIR__),
        env: [{"MIX_ENV", "dev"}],
        stderr_to_stdout: true
      )

    :ok
  end

  setup do
    root = Path.join(System.tmp_dir!(), "whiska-escript-#{System.unique_integer([:positive])}")
    main = Path.join(root, "myrepo")
    worktree = Path.join(main, "worktrees/feat-thing")
    File.mkdir_p!(Path.join(main, ".git"))
    File.mkdir_p!(Path.join(worktree, "lib"))
    File.write!(Path.join(worktree, ".git"), "gitdir: #{main}/.git/worktrees/feat-thing\n")
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, main: main, worktree: worktree}
  end

  # stdin has to reach EOF or the binary blocks on `IO.read(:eof)` forever, and
  # an Erlang port cannot half-close stdin — hence the shell redirect from a file.
  defp hook(fields, cd) do
    payload_file = Path.join(cd, "payload-#{System.unique_integer([:positive])}.json")
    File.write!(payload_file, JSON.encode!(fields))

    # stdout carries the decision and nothing else — that is the hook contract.
    # stderr is diagnostics, and is deliberately kept out of this capture.
    {out, status} =
      System.cmd("sh", ["-c", "#{@binary} hook pre-tool-use < #{payload_file} 2>/dev/null"],
        cd: cd
      )

    File.rm(payload_file)
    {out, status}
  end

  test "denies a main-checkout write, end to end", %{main: main, worktree: worktree} do
    {_, 0} = System.cmd(@binary, ["shape", "build"], cd: worktree, stderr_to_stdout: true)

    {out, status} =
      hook(
        %{
          "cwd" => worktree,
          "tool_name" => "Write",
          "tool_input" => %{"file_path" => Path.join(main, "CONTEXT.md")}
        },
        worktree
      )

    assert status == 0

    assert %{
             "hookSpecificOutput" => %{
               "hookEventName" => "PreToolUse",
               "permissionDecision" => "deny",
               "permissionDecisionReason" => reason
             }
           } = JSON.decode!(out)

    assert reason =~ "ADR-0013"
  end

  test "allows a write inside the worktree, silently", %{worktree: worktree} do
    {_, 0} = System.cmd(@binary, ["shape", "build"], cd: worktree, stderr_to_stdout: true)

    {out, status} =
      hook(
        %{
          "cwd" => worktree,
          "tool_name" => "Write",
          "tool_input" => %{"file_path" => Path.join(worktree, "lib/fine.ex")}
        },
        worktree
      )

    assert status == 0
    assert out == ""
  end

  test "mints the marker on first invocation", %{worktree: worktree} do
    {_, 0} = hook(%{"cwd" => worktree, "tool_name" => "Read", "tool_input" => %{}}, worktree)

    assert File.exists?(Path.join(worktree, ".whiska-mouse"))
  end

  test "a second invocation reuses the same id", %{worktree: worktree} do
    {_, 0} = hook(%{"cwd" => worktree, "tool_name" => "Read", "tool_input" => %{}}, worktree)
    first = File.read!(Path.join(worktree, ".whiska-mouse"))

    {_, 0} = hook(%{"cwd" => worktree, "tool_name" => "Read", "tool_input" => %{}}, worktree)

    assert File.read!(Path.join(worktree, ".whiska-mouse")) == first
  end

  test "a broken house does not stop the rule from being enforced", %{
    main: main,
    worktree: worktree
  } do
    # This is the live situation today, not a contrived one — see the :needs_nif
    # test below. Storage is bookkeeping; the decision must not depend on it.
    {out, 0} =
      hook(
        %{
          "cwd" => worktree,
          "tool_name" => "Write",
          "tool_input" => %{"file_path" => Path.join(main, "CONTEXT.md")}
        },
        worktree
      )

    assert out =~ ~s("permissionDecision":"deny")
  end

  test "opens a real SQLite house from the single-file binary", %{main: main, worktree: worktree} do
    # The escript carries SQLite's native library as embedded bytes and unpacks
    # it on first run (Whiska.BundledNIF) — an escript archive has no priv
    # directory, and native code cannot be loaded out of a zip regardless.
    {_, 0} = hook(%{"cwd" => worktree, "tool_name" => "Read", "tool_input" => %{}}, worktree)

    assert File.exists?(Path.join(main, ".git/whiska/whiska.db"))

    {:ok, conn} = Exqlite.Sqlite3.open(Path.join(main, ".git/whiska/whiska.db"))
    {:ok, statement} = Exqlite.Sqlite3.prepare(conn, "select count(*) from mice")

    try do
      assert {:row, [1]} = Exqlite.Sqlite3.step(conn, statement)
    after
      Exqlite.Sqlite3.release(conn, statement)
      Exqlite.Sqlite3.close(conn)
    end
  end

  test "carries priv/models.json inside the binary, since it carries no priv/", %{main: main} do
    {out, 0} = System.cmd(@binary, ["shape", "--rules"], cd: main)
    assert out == File.read!(Path.expand("../../priv/models.json", __DIR__))
  end

  test "reports its version" do
    {out, status} = System.cmd(@binary, ["--version"])
    assert status == 0
    assert String.trim(out) == "0.0.1"
  end

  # The order ADR-0069 is about: the shape is in the house before Claude starts,
  # so the very first tool call a sniff mouse makes is already a sniff call.
  test "a mouse shaped as sniff before it starts gets no free edit", %{worktree: worktree} do
    {out, 0} =
      System.cmd(@binary, ["shape", "sniff", "--model", "m1", "--effort", "high"],
        cd: worktree,
        stderr_to_stdout: false
      )

    assert out =~ ~r/\A--model m1 --effort high/

    {out, 0} =
      hook(
        %{
          "cwd" => worktree,
          "tool_name" => "Write",
          "tool_input" => %{"file_path" => Path.join(worktree, "lib/x.ex")}
        },
        worktree
      )

    assert out =~ ~s("permissionDecision":"deny")
    # Denied as sniff, not as a mouse nobody shaped.
    assert out =~ "sniff mode"
  end

  test "whiska mode refuses a shaped mouse, and its enforcement does not move", %{
    worktree: worktree
  } do
    {_, 0} = System.cmd(@binary, ["shape", "build"], cd: worktree, stderr_to_stdout: true)

    # build mouse: an edit inside its own worktree is fine
    {out, 0} =
      hook(
        %{
          "cwd" => worktree,
          "tool_name" => "Write",
          "tool_input" => %{"file_path" => Path.join(worktree, "lib/x.ex")}
        },
        worktree
      )

    assert out == ""

    {msg, 1} = System.cmd(@binary, ["mode", "sniff"], cd: worktree, stderr_to_stdout: true)
    assert msg =~ "shaped as build"

    {out, 0} =
      hook(
        %{
          "cwd" => worktree,
          "tool_name" => "Write",
          "tool_input" => %{"file_path" => Path.join(worktree, "lib/x.ex")}
        },
        worktree
      )

    assert out == ""
  end

  test "a build mouse cannot sed into the main checkout", %{main: main, worktree: worktree} do
    {out, 0} =
      hook(
        %{
          "cwd" => worktree,
          "tool_name" => "Bash",
          "tool_input" => %{"command" => "sed -i '' s/a/b/ #{main}/CONTEXT.md"}
        },
        worktree
      )

    assert out =~ ~s("permissionDecision":"deny")
  end

  test "but it can still read the main checkout", %{main: main, worktree: worktree} do
    {out, 0} =
      hook(
        %{
          "cwd" => worktree,
          "tool_name" => "Bash",
          "tool_input" => %{"command" => "cat #{main}/CONTEXT.md"}
        },
        worktree
      )

    assert out == ""
  end
end
