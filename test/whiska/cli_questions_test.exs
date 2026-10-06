defmodule Whiska.CLIQuestionsTest do
  @moduledoc """
  `whiska statusline`, and the parts of `whiska questions` that delivery's own
  tests do not cover: the orphaned and doorstep sections underneath the list.
  """
  # Serial: the code under test opens the house under the one VM-wide name
  # `Whiska.Repo`, and the tests move the global `:home`.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import Mox

  alias Whiska.CLI
  alias Whiska.Doorstep
  alias Whiska.Doorstep.Entry
  alias Whiska.Test.GitRepo
  alias Whiska.Watch.Ink
  alias Whiska.Storage

  setup :verify_on_exit!

  setup do
    root = Path.join(System.tmp_dir!(), "whiska-cliq-#{System.unique_integer([:positive])}")
    main = Path.join(root, "myrepo")
    worktree = Path.join(main, "worktrees/feat-thing")
    File.mkdir_p!(Path.join(main, ".git"))
    File.mkdir_p!(worktree)
    File.write!(Path.join(worktree, ".git"), "gitdir: #{main}/.git/worktrees/feat-thing\n")
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

    # The finished picker in the `whiska-delivered` skill (ADR-0022) reads the
    # line and runs this, and the owl has closed the report by then.
    test "a finished report reads back by id after it has been closed", %{main: main} do
      q =
        seed(main, fn ->
          report = ask("Merged it.\n[worktree-status: done]", kind: "done")
          {:ok, _} = Storage.mark_sent(report.id)
          {:ok, _} = Storage.close_question(report.id)
          report
        end)

      out = capture_io(fn -> assert CLI.run(["questions", to_string(q.id)], main) == 0 end)
      assert out =~ "feat-a"
      assert out =~ "finished"
      assert out =~ "Merged it."
      assert out =~ "closed"
      assert out =~ "On the branch: unknown"
      refute out =~ "nothing committed"
    end

    # The finished picker in `whiska-delivered` offers a fresh build only for
    # a mouse that could only look, and reads that from this heading — Whiska's
    # record, not the mouse's own word about itself.
    test "a sniff mouse's question names its mode in the heading", %{main: main} do
      q =
        seed(main, fn ->
          {:ok, _} = Storage.shape("m1", "sniff", nil, nil)
          ask("Found it.\n[worktree-status: done]", kind: "done")
        end)

      one = capture_io(fn -> assert CLI.run(["questions", to_string(q.id)], main) == 0 end)
      assert one =~ "##{q.id}  feat-a (sniff)  finished"

      full = capture_io(fn -> assert CLI.run(["questions", "--full"], main) == 0 end)
      assert full =~ "##{q.id}  feat-a (sniff)  finished"
    end

    test "a build mouse's heading names the branch alone", %{main: main} do
      q =
        seed(main, fn ->
          {:ok, _} = Storage.shape("m1", "build", nil, nil)
          ask("Merged it.\n[worktree-status: done]", kind: "done")
        end)

      one = capture_io(fn -> assert CLI.run(["questions", to_string(q.id)], main) == 0 end)
      assert one =~ "##{q.id}  feat-a  finished"
    end

    test "--full is in the usage text" do
      out = capture_io(fn -> assert CLI.run(["--help"]) == 0 end)
      assert out =~ "--full"
    end
  end

  # The finished picker in `whiska-delivered` offers a landing only when this
  # line says there is something to land.
  describe "whiska show — what a finished question's branch holds" do
    setup do
      root = Path.join(System.tmp_dir!(), "whiska-onbranch-#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf!(root) end)
      {:ok, repo: GitRepo.create(root)}
    end

    defp finished(repo, branch, opts \\ []) do
      path = GitRepo.worktree(repo, branch, push: false, commit: Keyword.get(opts, :commit, true))
      Enum.each(Keyword.get(opts, :files, []), &File.write!(Path.join(path, &1), "unsaved"))
      if opts[:gone], do: File.rm_rf!(path)

      {:ok, handle} = Storage.open(repo.checkout)

      try do
        {:ok, _} = Storage.record_mouse(%{mouse_id: "m-#{branch}", path: path, branch: branch})

        {:ok, q} =
          Storage.record_question(%{
            mouse_id: "m-#{branch}",
            text: "Done.\n⁣⁣⁣",
            kind: Keyword.get(opts, :kind, "done"),
            status: Keyword.get(opts, :status, "closed")
          })

        q
      after
        Storage.close(handle)
      end
    end

    defp show(repo, args) do
      capture_io(fn -> assert CLI.run(["show" | args], repo.checkout) == 0 end)
    end

    defp show_one(repo, %{id: id}), do: show(repo, [to_string(id)])

    test "commits of its own and nothing uncommitted", %{repo: repo} do
      q = finished(repo, "feat-a")

      assert show_one(repo, q) =~
               ~r/^##{q.id}  feat-a  finished  \(closed, asked [^)]+\)\nOn the branch: 1 commit beyond main · nothing uncommitted\n\nDone\./
    end

    test "an untracked file is uncommitted work, and nothing committed is said so",
         %{repo: repo} do
      q = finished(repo, "fix-b", commit: false, files: ["timeout_test.exs"])

      assert show_one(repo, q) =~
               "On the branch: nothing committed beyond main · 1 file not committed: timeout_test.exs"
    end

    test "commits beside uncommitted files", %{repo: repo} do
      q = finished(repo, "feat-c", files: ["a.txt", "b.txt"])

      assert show_one(repo, q) =~
               "On the branch: 1 commit beyond main · 2 files not committed: a.txt, b.txt"
    end

    test "names the first three uncommitted files and counts the rest", %{repo: repo} do
      q = finished(repo, "feat-d", commit: false, files: ~w(a.txt b.txt c.txt d.txt e.txt))

      assert show_one(repo, q) =~ "5 files not committed: a.txt, b.txt, c.txt and 2 more"
    end

    test "a branch with nothing on it", %{repo: repo} do
      q = finished(repo, "ask-e", commit: false)

      assert show_one(repo, q) =~
               "On the branch: nothing committed beyond main · nothing uncommitted"
    end

    # Land here skips merges from the base, so they are nothing to land.
    test "a merge from the base is not a commit of its own", %{repo: repo} do
      q = finished(repo, "feat-f", commit: false)
      path = Path.join([repo.root, "worktrees", "feat-f"])
      GitRepo.commit!(repo.checkout, "later.md", "moved on")
      GitRepo.git!(path, ["merge", "--no-ff", "-m", "sync", "main"])

      assert show_one(repo, q) =~ "nothing committed beyond main"
    end

    test "a worktree that is gone is unknown, never empty", %{repo: repo} do
      q = finished(repo, "feat-g", commit: false, gone: true)
      out = show_one(repo, q)

      assert out =~ "On the branch: unknown — its worktree is gone"
      refute out =~ "nothing committed"
    end

    test "no base branch to compare with is unknown, never empty", %{repo: repo} do
      q = finished(repo, "feat-h", commit: false)
      GitRepo.git!(repo.checkout, ["remote", "remove", "origin"])
      GitRepo.git!(repo.checkout, ["branch", "-m", "main", "trunk"])
      out = show_one(repo, q)

      assert out =~ "On the branch: unknown"
      refute out =~ "nothing committed"
    end

    test "a staged rename is one uncommitted file, under its new name", %{repo: repo} do
      q = finished(repo, "feat-l")
      GitRepo.git!(Path.join([repo.root, "worktrees", "feat-l"]), ["mv", "feat-l.md", "moved.md"])

      assert show_one(repo, q) =~ "1 commit beyond main · 1 file not committed: moved.md"
    end

    test "an untracked file counts even where git is told to hide them", %{repo: repo} do
      q = finished(repo, "fix-m", commit: false, files: ["timeout_test.exs"])
      path = Path.join([repo.root, "worktrees", "fix-m"])
      GitRepo.git!(path, ["config", "status.showUntrackedFiles", "no"])

      assert show_one(repo, q) =~ "1 file not committed: timeout_test.exs"
    end

    test "a worktree moved off its recorded branch is unknown, never empty", %{repo: repo} do
      q = finished(repo, "feat-n", commit: false)
      path = Path.join([repo.root, "worktrees", "feat-n"])
      GitRepo.git!(path, ["switch", "-c", "elsewhere"])
      GitRepo.commit!(path, "lost.md", "work on another branch")
      out = show_one(repo, q)

      assert out =~ "On the branch: unknown — its worktree is not on its branch"
      refute out =~ "nothing committed"
    end

    test "a detached head is unknown, never empty", %{repo: repo} do
      q = finished(repo, "feat-s", commit: false)
      path = Path.join([repo.root, "worktrees", "feat-s"])
      GitRepo.git!(path, ["switch", "--detach"])
      GitRepo.commit!(path, "loose.md", "work on no branch")

      assert show_one(repo, q) =~ "On the branch: unknown — its worktree is not on its branch"
    end

    test "a base branch named like an option is unknown", %{repo: repo} do
      q = finished(repo, "feat-t", commit: false)
      GitRepo.git!(repo.checkout, ["update-ref", "refs/remotes/origin/-x", "HEAD"])

      GitRepo.git!(repo.checkout, [
        "symbolic-ref",
        "refs/remotes/origin/HEAD",
        "refs/remotes/origin/-x"
      ])

      assert show_one(repo, q) =~
               "On the branch: unknown — its base branch's name is not a plain one"
    end

    test "a folder git cannot read is unknown, never a crash", %{repo: repo} do
      q = finished(repo, "feat-o", commit: false)
      locked = Path.join([repo.root, "worktrees", "feat-o", "locked"])
      File.mkdir_p!(Path.join(locked, "inner"))
      File.chmod!(locked, 0o000)
      on_exit(fn -> File.chmod(locked, 0o755) end)

      # Root reads a 0o000 folder anyway, and then there is nothing to show.
      case File.ls(locked) do
        {:ok, _readable} ->
          :ok

        {:error, _} ->
          assert show_one(repo, q) =~ "On the branch: unknown — git could not read it"
      end
    end

    test "a path's invisible and line-breaking characters cannot bend the line",
         %{repo: repo} do
      q = finished(repo, "feat-p", commit: false, files: ["a\u2028b\u202Ec.txt"])

      assert show_one(repo, q) =~ "1 file not committed: a?b?c.txt\n"
    end

    test "a path that is not valid UTF-8 is shown, not crashed on", %{repo: repo} do
      q = finished(repo, "feat-q", commit: false)
      path = Path.join([repo.root, "worktrees", "feat-q"])
      blob = path |> GitRepo.git!(["hash-object", "-w", "README.md"]) |> String.trim()
      GitRepo.git!(path, ["update-index", "--add", "--cacheinfo", "100644,#{blob},x\xFFy"])

      assert show_one(repo, q) =~ "1 file not committed: x?y\n"
    end

    test "a base branch whose name could run as shell is unknown", %{repo: repo} do
      q = finished(repo, "feat-r", commit: false)
      GitRepo.git!(repo.checkout, ["branch", "$(touch-pwned)"])

      GitRepo.git!(repo.checkout, [
        "symbolic-ref",
        "refs/remotes/origin/HEAD",
        "refs/remotes/origin/$(touch-pwned)"
      ])

      out = show_one(repo, q)
      assert out =~ "On the branch: unknown — its base branch's name is not a plain one"
      refute out =~ "$(touch-pwned)"
    end

    test "a question that did not finish says nothing about the branch", %{repo: repo} do
      q = finished(repo, "feat-i", kind: "needs-decision", status: "open")

      refute show_one(repo, q) =~ "On the branch"
    end

    test "every finished block of the full listing carries the same line", %{repo: repo} do
      q = finished(repo, "feat-j", commit: false, status: "open")

      assert show(repo, []) =~
               ~r/##{q.id}  feat-j  finished  \([^)]+\)\nOn the branch: nothing committed beyond main · nothing uncommitted\n/
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

  describe "whiska statusline --here — the board this repo draws (ADR-0051)" do
    setup do
      stub(Whiska.Herdr.Mock, :list_panes, fn _ -> {:ok, []} end)
      :ok
    end

    test "gives the mouse a row, with what it is waiting on", %{main: main} do
      seed(main, fn -> ask("Body.\n\npick one\n\u2063\u2063") end)

      out = Ink.plain(capture_io(fn -> assert CLI.run(["statusline", "--here"], main) == 0 end))

      assert out =~ "🐭 feat-a"
      assert out =~ "waiting on you · #1 · \"pick one\""
    end

    test "says nothing at all when this repo is quiet", %{main: main} do
      out = Ink.plain(capture_io(fn -> assert CLI.run(["statusline", "--here"], main) == 0 end))
      assert out == ""
    end

    test "a mouse's own session draws no board", %{main: main, worktree: worktree} do
      seed(main, fn -> ask("a") end)

      out = capture_io(fn -> assert CLI.run(["statusline", "--here"], worktree) == 0 end)
      assert out == ""
    end

    test "outside a checkout it says nothing and still exits 0", %{root: root} do
      plain = Path.join(root, "plain")
      File.mkdir_p!(plain)

      out = capture_io(fn -> assert CLI.run(["statusline", "--here"], plain) == 0 end)
      assert out == ""
    end

    test "is in the usage text" do
      out = capture_io(fn -> assert CLI.run(["--help"]) == 0 end)
      assert out =~ "statusline --here"
    end
  end
end
