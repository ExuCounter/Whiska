defmodule Whiska.CLIWatchTest do
  @moduledoc "`whiska watch` at the binary: the board, printed once."
  # Serial: the code under test opens the house under the one VM-wide name `Whiska.Repo`.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import Mox

  alias Whiska.CLI
  alias Whiska.Herdr.Mock, as: Herdr
  alias Whiska.Watch.Ink
  alias Whiska.Storage

  setup :verify_on_exit!

  setup do
    root = Path.join(System.tmp_dir!(), "whiska-cliwatch-#{System.unique_integer([:positive])}")
    main = Path.join(root, "myrepo")
    File.mkdir_p!(Path.join(main, ".git"))
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, main: main}
  end

  defp seed_mouse(main, id, branch) do
    {:ok, handle} = Storage.open(main, name: :seed)
    path = Path.join(main, "worktrees/#{branch}")
    File.mkdir_p!(path)
    File.write!(Path.join(path, ".git"), "gitdir: #{main}/.git/worktrees/#{branch}\n")
    {:ok, _} = Storage.record_mouse(%{mouse_id: id, path: path, branch: branch})
    Storage.close(handle)
    path
  end

  defp seed_question(main, mouse_id, text) do
    {:ok, handle} = Storage.open(main, name: :seed)

    {:ok, q} =
      Storage.record_question(%{
        mouse_id: mouse_id,
        text: text,
        kind: "needs-decision",
        asked_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    Storage.close(handle)
    q
  end

  defp pane(cwd, status),
    do: %{pane_id: "w1:p1", cwd: cwd, agent: "claude", agent_status: status}

  describe "whiska watch" do
    test "prints a row for each mouse in this house", %{main: main} do
      path = seed_mouse(main, "ma", "feat-a")
      stub(Herdr, :list_panes, fn _ -> {:ok, [pane(path, "working")]} end)

      out = Ink.plain(capture_io(fn -> assert CLI.run(["watch"], main) == 0 end))

      assert out =~ "🐭 feat-a"
      assert out =~ "working"
    end

    test "the board it prints is coloured, piped or not", %{main: main} do
      path = seed_mouse(main, "ma", "feat-a")
      stub(Herdr, :list_panes, fn _ -> {:ok, [pane(path, "working")]} end)

      out = capture_io(fn -> assert CLI.run(["watch"], main) == 0 end)

      assert out =~ "\e[36mfeat-a\e[39m"
    end

    test "a mouse waiting on the person shows its question id", %{main: main} do
      path = seed_mouse(main, "ma", "feat-a")
      q = seed_question(main, "ma", "Body.\n\nwhich db?\n⁣⁣")
      stub(Herdr, :list_panes, fn _ -> {:ok, [pane(path, "idle")]} end)

      out = Ink.plain(capture_io(fn -> assert CLI.run(["watch"], main) == 0 end))

      assert out =~ "waiting on you · ##{q.id}"
      assert out =~ "which db?"
    end

    test "a dead mouse has no row, and what it left is counted as orphaned", %{main: main} do
      seed_mouse(main, "ma", "feat-a")
      seed_question(main, "ma", "Body.\n\npick one\n\u2063\u2063")

      {:ok, handle} = Storage.open(main, name: :seed)
      {:ok, _} = Storage.mark_dead("ma")
      Storage.close(handle)

      stub(Herdr, :list_panes, fn _ -> {:ok, []} end)

      out = Ink.plain(capture_io(fn -> assert CLI.run(["watch"], main) == 0 end))

      refute out =~ "🐭 feat-a"
      refute out =~ "waiting"
      assert out =~ "🐱 1 orphaned (feat-a)"
    end

    test "a stale record for a folder a branch nests under is on neither list", %{main: main} do
      seed_mouse(main, "mstale", "feat")
      nested = seed_mouse(main, "mnested", "feat/checkout-form")
      stub(Herdr, :list_panes, fn _ -> {:ok, [pane(nested, "working")]} end)

      board = Ink.plain(capture_io(fn -> assert CLI.run(["watch"], main) == 0 end))
      mice = capture_io(fn -> assert CLI.run(["mice"], main) == 0 end)

      assert board =~ "🐭 feat/checkout-form"
      refute board =~ "🐭 feat  "
      assert mice =~ "feat/checkout-form"
      refute mice =~ "feat  "
    end

    test "a quiet house prints nothing", %{main: main} do
      stub(Herdr, :list_panes, fn _ -> {:ok, []} end)

      assert Ink.plain(capture_io(fn -> assert CLI.run(["watch"], main) == 0 end)) == ""
    end

    test "is in the usage text" do
      out = ExUnit.CaptureIO.capture_io(fn -> assert CLI.run(["--help"]) == 0 end)

      assert out =~ ~r/^\s+watch\s+\S/m
    end

    test "statusline --here draws no board in a mouse's own session", %{main: main} do
      path = seed_mouse(main, "ma", "feat-a")
      stub(Herdr, :list_panes, fn _ -> {:ok, [pane(path, "working")]} end)

      assert capture_io(fn -> assert CLI.run(["statusline", "--here"], path) == 0 end) == ""
    end

    test "run inside a worktree it still reports that worktree's own house", %{main: main} do
      path = seed_mouse(main, "ma", "feat-a")
      stub(Herdr, :list_panes, fn _ -> {:ok, [pane(path, "working")]} end)

      out = Ink.plain(capture_io(fn -> assert CLI.run(["watch"], path) == 0 end))

      assert out =~ "🐭 feat-a"
    end
  end
end
