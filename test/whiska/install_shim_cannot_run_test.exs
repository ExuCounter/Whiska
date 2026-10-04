defmodule Whiska.InstallShimCannotRunTest do
  @moduledoc """
  The shim when Whiska is set up here and cannot run.

  Claude Code files an exit-0 hook's stderr as a success and never shows it, so
  a shim that fails open with exit 0 fails open in silence: sniff mode and
  containment switch off, and a mouse's last message never reaches the doorstep.
  Exit 1 is shown as a hook error and still lets the call through — measured on
  Claude Code 2.1.285, where a Stop hook exiting 1 also ends the turn without
  looping.

  Loud only where it costs something: a session in a worktree, in a repo whose
  house exists on this machine or with a binary that was found. Anywhere else —
  a repo whose committed hook reached a machine without Whiska, or a session
  outside a worktree, where both hooks are no-ops anyway — stays exit 0.
  """
  use ExUnit.Case, async: true

  alias Whiska.Install

  setup do
    root = Path.join(System.tmp_dir!(), "whiska-shim-#{System.unique_integer([:positive])}")
    main = Path.join(root, "repo")
    worktree = Path.join(main, "worktrees/feat-x")

    File.mkdir_p!(Path.join(main, ".git/worktrees/feat-x"))
    File.mkdir_p!(worktree)
    File.write!(Path.join(worktree, ".git"), "gitdir: #{main}/.git/worktrees/feat-x\n")
    File.write!(Path.join(main, ".git/worktrees/feat-x/commondir"), "../..\n")
    File.write!(Path.join(main, ".git/worktrees/feat-x/HEAD"), "ref: refs/heads/feat-x\n")
    File.write!(Path.join(main, ".git/HEAD"), "ref: refs/heads/main\n")
    File.mkdir_p!(Path.join(main, ".git/refs/heads"))
    File.mkdir_p!(Path.join(main, ".git/objects"))

    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root, main: main, worktree: worktree}
  end

  for scope <- [:repo, :global] do
    describe "#{scope} shim, in a mouse's worktree, house on this machine, no binary" do
      setup %{main: main}, do: File.mkdir_p!(Path.join(main, ".git/whiska")) && :ok

      test "pre-tool-use says so with a non-blocking exit, and still allows", ctx do
        result = run(ctx, unquote(scope), "pre-tool-use", project: ctx.worktree)

        assert result.status == 1
        assert result.out == ""
        assert result.err =~ "whiska: not found"
        assert result.err =~ "sniff mode"
      end

      test "stop says this turn's message was not delivered", ctx do
        result = run(ctx, unquote(scope), "stop", project: ctx.worktree)

        assert result.status == 1
        assert result.err =~ "whiska: not found"
        assert result.err =~ "not delivered"
      end
    end
  end

  describe "stays silent where Whiska cannot cost anything" do
    test "a worktree in a repo with no house: Whiska was never set up here", ctx do
      for hook <- ["pre-tool-use", "stop"] do
        assert %{status: 0, out: ""} = run(ctx, :repo, hook, project: ctx.worktree)
      end
    end

    test "the main checkout, where neither hook has a mouse to speak for", ctx do
      File.mkdir_p!(Path.join(ctx.main, ".git/whiska"))

      for hook <- ["pre-tool-use", "stop"] do
        assert %{status: 0, out: ""} = run(ctx, :repo, hook, project: ctx.main)
      end
    end

    test "the complaint still reaches stderr, which the doctor's probe reads", ctx do
      assert %{status: 0, err: err} = run(ctx, :repo, "stop", project: ctx.main)
      assert err =~ "whiska: not found"
    end
  end

  test "a binary that is found but fails is loud even with no house", ctx do
    whiska = Path.join(ctx.root, "broken-whiska")
    escript = Path.join(ctx.root, "fake-escript")
    File.write!(whiska, "#!/usr/bin/env bash\nexit 127\n")
    File.write!(escript, "#!/usr/bin/env bash\nexec \"$@\"\n")
    File.chmod!(whiska, 0o755)
    File.chmod!(escript, 0o755)

    result =
      run(ctx, :repo, "pre-tool-use", project: ctx.worktree, whiska: whiska, escript: escript)

    assert result.status != 0
  end

  defp run(ctx, scope, hook, opts) do
    shim = Path.join(ctx.root, "whiska-#{scope}.sh")
    File.write!(shim, Install.shim(scope))

    n = System.unique_integer([:positive])
    err_file = Path.join(ctx.root, "err-#{n}.txt")
    payload_file = Path.join(ctx.root, "payload-#{n}.json")
    project = Keyword.fetch!(opts, :project)
    File.write!(payload_file, JSON.encode!(%{"cwd" => project, "tool_name" => "Write"}))

    env = [
      {"CLAUDE_PROJECT_DIR", project},
      {"HOME", ctx.root},
      # An unset WHISKA_BIN would let the shim find a real whiska on PATH, so
      # "not installed" is spelled as a path to nothing, and PATH is cut back
      # to the system's own.
      {"WHISKA_BIN", Keyword.get(opts, :whiska, Path.join(ctx.root, "no-whiska-here"))},
      {"PATH", "/usr/bin:/bin"}
    ]

    env =
      case Keyword.fetch(opts, :escript) do
        {:ok, escript} -> [{"WHISKA_ESCRIPT", escript} | env]
        :error -> env
      end

    {out, status} =
      System.cmd(
        "/bin/bash",
        ["-c", ~s|/bin/bash "#{shim}" #{hook} < "#{payload_file}" 2> "#{err_file}"|],
        env: env,
        cd: project
      )

    %{out: String.trim(out), err: File.read!(err_file), status: status}
  end
end
