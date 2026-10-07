defmodule Whiska.Owl.GateLogTest do
  @moduledoc """
  What the owl's log says about a held delivery (ADR-0058). The gate itself
  does not change (ADR-0008, ADR-0047); the log only says what it decided, and
  when — the one record of why a question waited.

  Not async: the log is the owl's stderr, and capturing a named device is only
  sound while nothing else is running.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import Mox

  alias Whiska.Doorstep
  alias Whiska.Doorstep.Entry
  alias Whiska.Herdr.Mock, as: Herdr
  alias Whiska.Owl.House
  alias Whiska.Storage

  setup :set_mox_global
  setup :verify_on_exit!
  setup {Whiska.Test.QuietSidebar, :stub_sidebar}

  @socket "/fake/herdr.sock"
  @main_pane "w1:p2"
  @mouse_pane "w1R:p1"
  @arrives 2_000

  setup do
    root = Path.join(System.tmp_dir!(), "whiska-gatelog-#{System.unique_integer([:positive])}")
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

    stub(Herdr, :notify, fn @socket, _notification -> :ok end)

    test = self()

    stub(Herdr, :prompt, fn @socket, pane, text ->
      send(test, {:prompted, pane, text})
      :ok
    end)

    box_holds("")
    {:ok, main: main, a: a}
  end

  defp open(main) do
    pid =
      start_supervised!(
        {House,
         [
           name: :"gate-log-house-#{System.unique_integer([:positive])}",
           main_checkout: main,
           herdr_socket: @socket,
           backstop_ms: 60_000,
           round_wait_ms: 100
         ]}
      )

    House.sync(pid)
    pid
  end

  defp main_is(status, agent \\ "claude") do
    stub(Herdr, :pane, fn @socket, @main_pane ->
      {:ok, %{pane_id: @main_pane, cwd: "/main", agent: agent, agent_status: status}}
    end)
  end

  defp box_holds(draft) do
    screen = """
    ✻ Baked for 46s · done 2:44 PM

    ────────────────────────────────────
    ❯\u00a0#{draft}
    ────────────────────────────────────
      ⏵⏵ auto mode on (shift+tab to cycle)
    """

    stub(Herdr, :read_screen, fn @socket, @main_pane -> {:ok, screen} end)
  end

  defp screen_is(screen),
    do: stub(Herdr, :read_screen, fn @socket, @main_pane -> {:ok, screen} end)

  defp first_attempt(house, main, a) do
    {:ok, _} =
      Doorstep.leave(main, %Entry{
        mouse_id: "ma",
        branch: "feat-a",
        worktree_root: a,
        stamped_at: DateTime.utc_now(),
        text: "[worktree-status: needs-decision] ?"
      })

    House.collect(house)
    Process.sleep(250)
    House.sync(house)
  end

  defp attempt(house) do
    send(
      house,
      {:herdr_event, "pane.agent_status_changed",
       %{"pane_id" => @main_pane, "agent_status" => "idle"}}
    )

    House.sync(house)
  end

  test "a hold's start names the question, the reason and herdr's status for the pane",
       %{main: main, a: a} do
    main_is("idle")
    box_holds("half a sentence")
    house = open(main)

    log = capture_io(:stderr, fn -> first_attempt(house, main, a) end)

    assert log =~ ~r/#1\b.*typing.*idle/
  end

  test "a hold's reason is the main pane's status when the model is mid-turn",
       %{main: main, a: a} do
    main_is("working")
    house = open(main)

    log = capture_io(:stderr, fn -> first_attempt(house, main, a) end)

    assert log =~ ~r/#1\b.*mid_turn.*working/
  end

  test "the same answer again logs nothing", %{main: main, a: a} do
    main_is("idle")
    box_holds("half a sentence")
    house = open(main)
    capture_io(:stderr, fn -> first_attempt(house, main, a) end)

    log =
      capture_io(:stderr, fn ->
        attempt(house)
        attempt(house)
      end)

    assert log == ""
  end

  test "a new reason is a line, and it says how long the hold has lasted", %{main: main, a: a} do
    main_is("idle")
    box_holds("half a sentence")
    house = open(main)
    capture_io(:stderr, fn -> first_attempt(house, main, a) end)

    screen_is("a dialog is up\n")
    log = capture_io(:stderr, fn -> attempt(house) end)

    assert log =~ ~r/#1\b.*no_box.*idle/
    assert log =~ ~r/gated \d/
  end

  test "the end of a hold is a line, with how long it held", %{main: main, a: a} do
    main_is("idle")
    box_holds("half a sentence")
    house = open(main)
    capture_io(:stderr, fn -> first_attempt(house, main, a) end)

    box_holds("")

    log =
      capture_io(:stderr, fn ->
        attempt(house)
        assert_receive {:prompted, @main_pane, _}, @arrives
      end)

    assert log =~ ~r/#1\b.*no longer gated.*gated \d/
  end

  test "a refused pane lookup is held as unreachable", %{main: main, a: a} do
    stub(Herdr, :pane, fn @socket, @main_pane -> {:error, :boom} end)
    house = open(main)

    log = capture_io(:stderr, fn -> first_attempt(house, main, a) end)

    assert log =~ ~r/#1\b.*unreachable/
  end

  test "every line starts with the local time", %{main: main, a: a} do
    main_is("working")
    house = open(main)

    log = capture_io(:stderr, fn -> first_attempt(house, main, a) end)

    lines = String.split(log, "\n", trim: true)
    assert lines != []
    assert Enum.all?(lines, &(&1 =~ ~r/^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d /))
  end

  test "a hold about the box leaves the screen as read in one file, not in the log",
       %{main: main, a: a} do
    main_is("idle")
    box_holds("my secret draft")
    house = open(main)

    log = capture_io(:stderr, fn -> first_attempt(house, main, a) end)

    file = Path.join(main, ".git/whiska/gate-screen")
    assert File.read!(file) =~ "my secret draft"
    refute log =~ "my secret draft"
    assert Bitwise.band(File.stat!(file).mode, 0o077) == 0

    box_holds("a newer draft")
    capture_io(:stderr, fn -> attempt(house) end)

    assert File.read!(file) =~ "a newer draft"
    refute File.read!(file) =~ "my secret draft"
  end

  test "a change of reason keeps the clock running and says how long", %{main: main, a: a} do
    main_is("idle")
    box_holds("half a sentence")
    house = open(main)
    capture_io(:stderr, fn -> first_attempt(house, main, a) end)

    :sys.replace_state(house, fn state ->
      %{state | held_since: DateTime.add(DateTime.utc_now(), -125, :second)}
    end)

    screen_is("a dialog is up\n")
    log = capture_io(:stderr, fn -> attempt(house) end)

    assert log =~ "gated 2m 5s"
  end

  test "an attempt with nothing gated logs nothing", %{main: main} do
    main_is("idle")
    house = open(main)

    assert capture_io(:stderr, fn -> attempt(house) end) == ""
  end

  test "a screen file that cannot be written does not change what the gate decides",
       %{main: main, a: a} do
    File.mkdir_p!(Path.join(main, ".git/whiska/gate-screen/in-the-way"))
    main_is("idle")
    box_holds("half a sentence")
    house = open(main)

    log = capture_io(:stderr, fn -> first_attempt(house, main, a) end)

    assert log =~ ~r/#1\b.*typing/
    assert House.held(house) == :typing
    refute_received {:prompted, _, _}
  end

  test "the screen file's directory is closed to everyone else", %{main: main, a: a} do
    main_is("idle")
    box_holds("my secret draft")
    house = open(main)

    capture_io(:stderr, fn -> first_attempt(house, main, a) end)

    dir = Path.join(main, ".git/whiska")
    assert Bitwise.band(File.stat!(dir).mode, 0o077) == 0
    assert Path.wildcard(Path.join(dir, "gate-screen.tmp-*")) == []
  end

  test "a hold that is not about the box leaves no screen file", %{main: main, a: a} do
    main_is("working")
    house = open(main)

    capture_io(:stderr, fn -> first_attempt(house, main, a) end)

    refute File.exists?(Path.join(main, ".git/whiska/gate-screen"))
  end
end
