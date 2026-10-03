defmodule Whiska.CleanupTest do
  @moduledoc """
  Taking a landed worktree down, pane and all (ADR-0061).

  Real git, a real house, and herdr faked at the one boundary that allows it
  (ADR-0031). Most of these tests are about *not* removing something: the four
  preconditions are the whole of the protection, and unknown is never
  permission.
  """
  use ExUnit.Case, async: false

  import Mox

  alias Whiska.Cleanup
  alias Whiska.Doorstep
  alias Whiska.Herdr.Mock, as: Herdr
  alias Whiska.Storage
  alias Whiska.Test.GitRepo

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    root = Path.join(System.tmp_dir!(), "whiska-cleanup-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    repo = GitRepo.create(root)
    {:ok, handle} = Storage.open(repo.checkout)

    on_exit(fn ->
      Storage.close(handle)
      File.rm_rf!(root)
    end)

    {:ok, repo: repo}
  end

  defp mouse(repo, branch, opts \\ []) do
    path = GitRepo.worktree(repo, branch, Keyword.take(opts, [:push]))
    id = "m-#{branch}"

    {:ok, _} =
      Storage.record_mouse(%{mouse_id: id, path: path, branch: branch, pane: opts[:pane]})

    unless opts[:silent] do
      {:ok, _} =
        Storage.record_question(%{
          mouse_id: id,
          text: "all done",
          kind: Keyword.get(opts, :kind, "done"),
          status: Keyword.get(opts, :status, "closed")
        })
    end

    %{id: id, path: path, branch: branch}
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

  describe "the four preconditions" do
    test "an unmerged branch stays, whatever else is true", %{repo: repo} do
      m = mouse(repo, "feat-a")
      seen(repo, m, workspace_id: nil)

      assert [{"m-feat-a", {:left, :not_merged}}] = sweep(repo)
      assert File.dir?(m.path)
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
      resolved = Whiska.Layout.canonical(m.path)
      refute resolved == m.path

      herdr(repo, [%{path: resolved, branch: "feat-a", workspace_id: "ws-7"}], [
        %{pane_id: "w9:p9", cwd: resolved, agent: "claude", agent_status: "idle"}
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
