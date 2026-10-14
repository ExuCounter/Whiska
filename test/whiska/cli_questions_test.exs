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
      assert out =~ "branch unknown"
      refute out =~ "nothing committed"
    end

    # Whiska's record of the mode, not the mouse's word about itself.
    test "a sniff mouse's question names its mode on the mouse line", %{main: main} do
      q =
        seed(main, fn ->
          {:ok, _} = Storage.shape("m1", "sniff", nil, nil)
          ask("Found it.\n[worktree-status: done]", kind: "done")
        end)

      one = capture_io(fn -> assert CLI.run(["questions", to_string(q.id)], main) == 0 end)
      assert one =~ "mouse: feat-a (sniff)\n"

      full = capture_io(fn -> assert CLI.run(["questions", "--full"], main) == 0 end)
      assert full =~ "mouse: feat-a (sniff)\n"
    end

    test "a build mouse's question names its mode too", %{main: main} do
      q =
        seed(main, fn ->
          {:ok, _} = Storage.shape("m1", "build", nil, nil)
          ask("Merged it.\n[worktree-status: done]", kind: "done")
        end)

      one = capture_io(fn -> assert CLI.run(["questions", to_string(q.id)], main) == 0 end)
      assert one =~ "mouse: feat-a (build)\n"
    end
  end

  describe "whiska show — what a finished question's branch holds" do
    setup do
      root = Path.join(System.tmp_dir!(), "whiska-onbranch-#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf!(root) end)
      {:ok, repo: GitRepo.create(root)}
    end

    defp finished(repo, branch, opts \\ []) do
      path =
        GitRepo.worktree(repo, branch,
          push: Keyword.get(opts, :push, false),
          commit: Keyword.get(opts, :commit, true)
        )

      Enum.each(Keyword.get(opts, :files, []), &File.write!(Path.join(path, &1), "unsaved"))
      if opts[:gone], do: File.rm_rf!(path)

      {:ok, handle} = Storage.open(repo.checkout)

      try do
        {:ok, _} =
          Storage.record_mouse(%{
            mouse_id: "m-#{branch}",
            path: path,
            branch: branch,
            base: opts[:base]
          })

        if url = opts[:merge_request],
          do: {:ok, _} = Storage.record_merge_request("m-#{branch}", url)

        {:ok, q} =
          Storage.record_question(%{
            mouse_id: "m-#{branch}",
            text: "Done.\n⁣⁣⁣",
            kind: Keyword.get(opts, :kind, "done"),
            status: Keyword.get(opts, :status, "closed"),
            asked_at: opts[:asked_at]
          })

        q
      after
        Storage.close(handle)
      end
    end

    # Kept the way the owl keeps it at collection: one file per branch.
    defp keep_research(repo, q, text) do
      entry = %Entry{
        mouse_id: q.mouse_id,
        branch: String.replace_prefix(q.mouse_id, "m-", ""),
        worktree_root: repo.checkout,
        stamped_at: ~U[2026-10-06 09:00:00Z],
        text: "",
        research: text
      }

      :kept = Whiska.SpecArchive.keep_research(repo.checkout, entry, q)
    end

    defp review_file(repo, branch), do: Whiska.Review.file(repo.checkout, branch)

    defp research_file(repo, branch),
      do: "file://#{repo.checkout}/.whiska/specs/2026-10-06-#{branch}.research.md"

    defp ask_again(repo, branch) do
      {:ok, handle} = Storage.open(repo.checkout)

      try do
        {:ok, q} =
          Storage.record_question(%{
            mouse_id: "m-#{branch}",
            text: "Done again.\n⁣⁣⁣",
            kind: "done",
            status: "closed"
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
               ~r/\Amouse: feat-a \(build\)\nquestion: #\d+ · finished\nstate: closed\nage: \S+\nbranch: 1 commit, clean\nDiff: \S+\n\nDone\./
    end

    test "a report from an earlier day says its age", %{repo: repo} do
      q = finished(repo, "feat-y", asked_at: ~U[2026-09-01 12:00:00Z])
      shown = show_one(repo, q)

      assert shown =~
               ~r/\nage: \d+d\nbranch: 1 commit, clean\n/
    end

    test "its diff is a patch file beside the kept specs, linked on its own line",
         %{repo: repo} do
      q = finished(repo, "feat-d")
      review = review_file(repo, "feat-d")

      assert Path.extname(review) == ".diff"
      assert show_one(repo, q) =~ "\nDiff: file://#{review}\n"

      assert File.read!(review) ==
               GitRepo.git!(repo.checkout, [
                 "diff",
                 "--no-color",
                 "main...refs/heads/feat-d",
                 "--"
               ])

      assert File.read!(Path.join(repo.checkout, ".git/info/exclude")) =~ "/.whiska/"
    end

    test "WHISKA_DIFF_LINK set makes no difference: the link is the file's", %{repo: repo} do
      q = finished(repo, "feat-d")
      previous = System.get_env("WHISKA_DIFF_LINK")
      System.put_env("WHISKA_DIFF_LINK", "hunk-review://{base}..{branch}")

      try do
        assert show_one(repo, q) =~ "\nDiff: file://#{review_file(repo, "feat-d")}\n"
      after
        if previous,
          do: System.put_env("WHISKA_DIFF_LINK", previous),
          else: System.delete_env("WHISKA_DIFF_LINK")
      end
    end

    test "a base the main checkout holds only from origin is diffed from there",
         %{repo: repo} do
      GitRepo.git!(repo.checkout, ["checkout", "-b", "staging"])
      GitRepo.commit!(repo.checkout, "s1.md", "staging work")
      GitRepo.git!(repo.checkout, ["push", "-u", "origin", "staging"])
      q = finished(repo, "feat-o", base: "staging")
      GitRepo.git!(repo.checkout, ["checkout", "main"])
      GitRepo.git!(repo.checkout, ["branch", "-D", "staging"])

      assert show_one(repo, q) =~ "\nDiff: file://#{review_file(repo, "feat-o")}\n"
      diff = File.read!(review_file(repo, "feat-o"))
      assert diff =~ "+++ b/feat-o.md"
      refute diff =~ "s1.md"
    end

    test "commits that change nothing between them leave no diff to link, and no old one",
         %{repo: repo} do
      q = finished(repo, "feat-n")
      assert show_one(repo, q) =~ "\nDiff: "
      GitRepo.git!(Path.join(repo.root, "worktrees/feat-n"), ["revert", "--no-edit", "HEAD"])

      refute show_one(repo, q) =~ "Diff"
      refute File.exists?(review_file(repo, "feat-n"))
    end

    test "read from another mouse's worktree, a finished branch still links its diff",
         %{repo: repo} do
      q = finished(repo, "feat-w")
      worktree = Path.join(repo.checkout, "worktrees/elsewhere")
      GitRepo.git!(repo.checkout, ["worktree", "add", "-b", "elsewhere", worktree])

      out = capture_io(fn -> assert CLI.run(["show", to_string(q.id)], worktree) == 0 end)

      assert out =~
               "\nDiff: file://#{review_file(repo, "feat-w")}\n"

      assert File.read!(review_file(repo, "feat-w")) =~ "+++ b/feat-w.md"
    end

    test "a kept research document is linked on its own line", %{repo: repo} do
      q = finished(repo, "ask-w1", commit: false)
      keep_research(repo, q, "# Why the owl hangs\n\nFound.\n")

      assert show_one(repo, q) =~
               "branch: nothing committed, clean\n" <>
                 "Research: #{research_file(repo, "ask-w1")}\n\nDone."
    end

    test "the research document is linked when read from a mouse's worktree too", %{repo: repo} do
      q = finished(repo, "ask-w2", commit: false)
      keep_research(repo, q, "No heading here.\n")
      worktree = Path.join(repo.checkout, "worktrees/reader")
      GitRepo.git!(repo.checkout, ["worktree", "add", "-b", "reader", worktree])

      out = capture_io(fn -> assert CLI.run(["show", to_string(q.id)], worktree) == 0 end)

      assert out =~
               "\nResearch: #{research_file(repo, "ask-w2")}\n"
    end

    test "a research document still links once its worktree is gone", %{repo: repo} do
      q = finished(repo, "ask-w3", commit: false, gone: true)
      keep_research(repo, q, "# Found [it]\n")

      assert show_one(repo, q) =~
               ~r/\nbranch: branch unknown[^\n]*\nResearch: file:/
    end

    test "a finished question with no research document has no research document link", %{
      repo: repo
    } do
      q = finished(repo, "ask-w4", commit: false)
      refute show_one(repo, q) =~ "research"
    end

    test "nothing committed has no diff to review", %{repo: repo} do
      q = finished(repo, "ask-n", commit: false)

      refute show_one(repo, q) =~ "Diff"
      refute File.exists?(review_file(repo, "ask-n"))
    end

    test "an earlier question links the same diff file as the latest, rewritten from the branch",
         %{repo: repo} do
      first = finished(repo, "feat-r")
      second = ask_again(repo, "feat-r")
      link = "Diff: file://#{review_file(repo, "feat-r")}\n"

      assert show_one(repo, second) =~ link
      assert show_one(repo, first) =~ link
      assert [_one] = Path.wildcard(Path.join(repo.checkout, ".whiska/reviews/*"))
    end

    test "an earlier question links the branch's one research document, holding the latest round",
         %{repo: repo} do
      first = finished(repo, "ask-r", commit: false)
      keep_research(repo, first, "# Draft\n")
      second = ask_again(repo, "ask-r")
      keep_research(repo, second, "# Final\n")

      for q <- [first, second] do
        assert show_one(repo, q) =~
                 "\nResearch: #{research_file(repo, "ask-r")}\n"
      end
    end

    test "a question from before research was kept per branch still links its own copy",
         %{repo: repo} do
      q = finished(repo, "ask-old", commit: false)
      old = Path.join(repo.checkout, ".whiska/research/#{q.id}.md")
      File.mkdir_p!(Path.dirname(old))
      File.write!(old, "# Older\n")

      assert show_one(repo, q) =~ "\nResearch: file://#{old}\n"
    end

    # The main checkout works on staging, which is ahead of main; a mouse cut
    # from it that committed nothing has nothing to land.
    defp on_staging(repo) do
      GitRepo.git!(repo.checkout, ["checkout", "-b", "staging"])
      GitRepo.commit!(repo.checkout, "s1.md", "staging work")
      GitRepo.commit!(repo.checkout, "s2.md", "staging work")
    end

    test "is counted beyond the branch the worktree was cut from, not main", %{repo: repo} do
      on_staging(repo)
      q = finished(repo, "ask-s", commit: false, base: "staging")

      assert show_one(repo, q) =~
               "nothing committed beyond staging, clean"
    end

    test "whiska shape records the branch the main checkout is on as the base", %{repo: repo} do
      on_staging(repo)
      # Where `Layout` looks for a worktree: under the main checkout.
      path = Path.join(repo.checkout, "worktrees/ask-v")
      GitRepo.git!(repo.checkout, ["worktree", "add", "-b", "ask-v", path])

      capture_io(:stderr, fn ->
        capture_io(fn -> assert CLI.run(["shape", "build"], path) == 0 end)
      end)

      {:ok, id} = Whiska.Marker.read_or_mint(path)
      {:ok, handle} = Storage.open(repo.checkout)

      try do
        assert Storage.mouse(id).base == "staging"
      after
        Storage.close(handle)
      end
    end

    test "whiska base prints the recorded base, or the default without one", %{repo: repo} do
      on_staging(repo)
      path = Path.join(repo.checkout, "worktrees/ask-w")
      GitRepo.git!(repo.checkout, ["worktree", "add", "-b", "ask-w", path])

      capture_io(:stderr, fn ->
        capture_io(fn -> assert CLI.run(["shape", "build"], path) == 0 end)
      end)

      assert capture_io(fn -> assert CLI.run(["base"], path) == 0 end) == "staging\n"

      GitRepo.git!(repo.checkout, ["checkout", "main"])
      GitRepo.git!(repo.checkout, ["branch", "-D", "staging"])

      stderr = capture_io(:stderr, fn -> assert CLI.run(["base"], path) == 1 end)
      assert stderr =~ "its base branch staging is gone"

      other = Path.join(repo.checkout, "worktrees/ask-x")
      GitRepo.git!(repo.checkout, ["worktree", "add", "-b", "ask-x", other])
      assert capture_io(fn -> assert CLI.run(["base"], other) == 0 end) == "main\n"
    end

    test "a mouse with no recorded base is still counted beyond main", %{repo: repo} do
      on_staging(repo)
      q = finished(repo, "ask-t", commit: false)

      assert show_one(repo, q) =~ "2 commits, clean"
    end

    test "a recorded base that is gone is unknown, never main", %{repo: repo} do
      q = finished(repo, "ask-u", commit: false, base: "staging")

      assert show_one(repo, q) =~ "branch unknown — its base branch staging is gone"
    end

    test "an untracked file is uncommitted work, and nothing committed is said so",
         %{repo: repo} do
      q = finished(repo, "fix-b", commit: false, files: ["timeout_test.exs"])

      assert show_one(repo, q) =~
               "nothing committed, 1 file not committed: timeout_test.exs"
    end

    test "commits beside uncommitted files", %{repo: repo} do
      q = finished(repo, "feat-c", files: ["a.txt", "b.txt"])

      assert show_one(repo, q) =~
               "1 commit, 2 files not committed: a.txt, b.txt"
    end

    test "names the first three uncommitted files and counts the rest", %{repo: repo} do
      q = finished(repo, "feat-d", commit: false, files: ~w(a.txt b.txt c.txt d.txt e.txt))

      assert show_one(repo, q) =~ "5 files not committed: a.txt, b.txt, c.txt and 2 more"
    end

    test "a branch with nothing on it", %{repo: repo} do
      q = finished(repo, "ask-e", commit: false)

      assert show_one(repo, q) =~
               "nothing committed, clean"
    end

    # Land here skips merges from the base, so they are nothing to land.
    test "a merge from the base is not a commit of its own", %{repo: repo} do
      q = finished(repo, "feat-f", commit: false)
      path = Path.join([repo.root, "worktrees", "feat-f"])
      GitRepo.commit!(repo.checkout, "later.md", "moved on")
      GitRepo.git!(path, ["merge", "--no-ff", "-m", "sync", "main"])

      assert show_one(repo, q) =~ "nothing committed, clean"
    end

    test "a worktree that is gone is unknown, never empty", %{repo: repo} do
      q = finished(repo, "feat-g", commit: false, gone: true)
      out = show_one(repo, q)

      assert out =~ "branch unknown — its worktree is gone"
      refute out =~ "nothing committed"
    end

    test "no base branch to compare with is unknown, never empty", %{repo: repo} do
      q = finished(repo, "feat-h", commit: false)
      GitRepo.git!(repo.checkout, ["remote", "remove", "origin"])
      GitRepo.git!(repo.checkout, ["branch", "-m", "main", "trunk"])
      out = show_one(repo, q)

      assert out =~ "branch unknown"
      refute out =~ "nothing committed"
    end

    test "a staged rename is one uncommitted file, under its new name", %{repo: repo} do
      q = finished(repo, "feat-l")
      GitRepo.git!(Path.join([repo.root, "worktrees", "feat-l"]), ["mv", "feat-l.md", "moved.md"])

      assert show_one(repo, q) =~ "1 commit, 1 file not committed: moved.md"
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

      assert out =~ "branch unknown — its worktree is not on its branch"
      refute out =~ "nothing committed"
    end

    test "a detached head is unknown, never empty", %{repo: repo} do
      q = finished(repo, "feat-s", commit: false)
      path = Path.join([repo.root, "worktrees", "feat-s"])
      GitRepo.git!(path, ["switch", "--detach"])
      GitRepo.commit!(path, "loose.md", "work on no branch")

      assert show_one(repo, q) =~ "branch unknown — its worktree is not on its branch"
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
               "branch unknown — its base branch's name is not a plain one"
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
          assert show_one(repo, q) =~ "branch unknown — git could not read it"
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
      assert out =~ "branch unknown — its base branch's name is not a plain one"
      refute out =~ "$(touch-pwned)"
    end

    test "a question that did not finish says nothing about the branch", %{repo: repo} do
      q = finished(repo, "feat-i", kind: "needs-decision", status: "open")

      refute show_one(repo, q) =~ "branch unknown"
      refute show_one(repo, q) =~ "clean"
    end

    test "every finished block of the full listing carries the same line", %{repo: repo} do
      q = finished(repo, "feat-j", commit: false, status: "open")

      full = capture_io(fn -> assert CLI.run(["questions", "--full"], repo.checkout) == 0 end)

      assert full =~
               ~r/mouse: feat-j \(build\)\nquestion: #\d+ · finished\nstate: open\nage: \S+\nbranch: nothing committed, clean\n/
    end

    @pr "https://github.com/o/r/pull/12"

    test "a merge request opened: what is not pushed, and its link",
         %{repo: repo} do
      q = finished(repo, "feat-m", merge_request: @pr)

      assert show_one(repo, q) =~
               ~r/\nbranch: merge request opened, 1 commit not pushed, clean\nMerge request: #{Regex.escape(@pr)}\nDiff: /
    end

    test "a merge request with everything pushed says so", %{repo: repo} do
      q = finished(repo, "feat-n", merge_request: @pr, push: true)

      assert show_one(repo, q) =~
               "\nbranch: merge request opened, everything pushed, clean\n"
    end

    test "a merge request's files not committed are named as on any branch line", %{repo: repo} do
      q = finished(repo, "feat-p", merge_request: @pr, push: true, files: ["a.txt"])

      assert show_one(repo, q) =~
               "\nbranch: merge request opened, everything pushed, 1 file not committed: a.txt\n"
    end

    # The base's own commits travel with the branch but are the base's to push.
    test "a commit the base has not pushed is not the merge request's", %{repo: repo} do
      GitRepo.commit!(repo.checkout, "local.md", "not pushed yet")
      q = finished(repo, "feat-q", merge_request: @pr)

      assert show_one(repo, q) =~ "merge request opened, 1 commit not pushed,"
    end

    test "a merge request already merged reads as any branch, so new commits can land",
         %{repo: repo} do
      q = finished(repo, "feat-s", merge_request: @pr)
      {:ok, handle} = Storage.open(repo.checkout)
      {:ok, _} = Storage.mark_landed("m-feat-s")
      Storage.close(handle)

      shown = show_one(repo, q)

      assert shown =~ "\nbranch: 1 commit, clean\n"
      refute shown =~ "Merge request:"
    end

    test "a merge request merged on the forge and fetched leaves nothing beyond the base",
         %{repo: repo} do
      q = finished(repo, "feat-u", merge_request: @pr, push: true)
      GitRepo.merge_on_forge(repo, "feat-u")
      :ok = Whiska.Git.fetch_base(repo.checkout, "main")
      {:ok, handle} = Storage.open(repo.checkout)
      {:ok, _} = Storage.mark_landed("m-feat-u")
      Storage.close(handle)

      assert show_one(repo, q) =~
               "\nbranch: nothing committed, clean\n"
    end

    test "a merge request opened after its branch landed is the branch's again", %{repo: repo} do
      q = finished(repo, "feat-t", merge_request: @pr)
      {:ok, handle} = Storage.open(repo.checkout)
      {:ok, landed} = Storage.mark_landed("m-feat-t")
      earlier = DateTime.add(landed.landed_at, -60)
      Whiska.Repo.update!(Ecto.Changeset.change(landed, %{landed_at: earlier}))
      {:ok, _} = Storage.record_merge_request("m-feat-t", "https://github.com/o/r/pull/13")
      Storage.close(handle)

      assert show_one(repo, q) =~
               "\nbranch: merge request opened, 1 commit not pushed, clean\nMerge request: https://github.com/o/r/pull/13\n"
    end

    test "commits not pushed are counted, merges included", %{repo: repo} do
      q = finished(repo, "feat-r", merge_request: @pr, push: true)
      path = Path.join([repo.root, "worktrees", "feat-r"])
      GitRepo.commit!(path, "second.md", "more")
      GitRepo.commit!(repo.checkout, "later.md", "moved on")
      GitRepo.git!(path, ["merge", "--no-ff", "-m", "sync", "main"])

      assert show_one(repo, q) =~ "merge request opened, 2 commits not pushed,"
    end
  end

  describe "whiska merge-request — the finished line remembers it" do
    setup do
      root = Path.join(System.tmp_dir!(), "whiska-mr-#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf!(root) end)
      repo = GitRepo.create(root)
      path = GitRepo.worktree(repo, "feat-x", push: false)

      {:ok, handle} = Storage.open(repo.checkout)

      try do
        {:ok, _} = Storage.record_mouse(%{mouse_id: "m-x", path: path, branch: "feat-x"})

        {:ok, q} =
          Storage.record_question(%{
            mouse_id: "m-x",
            text: "Done.\n⁣⁣⁣",
            kind: "done",
            status: "closed"
          })

        {:ok, repo: repo, q: q}
      after
        Storage.close(handle)
      end
    end

    defp merge_request(repo, args) do
      err =
        capture_io(:stderr, fn ->
          out =
            capture_io(fn ->
              send(self(), {:status, CLI.run(["merge-request" | args], repo.checkout)})
            end)

          send(self(), {:out, out})
        end)

      assert_received {:status, status}
      assert_received {:out, out}
      {status, out <> err}
    end

    defp recorded(repo) do
      {:ok, handle} = Storage.open(repo.checkout)

      try do
        Storage.mouse("m-x")
      after
        Storage.close(handle)
      end
    end

    test "records the link and the time on the question's mouse", %{repo: repo, q: q} do
      assert {0, out} = merge_request(repo, [to_string(q.id), @pr])
      assert out =~ "feat-x"
      assert out =~ @pr

      assert %{merge_request_url: @pr, merge_request_at: %DateTime{}} = recorded(repo)
      assert show_one(repo, q) =~ "merge request opened"
    end

    test "a second one replaces the first", %{repo: repo, q: q} do
      assert {0, _} = merge_request(repo, [to_string(q.id), @pr])

      assert {0, _} =
               merge_request(repo, [
                 to_string(q.id),
                 "https://gitlab.example/g/r/-/merge_requests/3"
               ])

      assert %{merge_request_url: "https://gitlab.example/g/r/-/merge_requests/3"} =
               recorded(repo)
    end

    test "refuses a link that is not a plain https one, and stores nothing", %{repo: repo, q: q} do
      for bad <- [
            "http://github.com/o/r/pull/12",
            "github.com/o/r/pull/12",
            "https://",
            "https:///pull/12",
            "https://github.com/o/r/pull/12 extra",
            "https://github.com/o/r/pull/(12)",
            "https://github.com/o/r/pull/12]",
            "https://github.com/o/r/pull/12\"",
            "https://github.com/o/r/pull/12'",
            "https://github.com/o/r/pull/12<",
            "https://github.com/o/r/pull/12\\",
            "https://github.com/o/r/pull/12\n",
            "https://github.com/o/r/pull/12\u202E"
          ] do
        assert {1, _} = merge_request(repo, [to_string(q.id), bad]), inspect(bad)
      end

      assert %{merge_request_url: nil, merge_request_at: nil} = recorded(repo)
    end

    test "refuses an id that is no question", %{repo: repo} do
      assert {1, _} = merge_request(repo, ["999", @pr])
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

    test "one whiska waiting is named by its repo (ADR-0048)", %{main: main} do
      seed(main, fn -> ask("[worktree-status: needs-decision] pick one") end)

      out = capture_io(fn -> assert CLI.run(["statusline"], main) == 0 end)
      assert after_owl(out) == " · 🐱 myrepo\n"
    end

    test "prints only the owl when nothing is waiting (ADR-0048)", %{main: main} do
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

  # The documents a mouse asks the person to review (ADR-0063), linked by
  # `whiska show` itself as file links (ADR-0085).
  describe "whiska show — the spec and build plan in the mouse's worktree" do
    setup do
      root = Path.join(System.tmp_dir!(), "whiska-speclink-#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf!(root) end)
      repo = GitRepo.create(root)
      path = Path.join(repo.checkout, "worktrees/feat/spec-w")
      GitRepo.git!(repo.checkout, ["worktree", "add", "-b", "feat/spec-w", path])

      {:ok, handle} = Storage.open(repo.checkout)

      q =
        try do
          {:ok, _} = Storage.record_mouse(%{mouse_id: "m-s", path: path, branch: "feat/spec-w"})

          {:ok, q} =
            Storage.record_question(%{
              mouse_id: "m-s",
              text: "Ok to build?\n⁣⁣",
              kind: "needs-decision",
              status: "open"
            })

          q
        after
          Storage.close(handle)
        end

      {:ok, repo: repo, path: path, id: to_string(q.id)}
    end

    defp show_with(ctx, pattern) do
      previous = System.get_env("WHISKA_SPEC_LINK")
      if pattern, do: System.put_env("WHISKA_SPEC_LINK", pattern)

      try do
        capture_io(fn -> assert CLI.run(["show", ctx.id], ctx.repo.checkout) == 0 end)
      after
        if previous,
          do: System.put_env("WHISKA_SPEC_LINK", previous),
          else: System.delete_env("WHISKA_SPEC_LINK")
      end
    end

    defp write_documents(path) do
      File.write!(Path.join(path, ".whiska-spec.md"), "# CSV sort\n")
      File.write!(Path.join(path, ".whiska-plan.md"), "# Build plan: CSV sort\n")
    end

    test "each is linked on a line of its own, by a short label", %{path: path} = ctx do
      write_documents(path)

      assert show_with(ctx, nil) =~
               "\nSpec: file://#{path}/.whiska-spec.md\n" <>
                 "Build plan: file://#{path}/.whiska-plan.md\n\n" <>
                 "Ok to build?"
    end

    test "a finished report links neither: the question they were for is closed",
         %{path: path} = ctx do
      write_documents(path)
      ctx = ask_document(ctx, "# Done\n\n## Summary\nIt is built.\n⁣⁣⁣", "build")

      out = show_with(ctx, nil)

      refute out =~ "Spec:"
      refute out =~ "Build plan"
      assert out =~ "\nFull report: file://"
    end

    test "with neither written, there is nothing to review", ctx do
      refute show_with(ctx, nil) =~ "file://"
    end

    test "WHISKA_SPEC_LINK set makes no difference: each link is the file's",
         %{path: path} = ctx do
      write_documents(path)

      assert show_with(ctx, "myviewer://open?file={path}&branch={branch}") =~
               "\nSpec: file://#{path}/.whiska-spec.md\n" <>
                 "Build plan: file://#{path}/.whiska-plan.md\n"
    end

    test "a document that is a link is not offered for review", %{path: path} = ctx do
      File.write!(Path.join(path, ".whiska-spec.md"), "# CSV sort\n")
      File.ln_s!(Path.join(path, "README.md"), Path.join(path, ".whiska-plan.md"))

      out = show_with(ctx, nil)
      assert out =~ "\nSpec: "
      refute out =~ "Build plan"
    end

    test "a bug's research document is linked on the question asking for the ok", ctx do
      entry = %Entry{
        mouse_id: "m-s",
        branch: "feat/spec-w",
        worktree_root: ctx.path,
        stamped_at: ~U[2026-10-06 09:00:00Z],
        text: "",
        research: "# Why the export drops rows\n"
      }

      {:ok, handle} = Storage.open(ctx.repo.checkout)
      q = Storage.question(String.to_integer(ctx.id))
      Storage.close(handle)
      :kept = Whiska.SpecArchive.keep_research(ctx.repo.checkout, entry, q)

      assert show_with(ctx, nil) =~ "\nResearch: file://"
    end

    defp ask_document(ctx, text, mode) do
      {:ok, handle} = Storage.open(ctx.repo.checkout)

      try do
        {:ok, q} =
          Storage.record_question(%{mouse_id: "m-s", text: text, kind: "done", status: "open"})

        entry = %Entry{
          mouse_id: "m-s",
          branch: "feat/spec-w",
          worktree_root: ctx.path,
          stamped_at: ~U[2026-10-06 09:00:00Z],
          text: text
        }

        :kept = Whiska.SpecArchive.keep_document(ctx.repo.checkout, entry, q, mode)
        %{ctx | id: to_string(q.id)}
      after
        Storage.close(handle)
      end
    end

    test "a research document prints its summary and what to change, under its link", ctx do
      ctx =
        ask_document(
          ctx,
          "# Why the export drops rows\n\n## Summary\nThe last page is never read.\n\n" <>
            "## What to change\n- Found: the pager stops one short.\n- Build: read to the end.\n\n" <>
            "## Question\nWhy?\n\n## Found\nexport.ex:40 loops while page < last.\n⁣⁣⁣",
          "sniff"
        )

      out = show_with(ctx, nil)

      assert out =~
               ~r"\nResearch: file://\S+\.research\.md\n"

      assert out =~
               "\n\n## Summary\nThe last page is never read.\n\n" <>
                 "## What to change\n- Found: the pager stops one short.\n"

      refute out =~ "Build: read to the end"
      refute out =~ "export.ex:40"
    end

    test "a build report prints its summary, under the link to the whole report", ctx do
      ctx =
        ask_document(
          ctx,
          "# The export keeps every row\n\n## Summary\nThe pager reads to the end.\n\n" <>
            "## What changed\n- Pages counted from one.\n⁣⁣⁣",
          "build"
        )

      out = show_with(ctx, nil)

      assert out =~
               ~r"\nFull report: file://\S+\.report\.md\n\n## Summary\nThe pager reads to the end.\n"

      refute out =~ "Pages counted from one"
    end

    test "a message with no Summary is printed whole", ctx do
      {:ok, handle} = Storage.open(ctx.repo.checkout)

      {:ok, q} =
        Storage.record_question(%{
          mouse_id: "m-s",
          text: "Two ways.\n\n## Found\nexport.ex:40\n⁣⁣",
          kind: "needs-decision",
          status: "open"
        })

      Storage.close(handle)

      assert show_with(%{ctx | id: to_string(q.id)}, nil) =~
               "\n\nTwo ways.\n\n## Found\nexport.ex:40"
    end
  end
end
