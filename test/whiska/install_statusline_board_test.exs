defmodule Whiska.InstallStatuslineBoardTest do
  @moduledoc """
  The statusline script as bash actually runs it (ADR-0051): it prints the
  board the owl left on disk, and starts nothing.
  """
  use ExUnit.Case, async: false

  alias Whiska.Install
  alias Whiska.Schema.Mouse
  alias Whiska.Schema.Question
  alias Whiska.Watch
  alias Whiska.Watch.Snapshot

  setup do
    root = Path.join(System.tmp_dir!(), "whiska-slb-#{System.unique_integer([:positive])}")
    home = Path.join(root, "home")
    whiska_home = Path.join(home, ".whiska")
    main = Path.join(root, "myrepo")
    script = Path.join(root, "whiska-statusline.sh")

    File.mkdir_p!(Path.join(main, "worktrees/feat-a"))
    File.mkdir_p!(home)
    File.write!(script, Install.statusline_script())
    File.chmod!(script, 0o755)

    previous = Application.get_env(:whiska, :home)
    Application.put_env(:whiska, :home, whiska_home)

    on_exit(fn ->
      Application.put_env(:whiska, :home, previous)
      File.rm_rf!(root)
    end)

    {:ok, root: root, home: home, main: main, script: script}
  end

  defp run(context, cwd, opts \\ [])

  defp run(%{script: script, home: home}, cwd, opts) do
    payload =
      JSON.encode!(%{
        "workspace" => %{
          "current_dir" => cwd,
          "project_dir" => Keyword.get(opts, :project_dir, cwd)
        }
      })

    # Explicitly nil rather than left out: the suite itself runs inside a herdr
    # pane, whose id the command would otherwise inherit.
    pane = [{"HERDR_PANE_ID", Keyword.get(opts, :pane)}]

    {out, status} =
      System.cmd("sh", ["-c", "printf '%s' '#{payload}' | bash #{script}"],
        cd: cwd,
        env: [{"HOME", home}, {"WHISKA_HOME", Path.join(home, ".whiska")}] ++ pane,
        stderr_to_stdout: false
      )

    assert status == 0
    out
  end

  defp board do
    mouse = %Mouse{
      mouse_id: "ma",
      branch: "feat-a",
      path: "/repo/worktrees/feat-a",
      mode: "build",
      created_at: DateTime.utc_now()
    }

    question = %Question{
      id: 52,
      mouse_id: "ma",
      status: "sent",
      kind: "needs-decision",
      text: "Body.\n\nwhich db?\n\u2063\u2063",
      asked_at: DateTime.utc_now()
    }

    pane = %{
      pane_id: "w1:p1",
      cwd: mouse.path,
      agent: "claude",
      agent_status: "working",
      terminal_title_stripped: nil
    }

    Watch.board([mouse],
      questions: [question],
      panes: {:ok, [pane]},
      activity: fn _mouse -> %{action: {:tool, "Edit lib/auth.ex"}, silent_for: 3} end
    )
  end

  defp age_file(path, seconds) do
    File.touch!(path, System.os_time(:second) - seconds)
  end

  test "prints the board the owl wrote for this repo", context do
    :ok = Snapshot.write(context.main, "🐭 feat-a  working  Edit lib/auth.ex")

    assert run(context, context.main) =~ "🐭 feat-a  working  Edit lib/auth.ex"
  end

  test "starts nothing of Whiska's own" do
    script = Install.statusline_script()

    refute script =~ "escript"
    refute script =~ "statusline --here"
  end

  test "a session inside a worktree draws no board", context do
    :ok = Snapshot.write(context.main, "🐭 feat-a  working  Edit lib/auth.ex")

    assert run(context, Path.join(context.main, "worktrees/feat-a")) == ""
  end

  test "finds the board from a subdirectory of the repo", context do
    lib = Path.join(context.main, "lib")
    File.mkdir_p!(lib)
    :ok = Snapshot.write(context.main, "🐭 feat-a  working")

    assert run(context, lib) =~ "🐭 feat-a"
  end

  test "a board a few seconds behind is still drawn as it is", context do
    :ok = Snapshot.write(context.main, "🐭 feat-a  working")
    age_file(Snapshot.path(context.main), 8)

    out = run(context, context.main)

    assert out =~ "🐭 feat-a"
    refute out =~ "stale"
  end

  test "a board going stale says so, and dims what it still shows", context do
    :ok = Snapshot.write(context.main, "🐭 feat-a  working")
    age_file(Snapshot.path(context.main), 40)

    out = run(context, context.main)

    assert out =~ "🦉 owl down · 40s stale"
    assert out =~ "🐭 feat-a"
    assert out =~ "\e[2m"
  end

  test "a stale board stays dim across the row's own colour", context do
    :ok = Snapshot.write(context.main, Watch.render(board(), frame: 1))
    age_file(Snapshot.path(context.main), 40)

    out = run(context, context.main)
    [_owl, row] = out |> String.trim_trailing() |> String.split("\n")

    assert row =~ "\e[33mwaiting on you · #52"
    assert String.starts_with?(row, "\e[2m")
    assert String.ends_with?(row, "\e[0m")
    refute row =~ ~r/\e\[22m(?!\e\[2m)/
  end

  test "a board nobody has touched for a minute is not shown at all", context do
    :ok = Snapshot.write(context.main, "🐭 feat-a  working")
    age_file(Snapshot.path(context.main), 300)

    assert run(context, context.main) == ""
  end

  test "a quiet repo draws nothing", context do
    :ok = Snapshot.write(context.main, "")

    assert run(context, context.main) == ""
  end

  test "a repo the owl has never opened draws nothing", context do
    assert run(context, context.main) == ""
  end

  test "the person's own global statusline still comes first", context do
    settings = Path.join(context.home, ".claude/settings.json")
    File.mkdir_p!(Path.dirname(settings))
    File.write!(settings, JSON.encode!(%{"statusLine" => %{"command" => "printf 'my line'"}}))
    :ok = Snapshot.write(context.main, "🐭 feat-a  working")

    out = run(context, context.main)

    assert [first, second] = String.split(String.trim_trailing(out), "\n")
    assert first == "my line"
    assert second =~ "🐭 feat-a"
  end

  describe "which session is the main session (ADR-0063)" do
    test "the main session's own pane is told nothing", context do
      :ok = Snapshot.write(context.main, "🐭 feat-a  working", "w1:p9")

      out = run(context, context.main, pane: "w1:p9")

      assert out =~ "🐭 feat-a"
      refute out =~ "main session"
    end

    test "any other pane in the repo is told it is not the main session", context do
      :ok = Snapshot.write(context.main, "🐭 feat-a  working", "w1:p9")

      out = run(context, context.main, pane: "w1:p2")

      assert out =~ "not the main session"
      assert out =~ "whiska start"
      assert out =~ "🐭 feat-a"
    end

    test "a repo with no main session recorded says nothing is delivered", context do
      :ok = Snapshot.write(context.main, "🐭 feat-a  working", nil)

      out = run(context, context.main, pane: "w1:p2")

      assert out =~ "no main session"
      assert out =~ "whiska start"
    end

    test "the notice stands on its own when no mouse is running", context do
      :ok = Snapshot.write(context.main, "", "w1:p9")

      assert run(context, context.main, pane: "w1:p2") =~ "not the main session"
    end

    test "a mouse is never told it is missing a main session", context do
      :ok = Snapshot.write(context.main, "🐭 feat-a  working", nil)

      assert run(context, Path.join(context.main, "worktrees/feat-a"), pane: "w1:p1") == ""
    end

    test "a mouse that stepped into the main checkout is still a mouse", context do
      :ok = Snapshot.write(context.main, "🐭 feat-a  working", "w1:p9")

      out =
        run(context, context.main,
          pane: "w1:p1",
          project_dir: Path.join(context.main, "worktrees/feat-a")
        )

      assert out == ""
    end

    test "a pane herdr cannot name is told nothing", context do
      :ok = Snapshot.write(context.main, "🐭 feat-a  working", "w1:p9")

      out = run(context, context.main)

      assert out =~ "🐭 feat-a"
      refute out =~ "main session"
    end

    test "a repo the owl has never opened says nothing either way", context do
      assert run(context, context.main, pane: "w1:p2") == ""
    end

    test "a board going stale still carries the notice", context do
      :ok = Snapshot.write(context.main, "🐭 feat-a  working", "w1:p9")
      age_file(Snapshot.path(context.main), 40)

      out = run(context, context.main, pane: "w1:p2")

      assert out =~ "not the main session"
      assert out =~ "40s stale"
    end
  end

  test "is redrawn often enough to be live" do
    assert Install.statusline_refresh_interval() == 2
  end
end
