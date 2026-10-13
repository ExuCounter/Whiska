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

    # The finish options in the `whiska-delivered` skill (ADR-0022) read the
    # line, and the report is closed once the person writes something.
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

    # The finish options in `whiska-delivered` offer a fresh build only for
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

  # The finish options in `whiska-delivered` offer a landing only when this
  # line says there is something to land.
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
            status: Keyword.get(opts, :status, "closed")
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
               ~r/^##{q.id}  feat-a  finished  \(closed, asked [^)]+\)\nOn the branch: 1 commit beyond main · nothing uncommitted\nReview diff here: .*\n\nDone\./
    end

    test "its diff is a file beside the kept specs, linked under the branch line", %{repo: repo} do
      q = finished(repo, "feat-d")
      review = review_file(repo, "feat-d")

      assert show_one(repo, q) =~
               "\nReview diff here: [1 commit against main](file://#{review})\n"

      text = File.read!(review)
      assert text =~ "git diff main...feat-d"
      assert text =~ ~r/^```diff\n.*^\+/ms
      assert File.read!(Path.join(repo.checkout, ".git/info/exclude")) =~ "/.whiska/"
    end

    # The person's own diff viewer, named only in their environment (ADR-0085).
    defp with_diff_link(pattern, fun) do
      previous = System.get_env("WHISKA_DIFF_LINK")
      System.put_env("WHISKA_DIFF_LINK", pattern)

      try do
        fun.()
      after
        if previous,
          do: System.put_env("WHISKA_DIFF_LINK", previous),
          else: System.delete_env("WHISKA_DIFF_LINK")
      end
    end

    test "WHISKA_DIFF_LINK points the link at the person's viewer, and no file is written",
         %{repo: repo} do
      q = finished(repo, "feat-d")

      out = with_diff_link("hunk-review://{base}..{branch}", fn -> show_one(repo, q) end)

      assert out =~ "\nReview diff here: [1 commit against main](hunk-review://main..feat-d)\n"
      refute File.exists?(review_file(repo, "feat-d"))
    end

    test "a base the main checkout holds only from origin reaches the pattern as git names it",
         %{repo: repo} do
      GitRepo.git!(repo.checkout, ["checkout", "-b", "staging"])
      GitRepo.commit!(repo.checkout, "s1.md", "staging work")
      GitRepo.git!(repo.checkout, ["push", "-u", "origin", "staging"])
      GitRepo.git!(repo.checkout, ["checkout", "main"])
      GitRepo.git!(repo.checkout, ["branch", "-D", "staging"])
      q = finished(repo, "feat-o", base: "staging")

      out = with_diff_link("hunk-review://{base}..{branch}", fn -> show_one(repo, q) end)

      assert out =~ "[1 commit against staging](hunk-review://origin/staging..feat-o)\n"
    end

    test "a branch name that would break the link reaches the pattern encoded", %{repo: repo} do
      q = finished(repo, "feat/a(b)")

      out = with_diff_link("hunk-review://{base}..{branch}", fn -> show_one(repo, q) end)

      assert out =~ "(hunk-review://main..feat/a%28b%29)\n"
    end

    test "an empty WHISKA_DIFF_LINK, or one that could break the link, keeps the file link",
         %{repo: repo} do
      q = finished(repo, "feat-e")
      file_link = "(file://#{review_file(repo, "feat-e")})\n"

      for pattern <- [
            "",
            "hunk-review//{base}..{branch}",
            "hunk-review://{base} {branch}",
            "hunk-review://{base}..{branch})",
            "hunk-review://{base}..{branch}\n",
            "hunk-review://{base}..{branch}\\",
            "hunk-review://{base}..{branch}\u202E",
            "hunk-review://{base}..{branch}\u009B"
          ] do
        assert with_diff_link(pattern, fn -> show_one(repo, q) end) =~ file_link,
               "pattern #{inspect(pattern)}"
      end
    end

    test "read from another mouse's worktree, a finished branch still links its diff",
         %{repo: repo} do
      q = finished(repo, "feat-w")
      worktree = Path.join(repo.checkout, "worktrees/elsewhere")
      GitRepo.git!(repo.checkout, ["worktree", "add", "-b", "elsewhere", worktree])

      out = capture_io(fn -> assert CLI.run(["show", to_string(q.id)], worktree) == 0 end)

      assert out =~
               "\nReview diff here: [1 commit against main](file://#{review_file(repo, "feat-w")})\n"

      assert File.read!(review_file(repo, "feat-w")) =~
               "git diff main...feat-w"
    end

    test "a kept research document is linked under the branch line, by its title", %{repo: repo} do
      q = finished(repo, "ask-w1", commit: false)
      keep_research(repo, q, "# Why the owl hangs\n\nFound.\n")

      assert show_one(repo, q) =~
               "On the branch: nothing committed beyond main · nothing uncommitted\n" <>
                 "Review research here: [Why the owl hangs](#{research_file(repo, "ask-w1")})\n\nDone."
    end

    test "the research document is linked when read from a mouse's worktree too", %{repo: repo} do
      q = finished(repo, "ask-w2", commit: false)
      keep_research(repo, q, "No heading here.\n")
      worktree = Path.join(repo.checkout, "worktrees/reader")
      GitRepo.git!(repo.checkout, ["worktree", "add", "-b", "reader", worktree])

      out = capture_io(fn -> assert CLI.run(["show", to_string(q.id)], worktree) == 0 end)

      assert out =~
               "\nReview research here: [research](#{research_file(repo, "ask-w2")})\n"
    end

    test "a research document still links once its worktree is gone", %{repo: repo} do
      q = finished(repo, "ask-w3", commit: false, gone: true)
      keep_research(repo, q, "# Found [it]\n")

      assert show_one(repo, q) =~
               ~r/\nOn the branch: unknown[^\n]*\nReview research here: \[Found it\]\(file:/
    end

    test "a finished question with no research document has no research document link", %{
      repo: repo
    } do
      q = finished(repo, "ask-w4", commit: false)
      refute show_one(repo, q) =~ "research"
    end

    test "nothing committed has no diff to review", %{repo: repo} do
      q = finished(repo, "ask-n", commit: false)

      refute show_one(repo, q) =~ "Review diff here"
      refute File.exists?(review_file(repo, "ask-n"))
    end

    test "an earlier question links the same diff file as the latest, rewritten from the branch",
         %{repo: repo} do
      first = finished(repo, "feat-r")
      second = ask_again(repo, "feat-r")
      link = "(file://#{review_file(repo, "feat-r")})\n"

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
                 "\nReview research here: [Final](#{research_file(repo, "ask-r")})\n"
      end
    end

    test "a question from before research was kept per branch still links its own copy",
         %{repo: repo} do
      q = finished(repo, "ask-old", commit: false)
      old = Path.join(repo.checkout, ".whiska/research/#{q.id}.md")
      File.mkdir_p!(Path.dirname(old))
      File.write!(old, "# Older\n")

      assert show_one(repo, q) =~ "\nReview research here: [Older](file://#{old})\n"
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
               "On the branch: nothing committed beyond staging · nothing uncommitted"
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

      assert show_one(repo, q) =~ "On the branch: 2 commits beyond main"
    end

    test "a recorded base that is gone is unknown, never main", %{repo: repo} do
      q = finished(repo, "ask-u", commit: false, base: "staging")

      assert show_one(repo, q) =~ "On the branch: unknown — its base branch staging is gone"
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

      full = capture_io(fn -> assert CLI.run(["questions", "--full"], repo.checkout) == 0 end)

      assert full =~
               ~r/##{q.id}  feat-j  finished  \([^)]+\)\nOn the branch: nothing committed beyond main · nothing uncommitted\n/
    end

    @pr "https://github.com/o/r/pull/12"

    test "a merge request opened: what is not pushed, and its link, under the heading",
         %{repo: repo} do
      q = finished(repo, "feat-m", merge_request: @pr)

      assert show_one(repo, q) =~
               ~r/^##{q.id}  feat-m  finished  \([^)]+\)\nOn the branch: merge request opened · 1 commit not pushed · nothing uncommitted\nMerge request: #{Regex.escape(@pr)}\nReview diff here: \[1 commit against main\]/
    end

    test "a merge request with everything pushed says so", %{repo: repo} do
      q = finished(repo, "feat-n", merge_request: @pr, push: true)

      assert show_one(repo, q) =~
               "\nOn the branch: merge request opened · everything pushed · nothing uncommitted\n"
    end

    test "a merge request's files not committed are named as on any branch line", %{repo: repo} do
      q = finished(repo, "feat-p", merge_request: @pr, push: true, files: ["a.txt"])

      assert show_one(repo, q) =~
               "\nOn the branch: merge request opened · everything pushed · 1 file not committed: a.txt\n"
    end

    # The base's own commits travel with the branch but are the base's to push.
    test "a commit the base has not pushed is not the merge request's", %{repo: repo} do
      GitRepo.commit!(repo.checkout, "local.md", "not pushed yet")
      q = finished(repo, "feat-q", merge_request: @pr)

      assert show_one(repo, q) =~ "merge request opened · 1 commit not pushed ·"
    end

    test "a merge request already merged reads as any branch, so new commits can land",
         %{repo: repo} do
      q = finished(repo, "feat-s", merge_request: @pr)
      {:ok, handle} = Storage.open(repo.checkout)
      {:ok, _} = Storage.mark_landed("m-feat-s")
      Storage.close(handle)

      shown = show_one(repo, q)

      assert shown =~ "\nOn the branch: 1 commit beyond main · nothing uncommitted\n"
      refute shown =~ "Merge request:"
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
               "\nOn the branch: merge request opened · 1 commit not pushed · nothing uncommitted\nMerge request: https://github.com/o/r/pull/13\n"
    end

    test "commits not pushed are counted, merges included", %{repo: repo} do
      q = finished(repo, "feat-r", merge_request: @pr, push: true)
      path = Path.join([repo.root, "worktrees", "feat-r"])
      GitRepo.commit!(path, "second.md", "more")
      GitRepo.commit!(repo.checkout, "later.md", "moved on")
      GitRepo.git!(path, ["merge", "--no-ff", "-m", "sync", "main"])

      assert show_one(repo, q) =~ "merge request opened · 2 commits not pushed ·"
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
      assert show_one(repo, q) =~ "On the branch: merge request opened"
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

  # The spec's review link, which a mouse sends as its question (ADR-0063);
  # the person's own viewer is named only in their environment (ADR-0085).
  describe "whiska spec-link — the line a mouse sends with its spec" do
    setup do
      root = Path.join(System.tmp_dir!(), "whiska-speclink-#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf!(root) end)
      repo = GitRepo.create(root)
      path = Path.join(repo.checkout, "worktrees/feat/spec-w")
      GitRepo.git!(repo.checkout, ["worktree", "add", "-b", "feat/spec-w", path])
      {:ok, repo: repo, path: path}
    end

    defp spec_link(path, pattern, title \\ "My spec") do
      previous = System.get_env("WHISKA_SPEC_LINK")
      if pattern, do: System.put_env("WHISKA_SPEC_LINK", pattern)

      try do
        capture_io(fn -> assert CLI.run(["spec-link", title], path) == 0 end)
      after
        if previous,
          do: System.put_env("WHISKA_SPEC_LINK", previous),
          else: System.delete_env("WHISKA_SPEC_LINK")
      end
    end

    test "WHISKA_SPEC_LINK points the link at the person's viewer", %{path: path} do
      out = spec_link(path, "myviewer://open?file={path}&branch={branch}")

      file = URI.encode(path <> "/.whiska-spec.md", &(URI.char_unreserved?(&1) or &1 == ?/))

      assert out ==
               "Review spec here: [My spec](myviewer://open?file=#{file}&branch=feat/spec-w)\n"
    end

    test "with none set, it is the file link annotate opens", %{path: path} do
      assert spec_link(path, nil) ==
               "Review spec here: [My spec](file://#{path}/.whiska-spec.md)\n"
    end

    test "a pattern that could break the link keeps the file link", %{path: path} do
      for pattern <- ["", "myviewer//{path}", "myviewer://{path} x", "myviewer://{path})"] do
        assert spec_link(path, pattern) =~ "(file://#{path}/.whiska-spec.md)\n",
               "pattern #{inspect(pattern)}"
      end
    end

    test "a branch name that would break the link reaches the pattern encoded", %{repo: repo} do
      odd = Path.join(repo.checkout, "worktrees/feat/a(b)")
      GitRepo.git!(repo.checkout, ["worktree", "add", "-b", "feat/a(b)", odd])

      assert spec_link(odd, "myviewer://x?b={branch}") =~ "(myviewer://x?b=feat/a%28b%29)\n"
    end

    test "from the main checkout it links that checkout's spec, and registers no mouse",
         %{repo: repo} do
      assert spec_link(repo.checkout, nil) =~
               ~r{\AReview spec here: \[My spec\]\(file://.+/repo/\.whiska-spec\.md\)\n\z}

      refute File.exists?(Path.join(repo.checkout, ".whiska-mouse"))
    end

    test "an empty title is refused, not printed as an empty link", %{path: path} do
      stderr = capture_io(:stderr, fn -> assert CLI.run(["spec-link", "  "], path) == 1 end)

      assert stderr =~ "needs the spec's title"
    end

    test "a title with brackets cannot close the link early", %{path: path} do
      assert spec_link(path, nil, "a [b] c") =~ "[a \\[b\\] c](file://"
    end

    test "with a build plan beside the spec, it links both, the spec first", %{path: path} do
      File.write!(Path.join(path, ".whiska-spec.md"), "# My spec\n")
      File.write!(Path.join(path, ".whiska-plan.md"), "# Build plan\n")

      assert spec_link(path, nil) ==
               "Review spec here: [My spec](file://#{path}/.whiska-spec.md)\n" <>
                 "Review build plan here: [My spec](file://#{path}/.whiska-plan.md)\n"
    end

    test "a bug's research document comes first, then its build plan", %{path: path} do
      File.write!(Path.join(path, ".whiska-research.md"), "# A bug\n")
      File.write!(Path.join(path, ".whiska-plan.md"), "# Build plan\n")

      assert spec_link(path, nil) ==
               "Review research here: [My spec](file://#{path}/.whiska-research.md)\n" <>
                 "Review build plan here: [My spec](file://#{path}/.whiska-plan.md)\n"
    end

    test "a research document alone is linked alone", %{path: path} do
      File.write!(Path.join(path, ".whiska-research.md"), "# A bug\n")

      assert spec_link(path, nil) ==
               "Review research here: [My spec](file://#{path}/.whiska-research.md)\n"
    end

    test "a document that is a link is not offered for review", %{path: path} do
      File.write!(Path.join(path, ".whiska-spec.md"), "# My spec\n")
      File.ln_s!(Path.join(path, "README.md"), Path.join(path, ".whiska-plan.md"))

      assert spec_link(path, nil) ==
               "Review spec here: [My spec](file://#{path}/.whiska-spec.md)\n"
    end

    test "WHISKA_SPEC_LINK takes every document's path", %{path: path} do
      File.write!(Path.join(path, ".whiska-spec.md"), "# My spec\n")
      File.write!(Path.join(path, ".whiska-plan.md"), "# Build plan\n")

      out = spec_link(path, "myviewer://open?file={path}")
      encoded = &URI.encode(path <> "/" <> &1, fn c -> URI.char_unreserved?(c) or c == ?/ end)

      assert out ==
               "Review spec here: [My spec](myviewer://open?file=#{encoded.(".whiska-spec.md")})\n" <>
                 "Review build plan here: [My spec](myviewer://open?file=#{encoded.(".whiska-plan.md")})\n"
    end
  end
end
