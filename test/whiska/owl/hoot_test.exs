defmodule Whiska.Owl.HootTest do
  @moduledoc """
  When the owl raises a desktop notification, and what happens when it cannot
  (ADR-0062). One hoot per delivered question, at the moment the line is typed;
  a question merely collected and held is not on the person's screen yet, so it
  does not hoot. A hoot that fails never costs the delivery.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO
  import Mox

  alias Whiska.Doorstep
  alias Whiska.Doorstep.Entry
  alias Whiska.Herdr.Mock, as: Herdr
  alias Whiska.Owl.House
  alias Whiska.Storage

  setup :verify_on_exit!

  @socket "/fake/herdr.sock"
  @main_pane "w1:p2"
  @mouse_pane "w1R:p1"
  @wait 100
  # The longest a message the house owes may take: the suite runs in parallel,
  # so this is slack, never the thing tested. A refute still waits only @wait.
  @arrives 2_000

  setup do
    root = Path.join(System.tmp_dir!(), "whiska-hoot-#{System.unique_integer([:positive])}")
    main = Path.join(root, "myrepo")
    File.mkdir_p!(Path.join(main, ".git"))
    on_exit(fn -> File.rm_rf!(root) end)

    a = Path.join([main, "worktrees", "feat-a"])
    File.mkdir_p!(a)

    {:ok, handle} = Storage.open(main, name: nil)
    {:ok, _} = Storage.record_mouse(%{mouse_id: "ma", path: a, branch: "feat-a"})
    :ok = Storage.set_main_pane(@main_pane)
    Storage.close(handle)

    stub(Herdr, :list_panes, fn @socket ->
      {:ok, [%{pane_id: @mouse_pane, cwd: a, agent: "claude", agent_status: "working"}]}
    end)

    stub(Herdr, :subscribe, fn @socket, _subs, _listener ->
      {:ok, spawn(fn -> receive do: (:stop -> :ok) end)}
    end)

    box_holds("")
    stub(Herdr, :prompt, fn @socket, _pane, _text -> :ok end)

    {:ok, main: main, a: a}
  end

  # Claude Code's prompt box, framed the way it is drawn on the screen, with
  # whatever the person has half-typed in it (ADR-0047, ADR-0068).

  # The house calls herdr from its own process, from `init/1` on, so it is
  # allowed in by name before it starts — which is what lets this file run async.
  defp start_house(opts) do
    name = :"house-#{System.unique_integer([:positive])}"
    allow(Herdr, self(), fn -> Process.whereis(name) end)
    start_supervised!({House, [name: name] ++ opts})
  end

  defp box_holds(draft) do
    rule = String.duplicate("─", 40)
    screen = "✻ Baked for 46s\n\n#{rule}\n❯\u00a0#{draft}\n#{rule}\n  ⏵⏵ auto mode on\n"

    stub(Herdr, :read_screen, fn @socket, @main_pane -> {:ok, screen} end)
  end

  defp open(main) do
    pid =
      start_house(
        main_checkout: main,
        herdr_socket: @socket,
        backstop_ms: 60_000,
        round_wait_ms: @wait
      )

    House.sync(pid)
    pid
  end

  defp main_is(status) do
    stub(Herdr, :pane, fn @socket, @main_pane ->
      {:ok, %{pane_id: @main_pane, cwd: "/main", agent: "claude", agent_status: status}}
    end)
  end

  defp leave(main, root, text) do
    {:ok, _} =
      Doorstep.leave(main, %Entry{
        mouse_id: "ma",
        branch: "feat-a",
        worktree_root: root,
        stamped_at: DateTime.utc_now(),
        text: text
      })
  end

  defp expect_hoots(answer \\ :ok) do
    test = self()

    stub(Herdr, :notify, fn @socket, notification ->
      send(test, {:hooted, notification})
      answer
    end)
  end

  test "one hoot goes out with the line, naming the house and the branch", %{main: main, a: a} do
    main_is("idle")
    expect_hoots()
    house = open(main)

    leave(main, a, "Which db?\n[worktree-status: needs-decision] pick one")
    House.collect(house)

    assert_receive {:hooted, hoot}, @arrives
    assert hoot.title == "🐱 myrepo · feat-a needs a decision"
    assert hoot.body == ~s(#1 · "pick one")
    assert hoot.sound == :request

    refute_receive {:hooted, _}, @wait
  end

  test "a finished branch hoots too, with the quieter sound", %{main: main, a: a} do
    main_is("idle")
    expect_hoots()
    house = open(main)

    leave(main, a, "Merged and pushed.\n[worktree-status: done]")
    House.collect(house)

    assert_receive {:hooted, %{title: title, sound: :done}}, @arrives
    assert title =~ "feat-a finished"
  end

  test "a question held behind a busy session does not hoot until it is typed", %{
    main: main,
    a: a
  } do
    main_is("working")
    expect_hoots()
    house = open(main)

    leave(main, a, "[worktree-status: needs-decision] pick one")
    House.collect(house)
    refute_receive {:hooted, _}, @wait * 2

    main_is("idle")

    send(
      house,
      {:herdr_event, "pane.agent_status_changed",
       %{"pane_id" => @main_pane, "agent_status" => "idle"}}
    )

    assert_receive {:hooted, _}, @arrives
  end

  test "a question held behind a half-typed prompt does not hoot (ADR-0047)", %{
    main: main,
    a: a
  } do
    main_is("idle")
    expect_hoots()
    box_holds("rebase onto")
    house = open(main)

    leave(main, a, "[worktree-status: needs-decision] pick one")
    House.collect(house)

    refute_receive {:hooted, _}, @wait * 3
  end

  test "a line herdr refuses to type does not hoot", %{main: main, a: a} do
    main_is("idle")
    expect_hoots()
    stub(Herdr, :prompt, fn @socket, _pane, _text -> {:error, :agent_blocked} end)
    house = open(main)

    capture_io(:stderr, fn ->
      leave(main, a, "[worktree-status: needs-decision] pick one")
      House.collect(house)
      refute_receive {:hooted, _}, @wait * 3
    end)
  end

  test "a hoot herdr refuses leaves the delivery exactly as it was", %{main: main, a: a} do
    test = self()
    main_is("idle")
    expect_hoots({:error, :no_such_method})

    stub(Herdr, :prompt, fn @socket, pane, text ->
      send(test, {:prompted, pane, text})
      :ok
    end)

    house = open(main)

    leave(main, a, "[worktree-status: needs-decision] pick one")
    House.collect(house)

    assert_receive {:prompted, @main_pane, _}, @arrives
    assert_receive {:hooted, _}, @arrives
    assert Process.alive?(house)

    House.sync(house)
    Storage.point_at(House.repo(house))
    assert Storage.question(1).status == "sent"
  end

  test "a hoot that raises never takes the house down with it", %{main: main, a: a} do
    test = self()
    main_is("idle")

    stub(Herdr, :notify, fn @socket, _notification ->
      send(test, :hooted)
      raise "herdr went away mid-call"
    end)

    house = open(main)

    capture_io(:stderr, fn ->
      leave(main, a, "[worktree-status: needs-decision] pick one")
      House.collect(house)
      assert_receive :hooted, @arrives
      House.sync(house)
    end)

    assert Process.alive?(house)
    Storage.point_at(House.repo(house))
    assert Storage.question(1).status == "sent"
  end
end
