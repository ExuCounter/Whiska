defmodule Whiska.CLIWatchTest do
  @moduledoc "`whiska watch` at the binary: the board, printed once."
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import Mox

  alias Whiska.CLI
  alias Whiska.Herdr.Mock, as: Herdr
  alias Whiska.Storage

  setup :set_mox_global
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

      out = capture_io(fn -> assert CLI.run(["watch"], main) == 0 end)

      assert out =~ "🐭 feat-a"
      assert out =~ "working"
    end

    test "a mouse waiting on the person shows its question id", %{main: main} do
      path = seed_mouse(main, "ma", "feat-a")
      q = seed_question(main, "ma", "Body.\n\nwhich db?\n⁣⁣")
      stub(Herdr, :list_panes, fn _ -> {:ok, [pane(path, "idle")]} end)

      out = capture_io(fn -> assert CLI.run(["watch"], main) == 0 end)

      assert out =~ "waiting on you · ##{q.id}"
      assert out =~ "which db?"
    end

    test "a quiet house prints nothing", %{main: main} do
      stub(Herdr, :list_panes, fn _ -> {:ok, []} end)

      assert capture_io(fn -> assert CLI.run(["watch"], main) == 0 end) == ""
    end

    test "is in the usage text" do
      out = ExUnit.CaptureIO.capture_io(fn -> assert CLI.run(["--help"]) == 0 end)

      assert out =~ ~r/^\s+watch\s+\S/m
    end

    test "run inside a worktree it still reports that worktree's own house", %{main: main} do
      path = seed_mouse(main, "ma", "feat-a")
      stub(Herdr, :list_panes, fn _ -> {:ok, [pane(path, "working")]} end)

      out = capture_io(fn -> assert CLI.run(["watch"], path) == 0 end)

      assert out =~ "🐭 feat-a"
    end
  end
end
