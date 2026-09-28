defmodule Whiska.Owl.NudgeTest do
  @moduledoc """
  The nudge (ADR-0041): when a house gains something open that needs the
  person, the owl types one line into every *other* open house's idle main
  session so its statusline redraws. Gated by the target's delivery slot, never
  holding it; once per episode; never retried; never for a `done` report.
  """
  use ExUnit.Case, async: false

  import Mox

  alias Whiska.Doorstep
  alias Whiska.Doorstep.Entry
  alias Whiska.Herdr.Mock, as: Herdr
  alias Whiska.OpenHouses
  alias Whiska.Owl
  alias Whiska.Owl.House
  alias Whiska.Storage

  setup :set_mox_global
  setup :verify_on_exit!

  @socket "/fake/herdr.sock"
  @alpha_main "wA:p1"
  @alpha_mouse "wA:p2"
  @beta_main "wB:p1"
  @beta_mouse "wB:p2"
  @gamma_main "wG:p1"
  @wait 100

  setup do
    root = Path.join(System.tmp_dir!(), "whiska-nudge-#{System.unique_integer([:positive])}")
    alpha = repo(root, "alpha", @alpha_main, "ma", "feat-a")
    beta = repo(root, "beta", @beta_main, "mb", "feat-b")
    gamma = repo(root, "gamma", @gamma_main, "mg", "feat-g")
    File.rm_rf!(Path.dirname(OpenHouses.path()))
    on_exit(fn -> File.rm_rf!(root) end)

    # herdr's word on each main pane, changeable mid-test.
    {:ok, statuses} =
      Agent.start_link(fn ->
        %{@alpha_main => "idle", @beta_main => "idle", @gamma_main => "idle"}
      end)

    stub(Herdr, :list_panes, fn @socket ->
      {:ok,
       [
         %{pane_id: @alpha_mouse, cwd: worktree(alpha), agent: "claude", agent_status: "working"},
         %{pane_id: @beta_mouse, cwd: worktree(beta), agent: "claude", agent_status: "working"}
       ]}
    end)

    stub(Herdr, :subscribe, fn @socket, _subs, _ ->
      {:ok, spawn(fn -> receive do: (:stop -> :ok) end)}
    end)

    stub(Herdr, :pane, fn @socket, pane ->
      status = Agent.get(statuses, &Map.fetch!(&1, pane))
      {:ok, %{pane_id: pane, cwd: "/main", agent: "claude", agent_status: status}}
    end)

    test = self()

    stub(Herdr, :prompt, fn @socket, pane, text ->
      send(test, {:prompted, pane, text})
      :ok
    end)

    start_supervised!({Owl, herdr_socket: @socket, backstop_ms: 60_000, round_wait_ms: @wait})
    {:ok, a} = Owl.open_house(alpha)
    {:ok, b} = Owl.open_house(beta)
    House.sync(a)
    House.sync(b)

    {:ok, alpha: alpha, beta: beta, gamma: gamma, a: a, b: b, statuses: statuses}
  end

  # A repo with a house, one mouse on disk and a main session recorded.
  defp repo(root, name, main_pane, mouse_id, branch) do
    main = Path.join(root, name)
    File.mkdir_p!(Path.join(main, ".git"))
    File.mkdir_p!(worktree(main))
    {:ok, handle} = Storage.open(main, name: :seed)
    {:ok, _} = Storage.record_mouse(%{mouse_id: mouse_id, path: worktree(main), branch: branch})
    :ok = Storage.set_main_pane(main_pane)
    Storage.close(handle)
    main
  end

  defp worktree(main), do: Path.join([main, "worktrees", "wt"])

  defp leave(main, mouse_id, text) do
    {:ok, _} =
      Doorstep.leave(main, %Entry{
        mouse_id: mouse_id,
        branch: "feat",
        worktree_root: worktree(main),
        stamped_at: DateTime.utc_now(),
        text: text
      })
  end

  defp main_is(statuses, pane, status), do: Agent.update(statuses, &Map.put(&1, pane, status))

  defp in_house(house, fun) do
    Storage.point_at(House.repo(house))
    fun.()
  end

  defp idle(house, pane) do
    send(
      house,
      {:herdr_event, "pane.agent_status_changed", %{"pane_id" => pane, "agent_status" => "idle"}}
    )
  end

  test "the owl runs one Nudge process" do
    assert is_pid(Process.whereis(Whiska.Owl.Nudge))
  end

  test "a question opening in alpha nudges beta's idle main session, and alpha's own gets the question",
       %{alpha: alpha, a: a} do
    leave(alpha, "ma", "Which db?\n[worktree-status: needs-decision] pick one")
    House.collect(a)

    assert_receive {:prompted, @beta_main, nudge}, @wait
    assert nudge == "⚡ alpha waiting"

    assert_receive {:prompted, @alpha_main, question}, @wait * 3
    assert question =~ "#1"
    refute_receive {:prompted, _, _}, @wait
  end

  test "a nudge goes even while alpha's own main session is busy: it is about something open, not about delivery",
       %{alpha: alpha, a: a, statuses: statuses} do
    main_is(statuses, @alpha_main, "working")
    leave(alpha, "ma", "[worktree-status: needs-decision] ?")
    House.collect(a)

    assert_receive {:prompted, @beta_main, nudge}, @wait
    assert nudge =~ "alpha waiting"
    refute_receive {:prompted, @alpha_main, _}, @wait * 2
  end

  test "beta is nudged once per episode: not again while alpha stays open, again after it clears and reopens",
       %{alpha: alpha, a: a} do
    leave(alpha, "ma", "[worktree-status: needs-decision] one")
    House.collect(a)
    assert_receive {:prompted, @beta_main, _}, @wait
    assert_receive {:prompted, @alpha_main, _}, @wait * 3

    leave(alpha, "ma", "[worktree-status: needs-decision] two")
    House.collect(a)
    assert_receive {:prompted, @alpha_main, _}, @wait * 3
    refute_receive {:prompted, @beta_main, _}, @wait

    # Answered by hand; the house notices at its next collection.
    in_house(a, fn -> {:ok, _} = Storage.answer(2, "go") end)
    House.collect(a)
    refute_receive {:prompted, _, _}, @wait

    leave(alpha, "ma", "[worktree-status: needs-decision] three")
    House.collect(a)
    assert_receive {:prompted, @beta_main, _}, @wait
  end

  test "a busy beta gets nothing, and the skipped nudge is not retried when it idles", %{
    alpha: alpha,
    a: a,
    b: b,
    statuses: statuses
  } do
    main_is(statuses, @beta_main, "working")
    leave(alpha, "ma", "[worktree-status: needs-decision] ?")
    House.collect(a)
    assert_receive {:prompted, @alpha_main, _}, @wait * 3
    refute_receive {:prompted, @beta_main, _}, @wait

    main_is(statuses, @beta_main, "idle")
    idle(b, @beta_main)
    House.sync(b)
    refute_receive {:prompted, @beta_main, _}, @wait
  end

  test "beta with its own question out waiting for an answer gets nothing (ADR-0008's slot gates it)",
       %{alpha: alpha, beta: beta, a: a, b: b} do
    leave(beta, "mb", "[worktree-status: needs-decision] beta's own")
    House.collect(b)
    assert_receive {:prompted, @beta_main, own}, @wait * 3
    assert own =~ "#1"
    # Beta's question opening nudges alpha; that is the mirror case, not this one.
    assert_receive {:prompted, @alpha_main, _}, @wait

    leave(alpha, "ma", "[worktree-status: needs-decision] ?")
    House.collect(a)
    assert_receive {:prompted, @alpha_main, _}, @wait * 3
    refute_receive {:prompted, @beta_main, _}, @wait
  end

  test "a nudge never holds beta's slot: beta's own next question goes as soon as its pane is idle",
       %{alpha: alpha, beta: beta, a: a, b: b} do
    leave(alpha, "ma", "[worktree-status: needs-decision] ?")
    House.collect(a)
    assert_receive {:prompted, @beta_main, nudge}, @wait
    assert nudge =~ "alpha waiting"
    assert_receive {:prompted, @alpha_main, _}, @wait * 3

    in_house(b, fn ->
      assert Storage.sent() == nil
      assert Storage.questions() == []
    end)

    leave(beta, "mb", "[worktree-status: needs-decision] beta's own")
    House.collect(b)
    assert_receive {:prompted, @beta_main, own}, @wait * 3
    assert own =~ "needs a decision"
  end

  test "one line names every house with something open, never the target itself", %{
    alpha: alpha,
    beta: beta,
    gamma: gamma,
    a: a,
    b: b
  } do
    # Gamma is a quiet third house: only ever a target.
    {:ok, g} = Owl.open_house(gamma)
    House.sync(g)

    leave(alpha, "ma", "[worktree-status: needs-decision] ?")
    House.collect(a)
    assert_receive {:prompted, @beta_main, "⚡ alpha waiting"}, @wait
    assert_receive {:prompted, @gamma_main, "⚡ alpha waiting"}, @wait
    assert_receive {:prompted, @alpha_main, question}, @wait * 3
    assert question =~ "#1"

    # Beta opens while alpha is still waiting: gamma hears about both in one
    # line. Alpha's own question is out, so alpha's slot holds the nudge.
    leave(beta, "mb", "[worktree-status: needs-decision] ?")
    House.collect(b)
    assert_receive {:prompted, @gamma_main, "⚡ alpha, beta waiting"}, @wait
    assert_receive {:prompted, @beta_main, question}, @wait * 3
    assert question =~ "#1"
    refute_receive {:prompted, _, _}, @wait
  end

  test "a done report does not nudge: nothing can be acted on from elsewhere", %{
    alpha: alpha,
    a: a
  } do
    leave(alpha, "ma", "Merged.\n[worktree-status: done]")
    House.collect(a)
    assert_receive {:prompted, @alpha_main, report}, @wait * 3
    assert report =~ "finished"
    refute_receive {:prompted, @beta_main, _}, @wait
  end

  test "an unmarked stop nudges like a question (ADR-0009: a missing marker means deliver)",
       %{alpha: alpha, a: a} do
    leave(alpha, "ma", "I stopped.")
    House.collect(a)
    assert_receive {:prompted, @beta_main, _}, @wait
  end

  test "a house in the record that is not open is skipped; the source is never nudged", %{
    alpha: alpha,
    a: a
  } do
    OpenHouses.add("/nowhere/gamma")
    leave(alpha, "ma", "[worktree-status: needs-decision] ?")
    House.collect(a)

    assert_receive {:prompted, @beta_main, _}, @wait
    assert_receive {:prompted, @alpha_main, question}, @wait * 3
    assert question =~ "#1"
    refute_receive {:prompted, _, _}, @wait
    assert Process.alive?(Process.whereis(Whiska.Owl.Nudge))
  end
end
