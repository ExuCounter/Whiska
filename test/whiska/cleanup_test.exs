defmodule Whiska.CleanupTest do
  @moduledoc """
  Taking a landed worktree down, pane and all (ADR-0061).

  Real git, a real house, and herdr faked at the one boundary that allows it
  (ADR-0031). Most of these tests are about *not* removing something: the four
  preconditions are the whole of the protection, and unknown is never
  permission.
  """
  use ExUnit.Case, async: true

  import Mox

  alias Whiska.Cleanup
  alias Whiska.Doorstep
  alias Whiska.Git
  alias Whiska.Herdr.Mock, as: Herdr
  alias Whiska.Storage
  alias Whiska.Test.GitRepo

  setup :verify_on_exit!

  setup do
    root = Path.join(System.tmp_dir!(), "whiska-cleanup-#{Whiska.Test.Unique.id()}")
    File.mkdir_p!(root)
    repo = GitRepo.create(root)
    {:ok, handle} = Storage.open(repo.checkout, name: nil)

    on_exit(fn ->
      Storage.close(handle)
      File.rm_rf!(root)
    end)

    {:ok, repo: repo}
  end

  defp mouse(repo, branch, opts \\ []) do
    path = GitRepo.worktree(repo, branch, Keyword.take(opts, [:push, :commit]))
    id = "m-#{branch}"

    {:ok, _} =
      Storage.record_mouse(%{
        mouse_id: id,
        path: path,
        branch: branch,
        pane: opts[:pane],
        base: opts[:base],
        mode: Keyword.get(opts, :mode, "build"),
        shaped_as: Keyword.get(opts, :shaped_as, Keyword.get(opts, :mode, "build")),
        built_from: opts[:built_from]
      })

    question =
      unless opts[:silent] do
        {:ok, question} =
          Storage.record_question(%{
            mouse_id: id,
            text: "all done",
            kind: Keyword.get(opts, :kind, "done"),
            status: Keyword.get(opts, :status, "closed")
          })

        question.id
      end

    %{id: id, path: path, branch: branch, question: question}
  end

  defp herdr(repo, worktrees, panes) do
    stub(Herdr, :list_panes, fn _ -> {:ok, panes} end)

    stub(Herdr, :worktrees, fn _, checkout ->
      ^checkout = repo.checkout
      {:ok, worktrees}
    end)

    :ok
  end

  defp seen(repo, mouse, opts) do
    worktree = %{
      path: mouse.path,
      branch: mouse.branch,
      workspace_id: Keyword.get(opts, :workspace_id, "ws-1")
    }

    panes =
      case opts[:pane] do
        nil -> []
        {id, status} -> [%{pane_id: id, cwd: mouse.path, agent: "claude", agent_status: status}]
      end

    herdr(repo, [worktree], panes)
  end

  defp sweep(repo), do: Cleanup.sweep(%{main_checkout: repo.checkout, herdr: Herdr, socket: "/s"})

  describe "a quiet mouse on a landed branch" do
    test "goes, pane and worktree together, through herdr", %{repo: repo} do
      m = mouse(repo, "feat-a", pane: "w1:p1")
      GitRepo.land(repo, "feat-a")
      seen(repo, m, pane: {"w1:p1", "idle"}, workspace_id: "ws-7")

      expect(Herdr, :remove_worktree, fn _, "ws-7" ->
        File.rm_rf!(m.path)
        :ok
      end)

      assert [{"m-feat-a", :removed}] = sweep(repo)
      refute File.dir?(m.path)
      refute GitRepo.git!(repo.checkout, ["branch", "--list"]) =~ "feat-a"
      assert %{removed_at: %DateTime{}, died_at: %DateTime{}} = Storage.mouse("m-feat-a")
    end

    test "takes the branch's diff file with the branch", %{repo: repo} do
      m = mouse(repo, "feat-a")
      {:ok, diff} = Whiska.Review.write(repo.checkout, "feat-a", "+a\n")
      GitRepo.land(repo, "feat-a")
      seen(repo, m, workspace_id: nil)

      assert [{"m-feat-a", :removed}] = sweep(repo)
      refute File.exists?(diff)
    end

    test "a pane herdr calls done is ready for input too", %{repo: repo} do
      m = mouse(repo, "feat-a", pane: "w1:p1")
      GitRepo.land(repo, "feat-a")
      seen(repo, m, pane: {"w1:p1", "done"})

      expect(Herdr, :remove_worktree, fn _, _ ->
        File.rm_rf!(m.path)
        :ok
      end)

      assert [{"m-feat-a", :removed}] = sweep(repo)
    end

    test "with its pane already gone, git takes the worktree down alone", %{repo: repo} do
      m = mouse(repo, "feat-a")
      GitRepo.land(repo, "feat-a")
      seen(repo, m, workspace_id: nil)

      assert [{"m-feat-a", :removed}] = sweep(repo)
      refute File.dir?(m.path)
    end

    test "is swept once — a marked row is never looked at again", %{repo: repo} do
      m = mouse(repo, "feat-a")
      GitRepo.land(repo, "feat-a")
      seen(repo, m, workspace_id: nil)
      assert [{"m-feat-a", :removed}] = sweep(repo)

      herdr(repo, [], [])
      assert [] = sweep(repo)
    end
  end

  describe "a mouse on hold (ADR-0079)" do
    test "is left exactly where it is, landed and quiet or not", %{repo: repo} do
      m = mouse(repo, "feat-a", pane: "w1:p1")
      GitRepo.land(repo, "feat-a")
      seen(repo, m, pane: {"w1:p1", "idle"}, workspace_id: "ws-7")
      {:ok, _} = Storage.hold("m-feat-a")

      assert [{"m-feat-a", {:left, :held}}] = sweep(repo)
      assert File.dir?(m.path)
      assert %{removed_at: nil} = Storage.mouse("m-feat-a")
    end

    test "its landing is still noted, so a question of its settles later", %{repo: repo} do
      m = mouse(repo, "feat-a", pane: "w1:p1")
      GitRepo.land(repo, "feat-a")
      seen(repo, m, pane: {"w1:p1", "idle"})
      {:ok, _} = Storage.hold("m-feat-a")

      assert [{"m-feat-a", {:left, :held}}] = sweep(repo)
      assert %{landed_at: %DateTime{}} = Storage.mouse("m-feat-a")
    end
  end

  # The sweep's other job (ADR-0064): noting that a branch has landed, whether
  # or not the worktree may go. A mouse holding a question is never torn down
  # here, but its branch landing is what later settles that question instead of
  # orphaning it.
  describe "noting a landing (ADR-0064)" do
    test "stamps a mouse whose branch has landed, even while a question holds it",
         %{repo: repo} do
      m = mouse(repo, "feat-a", kind: "needs-decision", status: "sent")
      GitRepo.land(repo, "feat-a")
      seen(repo, m, workspace_id: nil)

      assert [{"m-feat-a", {:left, :waiting}}] = sweep(repo)
      assert %{landed_at: %DateTime{}} = Storage.mouse("m-feat-a")
      assert File.dir?(m.path)
    end

    test "a mouse cut from staging has landed when staging has it, not main", %{repo: repo} do
      GitRepo.git!(repo.checkout, ["checkout", "-b", "staging"])
      GitRepo.commit!(repo.checkout, "s1.md", "staging work")
      m = mouse(repo, "feat-a", kind: "needs-decision", status: "sent", base: "staging")
      seen(repo, m, workspace_id: nil)

      assert [{"m-feat-a", {:left, :waiting}}] = sweep(repo)
      assert %{landed_at: nil} = Storage.mouse("m-feat-a")

      GitRepo.git!(repo.checkout, ["merge", "--no-ff", "-m", "merge feat-a", "feat-a"])

      assert [{"m-feat-a", {:left, :waiting}}] = sweep(repo)
      assert %{landed_at: %DateTime{}} = Storage.mouse("m-feat-a")
    end

    test "stamps a mouse whose worktree was taken down by hand, from the branch alone",
         %{repo: repo} do
      m = mouse(repo, "feat-a", kind: "needs-decision", status: "sent")
      GitRepo.land(repo, "feat-a")
      GitRepo.git!(repo.checkout, ["worktree", "remove", m.path])
      herdr(repo, [], [])

      assert [{"m-feat-a", {:left, :gone}}] = sweep(repo)
      assert %{landed_at: %DateTime{}} = Storage.mouse("m-feat-a")
    end

    test "leaves an unmerged branch unstamped — abandoned work is still an orphan",
         %{repo: repo} do
      m = mouse(repo, "feat-a", kind: "needs-decision", status: "sent")
      seen(repo, m, workspace_id: nil)

      assert [{"m-feat-a", {:left, :waiting}}] = sweep(repo)
      assert %{landed_at: nil} = Storage.mouse("m-feat-a")
    end

    test "a branch carrying no work of its own is no landing, however fresh", %{repo: repo} do
      m = mouse(repo, "feat-a", kind: "needs-decision", status: "sent", commit: false)
      seen(repo, m, workspace_id: nil)

      assert [{"m-feat-a", {:left, :waiting}}] = sweep(repo)
      assert %{landed_at: nil} = Storage.mouse("m-feat-a")
    end

    test "a branch cut off an older base is no landing either", %{repo: repo} do
      m = mouse(repo, "feat-a", kind: "needs-decision", status: "sent", commit: false)
      GitRepo.commit!(repo.checkout, "later.md", "moved on")
      GitRepo.git!(repo.checkout, ["push", "origin", "main"])
      seen(repo, m, workspace_id: nil)

      assert [{"m-feat-a", {:left, :waiting}}] = sweep(repo)
      assert %{landed_at: nil} = Storage.mouse("m-feat-a")
    end

    test "never reads the base branch as a landing — it is merged into itself", %{repo: repo} do
      {:ok, _} =
        Storage.record_mouse(%{mouse_id: "m-forged", path: "/w/gone", branch: "main"})

      {:ok, q} =
        Storage.record_question(%{
          mouse_id: "m-forged",
          text: "?",
          kind: "needs-decision",
          status: "orphaned"
        })

      herdr(repo, [], [])
      sweep(repo)

      assert %{landed_at: nil} = Storage.mouse("m-forged")
      assert Storage.question(q.id).status == "orphaned"
    end

    test "settles what the mouse had already left orphaned", %{repo: repo} do
      m = mouse(repo, "feat-a", kind: "needs-decision", status: "sent")
      [q] = Storage.all(Whiska.Schema.Question)
      {:ok, _} = Storage.mark_dead(m.id)
      assert Storage.question(q.id).status == "orphaned"

      GitRepo.land(repo, "feat-a")
      seen(repo, m, workspace_id: nil)
      sweep(repo)

      assert Storage.question(q.id).status == "settled"
    end
  end

  # Land here copies a branch's commits onto the base with new ids and leaves
  # the worktree for the owl. A trial merge that would change nothing is the
  # landing, whatever the commits are called now.
  describe "a branch landed as copies" do
    test "is stamped landed and taken down, branch and all, never having been pushed",
         %{repo: repo} do
      m = mouse(repo, "feat-a", push: false)
      GitRepo.commit!(repo.checkout, "later.md", "moved on")
      GitRepo.cherry_pick(repo, "feat-a")
      seen(repo, m, workspace_id: nil)

      assert [{"m-feat-a", :removed}] = sweep(repo)
      assert %{landed_at: %DateTime{}} = Storage.mouse("m-feat-a")
      refute File.dir?(m.path)
      refute GitRepo.git!(repo.checkout, ["branch", "--list"]) =~ "feat-a"
    end

    test "its finished notice settles rather than orphaning when the pane goes",
         %{repo: repo} do
      m = mouse(repo, "feat-a", push: false, status: "sent")
      [notice] = Storage.all(Whiska.Schema.Question)
      GitRepo.commit!(repo.checkout, "later.md", "moved on")
      GitRepo.cherry_pick(repo, "feat-a")
      seen(repo, m, workspace_id: nil)

      assert [{"m-feat-a", {:left, :waiting}}] = sweep(repo)
      {:ok, _} = Storage.mark_dead(m.id)

      assert Storage.question(notice.id).status == "settled"
    end

    test "so is a squashed one", %{repo: repo} do
      m = mouse(repo, "feat-a", push: false)
      GitRepo.commit!(m.path, "more.md", "second")
      GitRepo.squash(repo, "feat-a")
      seen(repo, m, workspace_id: nil)

      assert [{"m-feat-a", :removed}] = sweep(repo)
      refute GitRepo.git!(repo.checkout, ["branch", "--list"]) =~ "feat-a"
    end

    test "a branch that only merged the base in is no landing, and stays", %{repo: repo} do
      m = mouse(repo, "feat-a", push: false, commit: false)
      GitRepo.commit!(repo.checkout, "later.md", "moved on")
      GitRepo.git!(m.path, ["merge", "--no-ff", "-m", "merge main", "main"])
      seen(repo, m, workspace_id: nil)

      assert [{"m-feat-a", {:left, :not_merged}}] = sweep(repo)
      assert %{landed_at: nil} = Storage.mouse("m-feat-a")
      assert File.dir?(m.path)
    end

    test "half of a branch copied over is no landing, and nothing is deleted", %{repo: repo} do
      m = mouse(repo, "feat-a", push: false)
      first = String.trim(GitRepo.git!(m.path, ["rev-parse", "HEAD"]))
      GitRepo.commit!(m.path, "more.md", "second")
      GitRepo.git!(repo.checkout, ["cherry-pick", first])
      seen(repo, m, workspace_id: nil)

      assert [{"m-feat-a", {:left, :not_merged}}] = sweep(repo)
      assert %{landed_at: nil} = Storage.mouse("m-feat-a")
      assert GitRepo.git!(repo.checkout, ["branch", "--list"]) =~ "feat-a"
    end

    test "is noted from the branch alone once the worktree has gone", %{repo: repo} do
      m = mouse(repo, "feat-a", push: false, kind: "needs-decision", status: "sent")
      GitRepo.commit!(repo.checkout, "later.md", "moved on")
      GitRepo.cherry_pick(repo, "feat-a")
      GitRepo.git!(repo.checkout, ["worktree", "remove", m.path])
      herdr(repo, [], [])

      assert [{"m-feat-a", {:left, :gone}}] = sweep(repo)
      assert %{landed_at: %DateTime{}} = Storage.mouse("m-feat-a")
    end
  end

  describe "a branch merged on the forge" do
    test "stays while only the forge has it, and goes once the base is fetched",
         %{repo: repo} do
      m = mouse(repo, "feat-a")
      GitRepo.merge_on_forge(repo, "feat-a")
      seen(repo, m, workspace_id: nil)

      assert [{"m-feat-a", {:left, :not_merged}}] = sweep(repo)
      assert %{landed_at: nil} = Storage.mouse("m-feat-a")

      :ok = Git.fetch_base(repo.checkout, "main")

      assert [{"m-feat-a", :removed}] = sweep(repo)
      assert %{landed_at: %DateTime{}} = Storage.mouse("m-feat-a")
      refute File.dir?(m.path)
      refute GitRepo.git!(repo.checkout, ["branch", "--list"]) =~ "feat-a"
    end

    test "squashed, goes the same way, branch and all", %{repo: repo} do
      m = mouse(repo, "feat-a")
      GitRepo.commit!(m.path, "more.md", "second")
      GitRepo.git!(m.path, ["push", "--quiet", "origin", "feat-a"])
      GitRepo.merge_on_forge(repo, "feat-a", squash: true)
      :ok = Git.fetch_base(repo.checkout, "main")
      seen(repo, m, workspace_id: nil)

      assert [{"m-feat-a", :removed}] = sweep(repo)
      refute GitRepo.git!(repo.checkout, ["branch", "--list"]) =~ "feat-a"
    end

    test "a second merge request, opened after the first landed, is seen landed in turn",
         %{repo: repo} do
      m = mouse(repo, "feat-a", kind: "needs-decision", status: "sent")
      GitRepo.merge_on_forge(repo, "feat-a")
      :ok = Git.fetch_base(repo.checkout, "main")
      seen(repo, m, workspace_id: nil)
      sweep(repo)
      landed = Storage.mouse("m-feat-a")
      earlier = DateTime.add(landed.landed_at, -60)
      Whiska.Repo.update!(Ecto.Changeset.change(landed, %{landed_at: earlier}))
      {:ok, _} = Storage.record_merge_request("m-feat-a", "https://github.com/o/r/pull/2")
      GitRepo.commit!(m.path, "more.md", "second")
      GitRepo.git!(m.path, ["push", "--quiet", "origin", "feat-a"])
      GitRepo.merge_on_forge(repo, "feat-a")
      :ok = Git.fetch_base(repo.checkout, "main")

      sweep(repo)

      refute Whiska.Schema.Mouse.merge_request_waiting?(Storage.mouse("m-feat-a"))
    end

    test "with a commit made since the merge, stays", %{repo: repo} do
      m = mouse(repo, "feat-a")
      GitRepo.merge_on_forge(repo, "feat-a")
      :ok = Git.fetch_base(repo.checkout, "main")
      GitRepo.commit!(m.path, "late.md", "one more")
      seen(repo, m, workspace_id: nil)

      assert [{"m-feat-a", {:left, :not_merged}}] = sweep(repo)
      assert File.dir?(m.path)
    end
  end

  describe "a merge request the forge read as merged, into another branch" do
    @url "https://gitlab.example.com/acme/app/-/merge_requests/7"

    defp read_merged(m, opts \\ []) do
      {:ok, _} = Storage.record_merge_request(m.id, @url)
      {:ok, head} = Git.head(m.path)

      {:ok, _} =
        Storage.save_merge_request_read(%{
          mouse_id: m.id,
          url: Keyword.get(opts, :url, @url),
          state: Keyword.get(opts, :state, "merged"),
          head_sha: Keyword.get(opts, :head_sha, head)
        })

      head
    end

    test "goes, branch and all, though git sees nothing in the base, and is not stamped landed",
         %{repo: repo} do
      m = mouse(repo, "feat-a")
      read_merged(m)
      seen(repo, m, workspace_id: nil)

      assert [{"m-feat-a", :removed}] = sweep(repo)
      refute File.dir?(m.path)
      refute GitRepo.git!(repo.checkout, ["branch", "--list"]) =~ "feat-a"
      assert %{landed_at: nil, removed_at: %DateTime{}} = Storage.mouse("m-feat-a")
    end

    test "goes though the branch it was cut from is gone", %{repo: repo} do
      m = mouse(repo, "feat-a", base: "release-1")
      read_merged(m)
      seen(repo, m, workspace_id: nil)

      assert [{"m-feat-a", :removed}] = sweep(repo)
    end

    test "goes though the forge deleted its source branch on merge", %{repo: repo} do
      m = mouse(repo, "feat-a")
      GitRepo.git!(m.path, ["push", "--quiet", "origin", "--delete", "feat-a"])
      GitRepo.commit!(m.path, "more.md", "pushed once, then deleted on the forge")
      read_merged(m)
      seen(repo, m, workspace_id: nil)

      assert [{"m-feat-a", :removed}] = sweep(repo)
    end

    test "with a commit made since the merge, stays", %{repo: repo} do
      m = mouse(repo, "feat-a")
      read_merged(m)
      GitRepo.commit!(m.path, "late.md", "one more")
      seen(repo, m, workspace_id: nil)

      assert [{"m-feat-a", {:left, :not_merged}}] = sweep(repo)
      assert File.dir?(m.path)
    end

    test "with a file not committed, stays", %{repo: repo} do
      m = mouse(repo, "feat-a")
      read_merged(m)
      GitRepo.dirty!(m.path)
      seen(repo, m, workspace_id: nil)

      assert [{"m-feat-a", {:left, :dirty}}] = sweep(repo)
    end

    test "read open, or a read of another link than the one recorded, stays", %{repo: repo} do
      m = mouse(repo, "feat-a")
      read_merged(m, state: "open")
      seen(repo, m, workspace_id: nil)
      assert [{"m-feat-a", {:left, :not_merged}}] = sweep(repo)

      read_merged(m, url: "https://gitlab.example.com/acme/app/-/merge_requests/6")
      assert [{"m-feat-a", {:left, :not_merged}}] = sweep(repo)
    end

    test "not quiet, stays", %{repo: repo} do
      m = mouse(repo, "feat-a", kind: "needs-decision", status: "sent")
      read_merged(m)
      seen(repo, m, workspace_id: nil)

      assert [{"m-feat-a", {:left, :waiting}}] = sweep(repo)
    end
  end

  describe "a sniff mouse whose build has landed" do
    defp research(repo) do
      sniff = mouse(repo, "research-a", commit: false, mode: "sniff")
      build = mouse(repo, "feat-a", built_from: sniff.question)
      {sniff, build}
    end

    defp kept_research(repo, sniff) do
      entry = %Whiska.Doorstep.Entry{
        mouse_id: sniff.id,
        branch: sniff.branch,
        worktree_root: sniff.path,
        stamped_at: ~U[2026-10-06 09:00:00Z],
        text: "found it",
        research: "# Found it\n"
      }

      :kept = Whiska.SpecArchive.keep_research(repo.checkout, entry)
      Path.join(Whiska.SpecArchive.dir(repo.checkout), "2026-10-06-research-a.research.md")
    end

    # Taken down as the sweep does it: stamped landed first when it landed.
    defp gone(repo, m, opts \\ []) do
      if opts[:landed], do: {:ok, _} = Storage.mark_landed(m.id)
      File.rm_rf!(m.path)
      GitRepo.git!(repo.checkout, ["worktree", "prune"])
      {:ok, _} = Storage.mark_removed(m.id)
    end

    test "goes on the sweep after its build is taken down, its research document kept",
         %{repo: repo} do
      {sniff, build} = research(repo)
      kept = kept_research(repo, sniff)
      GitRepo.land(repo, "feat-a")
      herdr(repo, [], [])

      assert [{"m-research-a", {:left, :build_standing}}, {"m-feat-a", :removed}] =
               sweep(repo)

      refute File.dir?(build.path)

      assert [{"m-research-a", :removed}] = sweep(repo)
      refute File.dir?(sniff.path)
      refute GitRepo.git!(repo.checkout, ["branch", "--list"]) =~ "research-a"
      assert %{removed_at: %DateTime{}} = Storage.mouse("m-research-a")
      assert File.read!(kept) == "# Found it\n"
    end

    test "stays while any build from it still stands", %{repo: repo} do
      {sniff, build} = research(repo)
      other = mouse(repo, "feat-b", built_from: sniff.question)
      GitRepo.land(repo, "feat-a")
      gone(repo, build, landed: true)
      seen(repo, other, workspace_id: nil)

      assert [{"m-research-a", {:left, :build_standing}}, {"m-feat-b", {:left, :not_merged}}] =
               sweep(repo)

      assert File.dir?(sniff.path)
    end

    test "stays when every build from it was dropped unmerged", %{repo: repo} do
      {sniff, build} = research(repo)
      gone(repo, build)
      herdr(repo, [], [])

      assert [{"m-research-a", {:left, :no_build_landed}}] = sweep(repo)
      assert File.dir?(sniff.path)
    end

    test "with no build from it, stays as any branch that never moved", %{repo: repo} do
      sniff = mouse(repo, "research-a", commit: false, mode: "sniff")
      herdr(repo, [], [])

      assert [{"m-research-a", {:left, :no_work_of_its_own}}] = sweep(repo)
      assert File.dir?(sniff.path)
    end

    test "with a file not committed, stays", %{repo: repo} do
      {sniff, build} = research(repo)
      GitRepo.land(repo, "feat-a")
      gone(repo, build, landed: true)
      File.write!(Path.join(sniff.path, "notes.md"), "mine")
      herdr(repo, [], [])

      assert [{"m-research-a", {:left, :dirty}}] = sweep(repo)
      assert File.dir?(sniff.path)
    end

    test "with a commit of its own, stays", %{repo: repo} do
      {sniff, build} = research(repo)
      GitRepo.commit!(sniff.path, "notes.md", "mine")
      GitRepo.land(repo, "feat-a")
      gone(repo, build, landed: true)
      herdr(repo, [], [])

      assert [{"m-research-a", {:left, :not_merged}}] = sweep(repo)
      assert File.dir?(sniff.path)
    end

    test "not quiet, stays, and goes once it is", %{repo: repo} do
      {sniff, build} = research(repo)
      GitRepo.land(repo, "feat-a")
      gone(repo, build, landed: true)
      seen(repo, sniff, pane: {"w1:p1", "working"}, workspace_id: "ws-3")

      assert [{"m-research-a", {:left, :working}}] = sweep(repo)

      seen(repo, sniff, pane: {"w1:p1", "idle"}, workspace_id: "ws-3")

      expect(Herdr, :remove_worktree, fn _, "ws-3" ->
        File.rm_rf!(sniff.path)
        :ok
      end)

      assert [{"m-research-a", :removed}] = sweep(repo)
    end

    test "goes once one build landed and the other was dropped unmerged", %{repo: repo} do
      {sniff, build} = research(repo)
      other = mouse(repo, "feat-b", built_from: sniff.question)
      GitRepo.land(repo, "feat-a")
      gone(repo, build, landed: true)
      gone(repo, other)
      herdr(repo, [], [])

      assert [{"m-research-a", :removed}] = sweep(repo)
    end

    test "on hold, stays", %{repo: repo} do
      {sniff, build} = research(repo)
      GitRepo.land(repo, "feat-a")
      gone(repo, build, landed: true)
      {:ok, _} = Storage.hold(sniff.id)
      herdr(repo, [], [])

      assert [{"m-research-a", {:left, :held}}] = sweep(repo)
    end

    test "flipped to sniff after it was shaped build, stays", %{repo: repo} do
      sniff = mouse(repo, "research-a", commit: false, mode: "sniff", shaped_as: "build")
      build = mouse(repo, "feat-a", built_from: sniff.question)
      GitRepo.land(repo, "feat-a")
      gone(repo, build, landed: true)
      herdr(repo, [], [])

      assert [{"m-research-a", {:left, :no_work_of_its_own}}] = sweep(repo)
    end

    test "a build fast-forwarded into the base goes as any branch does", %{repo: repo} do
      mouse(repo, "feat-a")
      GitRepo.git!(repo.checkout, ["merge", "--ff-only", "feat-a"])
      GitRepo.git!(repo.checkout, ["push", "origin", "main"])
      herdr(repo, [], [])

      assert [{"m-feat-a", :removed}] = sweep(repo)
    end

    test "with work of its own landed, goes as any branch does, its builds aside",
         %{repo: repo} do
      {sniff, _build} = research(repo)
      GitRepo.commit!(sniff.path, "notes.md", "mine")
      GitRepo.git!(sniff.path, ["push", "origin", "research-a"])
      GitRepo.land(repo, "research-a")
      herdr(repo, [], [])

      assert [{"m-research-a", :removed}, {"m-feat-a", {:left, :not_merged}}] = sweep(repo)
    end

    test "a build record a newer one took the folder from is gone", %{repo: repo} do
      {sniff, build} = research(repo)
      GitRepo.land(repo, "feat-a")
      {:ok, _} = Storage.mark_landed(build.id)

      {:ok, _} =
        Storage.record_mouse(%{mouse_id: "m-newer", path: build.path, branch: build.branch})

      File.rm_rf!(build.path)
      GitRepo.git!(repo.checkout, ["worktree", "prune"])
      {:ok, _} = Storage.mark_removed("m-newer")
      herdr(repo, [], [])

      assert {"m-research-a", :removed} in sweep(repo)
    end

    test "a sniff mouse fast-forwarded with no build goes as any branch does",
         %{repo: repo} do
      mouse(repo, "research-a", mode: "sniff")
      GitRepo.git!(repo.checkout, ["merge", "--ff-only", "research-a"])
      GitRepo.git!(repo.checkout, ["push", "origin", "main"])
      herdr(repo, [], [])

      assert [{"m-research-a", :removed}] = sweep(repo)
    end

    test "a build from a build mouse's question takes nothing down with it", %{repo: repo} do
      source = mouse(repo, "feat-src", commit: false)
      build = mouse(repo, "feat-a", built_from: source.question)
      GitRepo.land(repo, "feat-a")
      gone(repo, build, landed: true)
      herdr(repo, [], [])

      assert [{"m-feat-src", {:left, :no_work_of_its_own}}] = sweep(repo)
      assert File.dir?(source.path)
    end
  end

  describe "the four preconditions" do
    test "an unmerged branch stays, whatever else is true", %{repo: repo} do
      m = mouse(repo, "feat-a")
      seen(repo, m, workspace_id: nil)

      assert [{"m-feat-a", {:left, :not_merged}}] = sweep(repo)
      assert File.dir?(m.path)
    end

    test "a branch that never moved is not landed — a sniff mouse's worktree stays", %{repo: repo} do
      m = mouse(repo, "research-a", commit: false)
      seen(repo, m, workspace_id: nil)

      assert [{"m-research-a", {:left, :no_work_of_its_own}}] = sweep(repo)
      assert File.dir?(m.path)
      assert GitRepo.git!(repo.checkout, ["branch", "--list"]) =~ "research-a"
    end

    test "still stays once the base has moved on past it", %{repo: repo} do
      m = mouse(repo, "research-a", commit: false)
      GitRepo.commit!(repo.checkout, "later.md", "moved on")
      GitRepo.git!(repo.checkout, ["push", "origin", "main"])
      seen(repo, m, workspace_id: nil)

      assert [{"m-research-a", {:left, :no_work_of_its_own}}] = sweep(repo)
      assert File.dir?(m.path)
    end

    test "a branch whose reflog is gone is unknown, and unknown is not permission", %{repo: repo} do
      m = mouse(repo, "feat-a")
      GitRepo.land(repo, "feat-a")
      File.rm!(Path.join([repo.checkout, ".git", "logs", "refs", "heads", "feat-a"]))
      seen(repo, m, workspace_id: nil)

      assert [{"m-feat-a", {:left, :no_reflog}}] = sweep(repo)
      assert File.dir?(m.path)
    end

    test "a branch with work fast-forwarded into the base still goes", %{repo: repo} do
      m = mouse(repo, "feat-a")
      GitRepo.git!(repo.checkout, ["merge", "--ff-only", "feat-a"])
      GitRepo.git!(repo.checkout, ["push", "origin", "main"])
      seen(repo, m, workspace_id: nil)

      assert [{"m-feat-a", :removed}] = sweep(repo)
      refute File.dir?(m.path)
    end

    test "an uncommitted change stays, and herdr is never asked to force it", %{repo: repo} do
      m = mouse(repo, "feat-a")
      GitRepo.land(repo, "feat-a")
      GitRepo.dirty!(m.path)
      seen(repo, m, workspace_id: "ws-7")

      assert [{"m-feat-a", {:left, :dirty}}] = sweep(repo)
      assert File.dir?(m.path)
    end

    test "a branch merged into a base that was never pushed stays", %{repo: repo} do
      m = mouse(repo, "feat-b", push: false)
      GitRepo.land(repo, "feat-b", push: false)
      seen(repo, m, workspace_id: nil)

      assert [{"m-feat-b", {:left, :unpushed}}] = sweep(repo)
      assert File.dir?(m.path)
    end
  end

  describe "quiet" do
    test "a mouse mid-turn is never torn down", %{repo: repo} do
      m = mouse(repo, "feat-a", pane: "w1:p1")
      GitRepo.land(repo, "feat-a")
      seen(repo, m, pane: {"w1:p1", "working"})

      assert [{"m-feat-a", {:left, :working}}] = sweep(repo)
    end

    test "a pane waiting on a dialog is not quiet either", %{repo: repo} do
      m = mouse(repo, "feat-a", pane: "w1:p1")
      GitRepo.land(repo, "feat-a")
      seen(repo, m, pane: {"w1:p1", "blocked"})

      assert [{"m-feat-a", {:left, :working}}] = sweep(repo)
    end

    test "a pane herdr cannot classify is unknown, and unknown is not permission",
         %{repo: repo} do
      m = mouse(repo, "feat-a", pane: "w1:p1")
      GitRepo.land(repo, "feat-a")
      seen(repo, m, pane: {"w1:p1", "unknown"})

      assert [{"m-feat-a", {:left, :working}}] = sweep(repo)
    end

    test "a question still waiting on the person holds the worktree", %{repo: repo} do
      m = mouse(repo, "feat-a", kind: "needs-decision", status: "sent")
      GitRepo.land(repo, "feat-a")
      seen(repo, m, workspace_id: nil)

      assert [{"m-feat-a", {:left, :waiting}}] = sweep(repo)
    end

    test "the owl's own question is not the mouse's last word, and goes with the worktree",
         %{repo: repo} do
      m = mouse(repo, "feat-a")
      GitRepo.land(repo, "feat-a")
      seen(repo, m, workspace_id: nil)

      {:ok, owl} =
        Storage.record_question(%{
          mouse_id: m.id,
          text: "Drop?",
          kind: "needs-decision",
          status: "sent",
          asked_by: "owl"
        })

      assert [{"m-feat-a", :removed}] = sweep(repo)
      assert Storage.question(owl.id).status == "closed"
    end

    test "a mouse whose last word was not done stays, even with nothing waiting",
         %{repo: repo} do
      m = mouse(repo, "feat-a", kind: "unmarked", status: "answered")
      GitRepo.land(repo, "feat-a")
      seen(repo, m, workspace_id: nil)

      assert [{"m-feat-a", {:left, :not_finished}}] = sweep(repo)
    end

    test "latest is when the mouse asked, not the order the owl collected", %{repo: repo} do
      m = mouse(repo, "feat-a", kind: "done", status: "closed")
      GitRepo.land(repo, "feat-a")

      {:ok, _} =
        Storage.record_question(%{
          mouse_id: m.id,
          text: "which way?",
          kind: "needs-decision",
          status: "answered",
          asked_at: ~U[2026-01-01 09:00:00Z]
        })

      seen(repo, m, workspace_id: nil)

      assert [{"m-feat-a", :removed}] = sweep(repo)
    end

    test "done is the mouse's latest word, not any word it ever said", %{repo: repo} do
      m = mouse(repo, "feat-a")
      GitRepo.land(repo, "feat-a")

      {:ok, _} =
        Storage.record_question(%{
          mouse_id: m.id,
          text: "which way?",
          kind: "needs-decision",
          status: "answered"
        })

      seen(repo, m, workspace_id: nil)

      assert [{"m-feat-a", {:left, :not_finished}}] = sweep(repo)
    end

    test "a mouse that has said nothing at all stays", %{repo: repo} do
      m = mouse(repo, "feat-a", silent: true)
      GitRepo.land(repo, "feat-a")
      seen(repo, m, workspace_id: nil)

      assert [{"m-feat-a", {:left, :not_finished}}] = sweep(repo)
    end

    test "an uncollected turn on the doorstep holds it, however old the done", %{repo: repo} do
      m = mouse(repo, "feat-a")
      GitRepo.land(repo, "feat-a")

      {:ok, _} =
        Doorstep.leave(repo.checkout, %Whiska.Doorstep.Entry{
          mouse_id: m.id,
          branch: "feat-a",
          worktree_root: m.path,
          stamped_at: DateTime.utc_now(),
          text: "one more thing"
        })

      seen(repo, m, workspace_id: nil)

      assert [{"m-feat-a", {:left, :uncollected}}] = sweep(repo)
    end

    test "a held stop on the doorstep holds it too: its question has not been asked", %{
      repo: repo
    } do
      m = mouse(repo, "feat-a")
      GitRepo.land(repo, "feat-a")

      {:ok, _} =
        Doorstep.hold(repo.checkout, %Whiska.Doorstep.Entry{
          mouse_id: m.id,
          branch: "feat-a",
          worktree_root: m.path,
          stamped_at: DateTime.utc_now(),
          text: "Pick A or B?\n⁣⁣"
        })

      seen(repo, m, workspace_id: nil)

      assert [{"m-feat-a", {:left, :uncollected}}] = sweep(repo)
    end
  end

  describe "the pane herdr sees, not the one the record remembers" do
    test "a pane working in the worktree holds it, though the record lost its pane id",
         %{repo: repo} do
      m = mouse(repo, "feat-a")
      GitRepo.land(repo, "feat-a")

      herdr(repo, [%{path: m.path, branch: "feat-a", workspace_id: "ws-7"}], [
        %{
          pane_id: "w9:p9",
          cwd: Path.join(m.path, "lib"),
          agent: "claude",
          agent_status: "working"
        }
      ])

      assert [{"m-feat-a", {:left, :working}}] = sweep(repo)
      assert File.dir?(m.path)
    end

    test "a workspace herdr still has open with no pane in it is unexplained", %{repo: repo} do
      m = mouse(repo, "feat-a")
      GitRepo.land(repo, "feat-a")
      herdr(repo, [%{path: m.path, branch: "feat-a", workspace_id: "ws-7"}], [])

      assert [{"m-feat-a", {:left, :unknown_workspace}}] = sweep(repo)
      assert File.dir?(m.path)
    end

    test "a ready pane the record never matched still goes through herdr", %{repo: repo} do
      m = mouse(repo, "feat-a")
      GitRepo.land(repo, "feat-a")

      herdr(repo, [%{path: m.path, branch: "feat-a", workspace_id: "ws-7"}], [
        %{pane_id: "w9:p9", cwd: m.path, agent: "claude", agent_status: "idle"}
      ])

      expect(Herdr, :remove_worktree, fn _, "ws-7" ->
        File.rm_rf!(m.path)
        :ok
      end)

      assert [{"m-feat-a", :removed}] = sweep(repo)
    end
  end

  describe "unknown is never permission" do
    test "a live pane whose workspace herdr does not name is left alone", %{repo: repo} do
      m = mouse(repo, "feat-a", pane: "w1:p1")
      GitRepo.land(repo, "feat-a")
      seen(repo, m, pane: {"w1:p1", "idle"}, workspace_id: nil)

      assert [{"m-feat-a", {:left, :unknown_workspace}}] = sweep(repo)
      assert File.dir?(m.path)
    end

    test "a detached head is left alone", %{repo: repo} do
      m = mouse(repo, "feat-a")
      GitRepo.land(repo, "feat-a")
      GitRepo.git!(m.path, ["checkout", "--detach"])
      seen(repo, m, workspace_id: nil)

      assert [{"m-feat-a", {:left, :detached}}] = sweep(repo)
    end

    test "a worktree folder that is already gone is left alone", %{repo: repo} do
      m = mouse(repo, "feat-a")
      GitRepo.land(repo, "feat-a")
      File.rm_rf!(m.path)
      seen(repo, m, workspace_id: nil)

      assert [{"m-feat-a", {:left, :gone}}] = sweep(repo)
    end

    test "a base branch nobody can name stops the whole sweep", %{repo: repo} do
      m = mouse(repo, "feat-a")
      GitRepo.land(repo, "feat-a")
      GitRepo.git!(repo.checkout, ["remote", "remove", "origin"])
      GitRepo.git!(repo.checkout, ["branch", "-m", "main", "trunk"])
      seen(repo, m, workspace_id: nil)

      assert [{"m-feat-a", {:left, :ambiguous_base}}] = sweep(repo)
    end

    test "a herdr that will not answer stops the sweep without relabelling what it refused",
         %{repo: repo} do
      m = mouse(repo, "feat-a")
      mouse(repo, "feat-b")
      GitRepo.land(repo, "feat-a")
      stub(Herdr, :list_panes, fn _ -> {:error, :econnrefused} end)
      stub(Herdr, :worktrees, fn _, _ -> {:error, :econnrefused} end)

      assert [{"m-feat-a", {:left, :no_herdr}}, {"m-feat-b", {:left, :not_merged}}] = sweep(repo)
      assert File.dir?(m.path)
    end

    test "herdr's path and the record's are compared with symlinks resolved", %{repo: repo} do
      m = mouse(repo, "feat-a")
      GitRepo.land(repo, "feat-a")

      # herdr names the worktree through a symlink the record never went through.
      link =
        Path.join(System.tmp_dir!(), "whiska-cleanup-link-#{Whiska.Test.Unique.id()}")

      File.ln_s!(Path.dirname(m.path), link)
      on_exit(fn -> File.rm(link) end)
      aliased = Path.join(link, Path.basename(m.path))

      herdr(repo, [%{path: aliased, branch: "feat-a", workspace_id: "ws-7"}], [
        %{pane_id: "w9:p9", cwd: aliased, agent: "claude", agent_status: "idle"}
      ])

      expect(Herdr, :remove_worktree, fn _, "ws-7" ->
        File.rm_rf!(m.path)
        :ok
      end)

      assert [{"m-feat-a", :removed}] = sweep(repo)
    end

    test "a record that vanishes mid-teardown is reported, never a crash", %{repo: repo} do
      m = mouse(repo, "feat-a")
      GitRepo.land(repo, "feat-a")
      seen(repo, m, workspace_id: nil)

      expect(Herdr, :worktrees, fn _, _ ->
        Whiska.Repo.delete_all(Whiska.Schema.Question)
        Whiska.Repo.delete_all(Whiska.Schema.Mouse)
        {:ok, [%{path: m.path, branch: "feat-a", workspace_id: nil}]}
      end)

      assert [{"m-feat-a", {:removed, {:unrecorded, :no_such_mouse}}}] = sweep(repo)
      refute File.dir?(m.path)
    end

    test "herdr refusing the removal leaves the branch alone too", %{repo: repo} do
      m = mouse(repo, "feat-a", pane: "w1:p1")
      GitRepo.land(repo, "feat-a")
      seen(repo, m, pane: {"w1:p1", "idle"}, workspace_id: "ws-7")
      expect(Herdr, :remove_worktree, fn _, _ -> {:error, {:herdr, %{"code" => "dirty"}}} end)

      assert [{"m-feat-a", {:left, {:not_removed, _}}}] = sweep(repo)
      assert GitRepo.git!(repo.checkout, ["branch", "--list"]) =~ "feat-a"
      refute Storage.mouse("m-feat-a").removed_at
    end
  end

  describe "a removal git will not finish" do
    test "a branch checked out elsewhere is kept, and the worktree still goes", %{repo: repo} do
      m = mouse(repo, "feat-a")
      GitRepo.land(repo, "feat-a")
      seen(repo, m, workspace_id: nil)
      elsewhere = Path.join(repo.root, "elsewhere")
      GitRepo.git!(repo.checkout, ["worktree", "add", "--force", elsewhere, "feat-a"])

      assert [{"m-feat-a", {:removed, {:branch_kept, _}}}] = sweep(repo)
      refute File.dir?(m.path)
      assert %{removed_at: %DateTime{}} = Storage.mouse("m-feat-a")
    end

    test "a kept branch keeps its diff file", %{repo: repo} do
      m = mouse(repo, "feat-a")
      {:ok, diff} = Whiska.Review.write(repo.checkout, "feat-a", "+a\n")
      GitRepo.land(repo, "feat-a")
      seen(repo, m, workspace_id: nil)
      elsewhere = Path.join(repo.root, "elsewhere")
      GitRepo.git!(repo.checkout, ["worktree", "add", "--force", elsewhere, "feat-a"])

      assert [{"m-feat-a", {:removed, {:branch_kept, _}}}] = sweep(repo)
      assert File.exists?(diff)
    end
  end

  describe "a house with nothing to do" do
    test "sweeps nothing and asks herdr for nothing it does not need", %{repo: repo} do
      herdr(repo, [], [])
      assert [] = sweep(repo)
    end

    test "asks herdr nothing at all while no worktree has passed the local checks",
         %{repo: repo} do
      mouse(repo, "feat-a")
      assert [{"m-feat-a", {:left, :not_merged}}] = sweep(repo)
    end
  end
end
