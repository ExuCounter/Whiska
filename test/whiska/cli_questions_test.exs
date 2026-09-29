defmodule Whiska.CLIQuestionsTest do
  @moduledoc """
  `whiska statusline`, and the parts of `whiska questions` that delivery's own
  tests do not cover: the orphaned and doorstep sections underneath the list.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import Mox

  alias Whiska.CLI
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

  describe "whiska questions --full — no id to type" do
    test "prints every open question in full, oldest first, with what is not actionable under it",
         %{main: main} do
      %{q1: q1, q2: q2} =
        seed(main, fn ->
          q1 = ask("Recap.\n[worktree-status: needs-decision] pick a cache TTL")
          q2 = ask("The other one.\n[worktree-status: needs-decision] name the flag")
          ask("gone", status: "orphaned")
          %{q1: q1, q2: q2}
        end)

      out = capture_io(fn -> assert CLI.run(["questions", "--full"], main) == 0 end)

      assert out =~ "pick a cache TTL"
      assert out =~ "name the flag"
      assert out =~ ~r/pick a cache TTL.*name the flag/s
      refute out =~ "answer: whiska reply"
      refute out =~ "[worktree-status"
      assert out =~ "feat-a"
      assert out =~ "1 orphaned"
    end

    test "with nothing open it says so, the same as the summary does", %{main: main} do
      out = capture_io(fn -> assert CLI.run(["questions", "--full"], main) == 0 end)
      assert out =~ "🦉 Nothing needs you"
    end

    test "the plain listing and one question by id are unchanged", %{main: main} do
      q = seed(main, fn -> ask("Recap.\n[worktree-status: needs-decision] pick a cache TTL") end)

      listing = capture_io(fn -> assert CLI.run(["questions"], main) == 0 end)
      assert listing =~ ~s(##{q.id}  feat-a  needs a decision · "pick a cache TTL"  \(open\))
      refute listing =~ "answer: whiska reply"

      one = capture_io(fn -> assert CLI.run(["questions", to_string(q.id)], main) == 0 end)
      assert one =~ "feat-a"
      assert one =~ "pick a cache TTL"
      refute one =~ "[worktree-status"
      refute one =~ "answer: whiska reply"
    end

    test "--full is in the usage text" do
      out = capture_io(fn -> assert CLI.run(["--help"]) == 0 end)
      assert out =~ "--full"
    end
  end

  # The owl is found in the real process table (ADR-0031 fakes only herdr), so
  # the CLI tests accept either state and pin the rest; the owl's own logic is
  # tested in Whiska.StatuslineTest with `:owl_pids` pinned.
  @owl ~r/\A🦉 (watching|owl down)/

  defp after_owl(out) do
    assert out =~ @owl
    String.replace(out, @owl, "")
  end

  describe "whiska statusline" do
    setup %{main: main} do
      home = Path.join(Path.dirname(main), "dot-whiska")
      previous = Application.get_env(:whiska, :home)
      Application.put_env(:whiska, :home, home)
      Whiska.OpenHouses.add(main)
      on_exit(fn -> Application.put_env(:whiska, :home, previous) end)
      :ok
    end

    test "prints the machine-wide line and nothing else — two questions in one repo are one whiska",
         %{
           main: main
         } do
      seed(main, fn ->
        ask("a")
        ask("b")
      end)

      out = capture_io(fn -> assert CLI.run(["statusline"], main) == 0 end)
      assert after_owl(out) == " · 🐱 myrepo\n"
    end

    test "one whiska waiting is named by its repo (ADR-0048 note)", %{main: main} do
      seed(main, fn -> ask("[worktree-status: needs-decision] pick one") end)

      out = capture_io(fn -> assert CLI.run(["statusline"], main) == 0 end)
      assert after_owl(out) == " · 🐱 myrepo\n"
    end

    test "prints only the owl when nothing is waiting (ADR-0027 addendum)", %{main: main} do
      out = capture_io(fn -> assert CLI.run(["statusline"], main) == 0 end)
      assert after_owl(out) == "\n"
    end

    test "is not repo-scoped: outside a checkout it prints the same line", %{
      root: root,
      main: main
    } do
      seed(main, fn -> ask("a") end)
      plain = Path.join(root, "plain")
      File.mkdir_p!(plain)

      out = capture_io(fn -> assert CLI.run(["statusline"], plain) == 0 end)
      assert after_owl(out) == " · 🐱 myrepo\n"
    end
  end
end
