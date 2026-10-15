defmodule Whiska.ReviewStartTest do
  @moduledoc """
  A fresh mouse for a merge request's review, over a real git repo and a fake
  herdr (ADR-0031).
  """
  # Serial: the house opens under the one VM-wide name `Whiska.Repo`.
  use ExUnit.Case, async: false

  import Mox

  alias Whiska.Herdr.Mock, as: Herdr
  alias Whiska.Marker
  alias Whiska.ReviewRound
  alias Whiska.ReviewStart
  alias Whiska.Storage
  alias Whiska.Test.GitRepo

  setup :verify_on_exit!

  @socket "/fake/herdr.sock"
  @url "https://gitlab.example.com/acme/app/-/merge_requests/7"

  setup do
    root = Path.join(System.tmp_dir!(), "whiska-rs-#{Whiska.Test.Unique.id()}")
    repo = GitRepo.create(root)
    path = Path.join([repo.checkout, "worktrees", "feat-a"])
    GitRepo.git!(repo.checkout, ["worktree", "add", "-b", "feat-a", path])
    GitRepo.commit!(path, "a.md", "work")
    GitRepo.git!(path, ["push", "-u", "origin", "feat-a"])
    {:ok, id} = Marker.read_or_mint(path)

    within(repo, fn ->
      {:ok, _} =
        Storage.record_mouse(%{mouse_id: id, path: path, branch: "feat-a", pane: "w1:p1"})

      {:ok, _} = Storage.record_merge_request(id, @url)
    end)

    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, repo: repo, path: path, id: id}
  end

  defp within(repo, fun), do: Storage.within(repo.checkout, fun)

  defp mouse(ctx), do: within(ctx.repo, fn -> Storage.mouse(ctx.id) end)

  defp run(ctx, mouse) do
    within(ctx.repo, fn ->
      ReviewStart.run(ctx.repo.checkout, mouse, "the letter\n", %{herdr: Herdr, socket: @socket})
    end)
  end

  defp herdr_starts(path) do
    expect(Herdr, :open_worktree, fn @socket, ^path, false ->
      {:ok, %{workspace_id: "w9", pane_id: "w9:p1", already_open?: false}}
    end)

    expect(Herdr, :start_agent, fn @socket, "w9:p1", "feat-a", args ->
      send(self(), {:args, args})
      {:ok, ["claude" | args]}
    end)

    expect(Herdr, :prompt, fn @socket, "w9:p1", text ->
      send(self(), {:prompt, text})
      :ok
    end)
  end

  test "a dropped worktree is made again from origin, and a review mouse starts there on the letter",
       ctx do
    head = GitRepo.git!(ctx.path, ["rev-parse", "HEAD"])
    GitRepo.git!(ctx.repo.checkout, ["worktree", "remove", "--force", ctx.path])
    GitRepo.git!(ctx.repo.checkout, ["branch", "-D", "feat-a"])
    within(ctx.repo, fn -> Storage.mark_removed(ctx.id) end)

    herdr_starts(ctx.path)
    assert {:ok, %{pane: "w9:p1", letter: letter}} = run(ctx, mouse(ctx))

    assert GitRepo.git!(ctx.path, ["rev-parse", "HEAD"]) == head
    assert File.read!(Marker.path(ctx.path)) =~ ctx.id
    assert File.read!(letter) == "the letter\n"
    assert Path.dirname(letter) == Path.join(ctx.path, ".whiska-letters")
    assert File.read!(Path.join(ctx.path, ".whiska-brief.md")) =~ "# Whiska: review mouse"

    assert_received {:args, args}
    assert ["--model", "sonnet" | _] = args
    assert Enum.chunk_every(args, 2, 1) |> Enum.member?(["--effort", "medium"])
    assert_received {:prompt, prompt}
    assert prompt == "Your task:\n\n" <> ReviewRound.line(letter)

    assert %{removed_at: nil, died_at: nil, pane: "w9:p1", mode: "build"} = mouse(ctx)
  end

  test "a worktree still there is opened as it is, never made again", ctx do
    within(ctx.repo, fn -> Storage.mark_dead(ctx.id) end)
    GitRepo.commit!(ctx.path, "b.md", "not pushed")
    head = GitRepo.git!(ctx.path, ["rev-parse", "HEAD"])

    herdr_starts(ctx.path)
    assert {:ok, %{pane: "w9:p1"}} = run(ctx, mouse(ctx))
    assert GitRepo.git!(ctx.path, ["rev-parse", "HEAD"]) == head
    assert %{died_at: nil} = mouse(ctx)
  end

  test "a start that fails once its worktree is open leaves the mouse dead, to be started again",
       ctx do
    within(ctx.repo, fn -> Storage.mark_dead(ctx.id) end)

    expect(Herdr, :open_worktree, fn @socket, _path, false ->
      {:ok, %{workspace_id: "w9", pane_id: "w9:p1", already_open?: false}}
    end)

    expect(Herdr, :start_agent, fn @socket, "w9:p1", "feat-a", _args -> {:error, :refused} end)

    assert {:error, :refused} = run(ctx, mouse(ctx))
    assert %{died_at: %DateTime{}} = mouse(ctx)
  end

  test "a Claude that started but never took its line is recorded alive, and its letter taken back",
       ctx do
    within(ctx.repo, fn -> Storage.mark_dead(ctx.id) end)

    expect(Herdr, :open_worktree, fn @socket, _path, false ->
      {:ok, %{workspace_id: "w9", pane_id: "w9:p1", already_open?: false}}
    end)

    expect(Herdr, :start_agent, fn @socket, "w9:p1", "feat-a", args -> {:ok, args} end)
    expect(Herdr, :prompt, fn @socket, "w9:p1", _text -> {:error, :refused} end)

    assert {:error, :refused} = run(ctx, mouse(ctx))
    assert %{died_at: nil, pane: "w9:p1"} = mouse(ctx)
    assert [] = Path.wildcard(Path.join(ctx.path, ".whiska-letters/*.md"))
  end

  test "a worktree already open with an agent running in it is never started into", ctx do
    within(ctx.repo, fn -> Storage.mark_dead(ctx.id) end)
    path = ctx.path

    expect(Herdr, :open_worktree, fn @socket, ^path, false ->
      {:ok, %{workspace_id: "w9", pane_id: "w9:p1", already_open?: true}}
    end)

    expect(Herdr, :list_panes, fn @socket ->
      {:ok, [%{pane_id: "w9:p2", cwd: path, agent: "claude", agent_status: "idle"}]}
    end)

    assert {:error, :agent_running} = run(ctx, mouse(ctx))
    assert %{died_at: %DateTime{}} = mouse(ctx)
  end

  test "a worktree already open with only a shell in it is started in", ctx do
    within(ctx.repo, fn -> Storage.mark_dead(ctx.id) end)
    path = ctx.path

    expect(Herdr, :open_worktree, fn @socket, ^path, false ->
      {:ok, %{workspace_id: "w9", pane_id: "w9:p1", already_open?: true}}
    end)

    expect(Herdr, :list_panes, fn @socket ->
      {:ok, [%{pane_id: "w9:p1", cwd: path, agent: nil, agent_status: nil}]}
    end)

    expect(Herdr, :start_agent, fn @socket, "w9:p1", "feat-a", args -> {:ok, args} end)
    expect(Herdr, :prompt, fn @socket, "w9:p1", _text -> :ok end)

    assert {:ok, %{pane: "w9:p1"}} = run(ctx, mouse(ctx))
    assert %{died_at: nil} = mouse(ctx)
  end

  test "a worktree another mouse's marker names is left alone", ctx do
    within(ctx.repo, fn -> Storage.mark_dead(ctx.id) end)
    File.write!(Marker.path(ctx.path), "someone-else\n")

    assert {:error, :not_this_mouse} = run(ctx, mouse(ctx))
  end

  test "a branch recorded anywhere but worktrees/<branch> is not made again", ctx do
    GitRepo.git!(ctx.repo.checkout, ["worktree", "remove", "--force", ctx.path])
    within(ctx.repo, fn -> Storage.mark_removed(ctx.id) end)
    moved = %{mouse(ctx) | path: Path.join(ctx.repo.root, "elsewhere/feat-a")}

    assert {:error, :not_where_spawned} = run(ctx, moved)
    refute File.exists?(ctx.path)
  end
end
