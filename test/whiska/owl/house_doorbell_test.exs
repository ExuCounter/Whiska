defmodule Whiska.Owl.HouseDoorbellTest do
  @moduledoc """
  The house ringing a mouse's doorbell again on its backstop while an answer
  the person saved has not been taken (ADR-next-an-answer-is-taken-not-typed).

  A real house with herdr faked at its one boundary (ADR-0031). The backstop is
  driven by hand, one sweep per `:backstop`, and the spacing between rings is
  wound down to nothing.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO
  import Mox

  alias Whiska.AnswerFlag
  alias Whiska.Desktop.Mock, as: Desktop
  alias Whiska.Doorbell
  alias Whiska.Herdr.Mock, as: Herdr
  alias Whiska.Owl.House
  alias Whiska.Storage
  alias Whiska.Test.GitRepo

  setup :verify_on_exit!

  @socket "/fake/herdr.sock"
  @screens Path.expand("../../support/screens", __DIR__)

  setup do
    root = Path.join(System.tmp_dir!(), "whiska-hd-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    repo = GitRepo.create(root)
    path = GitRepo.worktree(repo, "feat-a")

    in_house(repo, fn ->
      {:ok, _} = Storage.record_mouse(%{mouse_id: "ma", path: path, branch: "feat-a"})
    end)

    stub(Herdr, :subscribe, fn @socket, _subs, _listener -> {:ok, spawn(fn -> :ok end)} end)

    stub(Herdr, :worktrees, fn @socket, _checkout ->
      {:ok, [%{path: path, branch: "feat-a", workspace_id: "ws-1"}]}
    end)

    stub(Herdr, :list_panes, fn @socket -> {:ok, [pane(path, "done")]} end)
    stub(Herdr, :read_screen, fn _, _ -> {:error, :no_screen} end)
    stub(Herdr, :pane, fn _, _ -> {:error, :no_pane} end)

    test_pid = self()

    stub(Herdr, :prompt, fn @socket, pane, line ->
      send(test_pid, {:typed, pane, line})
      :ok
    end)

    stub(Herdr, :notify, fn @socket, hoot ->
      send(test_pid, {:hoot, hoot})
      {:ok, :shown}
    end)

    stub(Desktop, :notify, fn _hoot -> :ok end)

    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, repo: repo, path: path}
  end

  defp in_house(repo, fun) do
    {:ok, handle} = Storage.open(repo.checkout, name: nil)

    try do
      fun.()
    after
      Storage.close(handle)
    end
  end

  defp pane(path, status, id \\ "w1:p1") do
    %{pane_id: id, cwd: path, agent: "claude", agent_status: status, title: nil, session: nil}
  end

  # An answer `reply` saved, whose own doorbell did not ring.
  defp answered(repo, attrs \\ []) do
    in_house(repo, fn ->
      {:ok, q} =
        Storage.record_question(%{mouse_id: "ma", text: "which?", kind: "needs-decision"})

      {:ok, _} = Storage.answer(q.id, "SQLite")
      {:ok, _} = Storage.set_ring(q.id, attrs[:rung_at], attrs[:rings] || 0)
      q
    end)
  end

  # One backstop sweep, run to completion. The house is opened with a backstop
  # nobody waits for, so the only sweeps are the ones a test sends.
  defp sweep(house) do
    send(house, :backstop)
    House.sync(house)
  end

  defp open(repo, opts \\ []) do
    name = :"house-#{System.unique_integer([:positive])}"
    allow(Herdr, self(), fn -> Process.whereis(name) end)
    allow(Desktop, self(), fn -> Process.whereis(name) end)

    house =
      start_supervised!(
        {House,
         [
           name: name,
           main_checkout: repo.checkout,
           herdr_socket: @socket,
           desktop: Desktop,
           backstop_ms: 3_600_000,
           board_ms: 3_600_000,
           ring_ms: Keyword.get(opts, :ring_ms, 0),
           away_path: Keyword.get(opts, :away_path, Path.join(repo.root, "not-away"))
         ]}
      )

    House.sync(house)
    house
  end

  defp quietly(fun), do: with_io(:stderr, fun) |> elem(0)

  test "rings an idle mouse whose answer was not taken, and counts the ring", %{
    repo: repo,
    path: path
  } do
    q = answered(repo)

    quietly(fn -> repo |> open() |> sweep() end)

    assert_received {:typed, "w1:p1", line}
    assert line == Doorbell.line(q.id)
    in_house(repo, fn -> assert %{rings: 1, rung_at: %DateTime{}} = Storage.question(q.id) end)
    assert AnswerFlag.set?(path)
  end

  test "rings at most three times, then marks it not taken and hoots once", %{repo: repo} do
    q = answered(repo, rung_at: ~U[2026-01-01 00:00:00Z], rings: 2)

    {_, log} =
      with_io(:stderr, fn ->
        house = open(repo)
        sweep(house)
        sweep(house)
        sweep(house)
      end)

    assert_received {:typed, "w1:p1", _third}
    refute_received {:typed, _, _}
    assert_received {:hoot, hoot}
    refute_received {:hoot, _}
    assert hoot.title =~ "feat-a"
    assert hoot.body =~ "##{q.id}"
    in_house(repo, fn -> assert %{rings: 3, stale_at: %DateTime{}} = Storage.question(q.id) end)
    assert log =~ "not taken"
  end

  test "a herdr client that crashes on the ring leaves the count as it was", %{repo: repo} do
    q = answered(repo)
    stub(Herdr, :prompt, fn @socket, _pane, _line -> exit(:badarg) end)

    quietly(fn -> repo |> open() |> sweep() end)

    in_house(repo, fn -> assert %{rings: 0, rung_at: nil} = Storage.question(q.id) end)
  end

  test "an answer that was taken is never rung", %{repo: repo} do
    q = answered(repo)
    in_house(repo, fn -> Storage.take([q.id], DateTime.utc_now()) end)

    quietly(fn -> repo |> open() |> sweep() end)

    refute_received {:typed, _, _}
  end

  test "stops ringing once the mouse asks a newer question (ADR-0005)", %{repo: repo} do
    q = answered(repo)

    in_house(repo, fn ->
      Storage.record_question(%{mouse_id: "ma", text: "next?", kind: "needs-decision"})
    end)

    quietly(fn -> repo |> open() |> sweep() end)

    line = Doorbell.line(q.id)
    refute_received {:typed, "w1:p1", ^line}
  end

  test "stops ringing once the mouse's branch has landed (ADR-0064)", %{repo: repo} do
    answered(repo)
    in_house(repo, fn -> {:ok, _} = Storage.mark_landed("ma") end)

    quietly(fn -> repo |> open() |> sweep() end)

    refute_received {:typed, _, _}
  end

  test "rings again only once ring_ms has passed since the last doorbell", %{repo: repo} do
    q = answered(repo, rung_at: DateTime.utc_now())

    quietly(fn -> repo |> open(ring_ms: 3_600_000) |> sweep() end)

    refute_received {:typed, _, _}
    in_house(repo, fn -> assert Storage.question(q.id).rings == 0 end)
  end

  test "gives up only once ring_ms has passed since the third ring", %{repo: repo} do
    q = answered(repo, rung_at: DateTime.utc_now(), rings: 3)

    quietly(fn -> repo |> open(ring_ms: 3_600_000) |> sweep() end)

    refute_received {:hoot, _}
    in_house(repo, fn -> assert Storage.question(q.id).stale_at == nil end)
  end

  test "while the person is away it keeps ringing but waits to give up until they are back",
       %{repo: repo} do
    q = answered(repo, rung_at: ~U[2026-01-01 00:00:00Z], rings: 3)
    away = Path.join(repo.root, "away")
    File.write!(away, "")

    quietly(fn ->
      house = open(repo, away_path: away)
      sweep(house)
      refute_received {:hoot, _}
      in_house(repo, fn -> assert Storage.question(q.id).stale_at == nil end)

      File.rm!(away)
      sweep(house)
    end)

    assert_received {:hoot, _}
    in_house(repo, fn -> assert %DateTime{} = Storage.question(q.id).stale_at end)
  end

  test "waits while the mouse's pane is busy, and the wait uses up no ring", %{
    repo: repo,
    path: path
  } do
    q = answered(repo)
    stub(Herdr, :list_panes, fn @socket -> {:ok, [pane(path, "working")]} end)

    quietly(fn -> repo |> open() |> sweep() end)

    refute_received {:typed, _, _}
    in_house(repo, fn -> assert Storage.question(q.id).rings == 0 end)
  end

  test "never rings a held mouse", %{repo: repo} do
    answered(repo)
    in_house(repo, fn -> {:ok, _} = Storage.hold("ma") end)

    quietly(fn -> repo |> open() |> sweep() end)

    refute_received {:typed, _, _}
  end

  test "never rings into the main session's pane (ADR-0053)", %{repo: repo, path: path} do
    q = answered(repo)
    in_house(repo, fn -> Storage.set_main_pane("w1:p1") end)
    stub(Herdr, :list_panes, fn @socket -> {:ok, [pane(path, "done")]} end)

    quietly(fn -> repo |> open() |> sweep() end)

    line = Doorbell.line(q.id)
    refute_received {:typed, "w1:p1", ^line}
  end

  test "holds off while the person has a draft in the mouse's prompt box", %{repo: repo} do
    q = answered(repo)

    stub(Herdr, :read_screen, fn _, _ ->
      {:ok, File.read!(Path.join(@screens, "box-holds-a-draft.txt"))}
    end)

    quietly(fn -> repo |> open() |> sweep() end)

    refute_received {:typed, _, _}
    in_house(repo, fn -> assert Storage.question(q.id).rings == 0 end)
  end

  test "the doorbell does not read as a line the owl delivers to the main session" do
    refute String.starts_with?(Doorbell.line(12), "🐱")
  end
end
