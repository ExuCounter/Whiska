defmodule Whiska.InstallShimPromptTest do
  @moduledoc """
  The shim's `user-prompt-submit` path (ADR-next-an-answer-is-taken-not-typed):
  every prompt in every session runs it, so a session with no answer waiting
  must leave in plain shell, before Whiska or Erlang is looked for.

  Everything here runs the real shim with a stub binary standing in for Whiska,
  because the path only exists in shell.
  """
  use ExUnit.Case, async: true

  alias Whiska.Install

  setup do
    root = Path.join(System.tmp_dir!(), "whiska-shimp-#{System.unique_integer([:positive])}")
    worktree = Path.join(root, "repo/worktrees/feat-a")
    admin = Path.join(root, "repo/.git/worktrees/feat-a")
    File.mkdir_p!(worktree)
    File.mkdir_p!(admin)
    File.write!(Path.join(worktree, ".git"), "gitdir: #{admin}\n")
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root, worktree: worktree, admin: admin}
  end

  describe "settings.json" do
    for scope <- [:repo, :global] do
      test "#{scope}: one UserPromptSubmit entry, and it is the shim" do
        assert [entry] = Install.merge(%{}, unquote(scope))["hooks"]["UserPromptSubmit"]
        assert [%{"command" => command}] = entry["hooks"]
        assert command == Install.prompt_command(unquote(scope))
        assert command =~ "user-prompt-submit"
      end
    end

    test "merging twice leaves one entry, and uninstall takes it out" do
      twice = Install.merge(Install.merge(%{}))
      assert length(twice["hooks"]["UserPromptSubmit"]) == 1
      assert Install.unmerge(twice, nil)["hooks"]["UserPromptSubmit"] == []
    end
  end

  for scope <- [:repo, :global] do
    describe "#{scope} shim, the user-prompt-submit path" do
      test "a session outside any worktree never reaches Whiska", %{root: root} do
        assert %{status: 0, called: []} =
                 run(sandbox(root, unquote(scope)), Path.join(root, "repo"))
      end

      test "a worktree with no answer waiting never reaches Whiska", %{
        root: root,
        worktree: worktree
      } do
        assert %{status: 0, called: []} = run(sandbox(root, unquote(scope)), worktree)
      end

      test "a worktree with an answer waiting reaches Whiska, payload intact", %{
        root: root,
        worktree: worktree,
        admin: admin
      } do
        File.write!(Path.join(admin, "whiska-answer"), "")

        assert %{status: 0, called: [call]} = run(sandbox(root, unquote(scope)), worktree)
        assert call.args == ["hook", "user-prompt-submit"]
        assert JSON.decode!(call.stdin)["prompt"] == "hello"
      end

      test "a gitdir written as a relative path is read the same way", %{
        root: root,
        worktree: worktree,
        admin: admin
      } do
        File.write!(Path.join(worktree, ".git"), "gitdir: ../../.git/worktrees/feat-a\n")
        File.write!(Path.join(admin, "whiska-answer"), "")

        assert %{called: [_call]} = run(sandbox(root, unquote(scope)), worktree)
      end

      test "with no project directory to decide on, Whiska decides", %{root: root} do
        assert %{called: [_call]} = run(sandbox(root, unquote(scope)), nil)
      end
    end
  end

  defp sandbox(root, scope) do
    dir = Path.join(root, "sandbox-#{scope}")
    File.mkdir_p!(dir)
    shim = Path.join(dir, "whiska.sh")
    whiska = Path.join(dir, "fake-whiska")
    escript = Path.join(dir, "fake-escript")
    log = Path.join(dir, "calls")

    File.write!(shim, Install.shim(scope))

    File.write!(whiska, """
    #!/usr/bin/env bash
    cat > "#{log}.stdin"
    printf '%s\\n' "$@" > "#{log}"
    """)

    File.write!(escript, """
    #!/usr/bin/env bash
    exec "$@"
    """)

    for f <- [shim, whiska, escript], do: File.chmod!(f, 0o755)
    %{dir: dir, shim: shim, whiska: whiska, escript: escript, log: log}
  end

  defp run(sandbox, project_dir) do
    payload_file = Path.join(sandbox.dir, "payload.json")
    File.write!(payload_file, JSON.encode!(%{"prompt" => "hello", "cwd" => project_dir}))
    File.rm(sandbox.log)

    env = [
      {"CLAUDE_PROJECT_DIR", project_dir},
      {"HOME", sandbox.dir},
      {"WHISKA_ESCRIPT", sandbox.escript},
      {"WHISKA_BIN", sandbox.whiska}
    ]

    {_out, status} =
      System.cmd(
        "bash",
        ["-c", ~s|bash "#{sandbox.shim}" user-prompt-submit < "#{payload_file}" 2>/dev/null|],
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

    %{status: status, called: called}
  end
end
