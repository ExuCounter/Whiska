defmodule Whiska.CLIQuestionsTest do
  @moduledoc """
  `whiska statusline`, and the parts of `whiska questions` that delivery's own
  tests do not cover: the orphaned and doorstep sections underneath the list.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import Mox

  alias Whiska.CLI
  alias Whiska.Herdr.Mock, as: Herdr
  alias Whiska.Doorstep
  alias Whiska.Doorstep.Entry
  alias Whiska.Storage

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    root = Path.join(System.tmp_dir!(), "whiska-cliq-#{System.unique_integer([:positive])}")
    main = Path.join(root, "myrepo")
    worktree = Path.join(main, "worktrees/feat-thing")
    File.mkdir_p!(Path.join(main, ".git"))
    File.mkdir_p!(worktree)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root, main: main, worktree: worktree}
  end

  defp seed(main, fun) do
    {:ok, handle} = Storage.open(main)
    {:ok, _} = Storage.record_mouse(%{mouse_id: "m1", path: "/w/a", branch: "feat-a"})
    result = fun.()
    Storage.close(handle)
    result
  end

  defp ask(text, opts \\ []) do
    {:ok, q} =
      Storage.record_question(%{
        mouse_id: "m1",
        text: text,
        kind: Keyword.get(opts, :kind, "needs-decision"),
        status: Keyword.get(opts, :status, "open")
      })

    q
  end

  describe "whiska questions — beneath the list" do
    test "shows orphaned questions apart and what is still on the doorstep", %{main: main} do
      seed(main, fn ->
        ask("live")
        ask("gone", status: "orphaned")
      end)

      {:ok, _} =
        Doorstep.leave(main, %Entry{
          mouse_id: "m1",
          branch: "feat-a",
          worktree_root: "/w/a",
          stamped_at: DateTime.utc_now(),
          text: "uncollected"
        })

      out = capture_io(fn -> assert CLI.run(["questions"], main) == 0 end)
      assert out =~ ~s("live"  \(open\))
      assert out =~ "1 orphaned"
      assert out =~ "1 on the doorstep"
    end

    test "is in the usage text, beside statusline" do
      out = capture_io(fn -> assert CLI.run(["--help"]) == 0 end)
      assert out =~ "questions"
      assert out =~ "statusline"
    end
  end

  describe "whiska statusline" do
    test "prints the segment and nothing else", %{main: main} do
      stub(Herdr, :list_panes, fn _ -> {:ok, []} end)

      seed(main, fn ->
        ask("a")
        ask("b")
      end)

      out = capture_io(fn -> assert CLI.run(["statusline"], main) == 0 end)
      assert out == "🐱 2 questions waiting\n"
    end

    test "counts the mice herdr sees in this repo's worktrees", %{main: main, worktree: worktree} do
      stub(Herdr, :list_panes, fn _ ->
        {:ok, [%{pane_id: "p1", cwd: worktree, agent: "claude", agent_status: "working"}]}
      end)

      out = capture_io(fn -> assert CLI.run(["statusline"], main) == 0 end)
      assert out == "🐭 1 mouse\n"
    end

    test "reads the same house from a worktree", %{main: main, worktree: worktree} do
      stub(Herdr, :list_panes, fn _ -> {:ok, []} end)
      seed(main, fn -> ask("[worktree-status: needs-decision] pick one") end)

      out = capture_io(fn -> assert CLI.run(["statusline"], worktree) == 0 end)
      assert out == "🐱 feat-a: pick one\n"
    end

    test "prints nothing when nothing is waiting, so the line stays clean", %{main: main} do
      stub(Herdr, :list_panes, fn _ -> {:ok, []} end)
      out = capture_io(fn -> assert CLI.run(["statusline"], main) == 0 end)
      assert out == ""
    end

    test "prints nothing outside a checkout, and still exits 0", %{root: root} do
      plain = Path.join(root, "plain")
      File.mkdir_p!(plain)
      out = capture_io(fn -> assert CLI.run(["statusline"], plain) == 0 end)
      assert out == ""
    end
  end
end
