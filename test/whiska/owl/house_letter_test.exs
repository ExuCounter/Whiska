defmodule Whiska.Owl.HouseLetterTest do
  @moduledoc """
  A letter another repo's main session left in this house (`whiska tell`),
  typed into this house's own main session by its own delivery (ADR-0044). It
  waits for away and for the gate (ADR-0047, ADR-0079), never for the slot or a
  focus, and goes ahead of the questions queued (ADR-0008).
  """
  use ExUnit.Case, async: true

  import Mox

  alias Whiska.Desktop.Mock, as: Desktop
  alias Whiska.Doorstep
  alias Whiska.Doorstep.Entry
  alias Whiska.Herdr.Mock, as: Herdr
  alias Whiska.Owl.House
  alias Whiska.Storage

  setup :verify_on_exit!
  setup {Whiska.Test.QuietSidebar, :stub_sidebar}

  @socket "/fake/herdr.sock"
  @main_pane "w1:p2"
  @mouse_pane "w1R:p1"
  @wait 100
  @arrives 2_000

  setup do
    root = Path.join(System.tmp_dir!(), "whiska-letter-#{Whiska.Test.Unique.id()}")
    main = Path.join(root, "myrepo")
    File.mkdir_p!(Path.join(main, ".git"))
    on_exit(fn -> File.rm_rf!(root) end)

    a = Path.join([main, "worktrees", "feat-a"])
    File.mkdir_p!(a)

    seed(main, fn ->
      {:ok, _} = Storage.record_mouse(%{mouse_id: "ma", path: a, branch: "feat-a"})
      :ok = Storage.set_main_pane(@main_pane)
    end)

    stub(Herdr, :list_panes, fn @socket ->
      {:ok, [%{pane_id: @mouse_pane, cwd: a, agent: "claude", agent_status: "working"}]}
    end)

    stub(Herdr, :subscribe, fn @socket, _subs, _listener ->
      {:ok, spawn(fn -> receive do: (:stop -> :ok) end)}
    end)

    stub(Desktop, :notify, fn _notification -> {:ok, "osascript"} end)
    box_holds("")
    main_is("idle")
    expect_prompts()

    away = Path.join(root, "away")
    {:ok, main: main, a: a, away: away}
  end

  defp seed(main, fun) do
    {:ok, handle} = Storage.open(main, name: nil)
    fun.()
    Storage.close(handle)
  end

  defp leave_letter(main, from, path \\ nil) do
    path = path || put_letter(main, from)

    seed(main, fn ->
      {:ok, _} =
        Storage.leave_letter(%{from_repo: from, from_checkout: "/elsewhere/#{from}", path: path})
    end)

    path
  end

  defp put_letter(main, from) do
    source = Path.join(Path.dirname(main), "#{from}.md")
    File.write!(source, "From #{from}.\n")
    {:ok, path} = Whiska.Letters.put_house(main, source)
    path
  end

  defp open(main, opts \\ []) do
    opts =
      Keyword.merge(
        [main_checkout: main, herdr_socket: @socket, backstop_ms: 60_000, round_wait_ms: @wait],
        opts
      )

    name = :"house-#{System.unique_integer([:positive])}"
    allow(Herdr, self(), fn -> Process.whereis(name) end)
    pid = start_supervised!({House, [name: name] ++ opts})
    House.sync(pid)
    pid
  end

  defp in_house(house, fun) do
    Storage.point_at(House.repo(house))
    fun.()
  end

  defp main_is(status) do
    stub(Herdr, :pane, fn @socket, @main_pane ->
      {:ok, %{pane_id: @main_pane, cwd: "/main", agent: "claude", agent_status: status}}
    end)
  end

  defp box_holds(draft) do
    screen = """
    ✻ Baked for 46s · done 2:44 PM

    ────────────────────────────────────
    ❯ #{draft}
    ────────────────────────────────────
      ⏵⏵ auto mode on (shift+tab to cycle)
    """

    stub(Herdr, :read_screen, fn @socket, @main_pane -> {:ok, screen} end)
  end

  defp expect_prompts do
    test = self()

    stub(Herdr, :prompt, fn @socket, pane, text ->
      send(test, {:prompted, pane, text})
      :ok
    end)
  end

  defp idle(house) do
    send(
      house,
      {:herdr_event, "pane.agent_status_changed",
       %{"pane_id" => @main_pane, "agent_status" => "idle"}}
    )
  end

  defp leave_question(main, root, text) do
    {:ok, _} =
      Doorstep.leave(main, %Entry{
        mouse_id: "ma",
        branch: "feat-a",
        worktree_root: root,
        stamped_at: DateTime.utc_now(),
        text: text
      })
  end

  test "a letter another house left is typed once the gate is free", %{main: main} do
    path = leave_letter(main, "platform")
    main_is("working")
    house = open(main)
    refute_receive {:prompted, _, _}, @wait

    main_is("idle")
    idle(house)

    assert_receive {:prompted, @main_pane, line}, @arrives
    assert line == "📨 platform's Whiska sent you a letter: #{path}"

    in_house(house, fn ->
      assert [%{typed_at: %DateTime{}}] = Storage.letters()
    end)
  end

  test "a letter is typed once, never again", %{main: main} do
    leave_letter(main, "platform")
    house = open(main)
    assert_receive {:prompted, @main_pane, "📨 " <> _}, @arrives

    idle(house)
    House.sync(house)
    refute_receive {:prompted, _, _}, @wait
  end

  test "a letter left while the house is open is noticed on the board's tick", %{main: main} do
    house = open(main, board_ms: 20, panes_ms: 20)
    refute_receive {:prompted, _, _}, @wait

    leave_letter(main, "platform")
    assert_receive {:prompted, @main_pane, "📨 platform's Whiska" <> _}, @arrives
    assert House.sync(house) == :ok
  end

  test "a draft in the box holds it", %{main: main} do
    box_holds("half a sentence")
    leave_letter(main, "platform")
    house = open(main)
    refute_receive {:prompted, _, _}, @wait * 2
    assert House.held(house) == :typing

    box_holds("")
    idle(house)
    assert_receive {:prompted, @main_pane, "📨 " <> _}, @arrives
  end

  test "while away it waits, and goes once the person is back", %{main: main, away: away} do
    :ok = Whiska.Delivery.Mode.set_away(away)
    leave_letter(main, "platform")
    open(main, away_path: away, board_ms: 20, panes_ms: 20)
    refute_receive {:prompted, _, _}, @wait * 2

    :ok = Whiska.Delivery.Mode.clear_away(away)
    assert_receive {:prompted, @main_pane, "📨 " <> _}, @arrives
  end

  test "it does not wait for a delivered question to be answered", %{main: main, a: a} do
    house = open(main)
    leave_question(main, a, "[worktree-status: needs-decision] which db?")
    House.collect(house)
    assert_receive {:prompted, @main_pane, "🐱 " <> _}, @arrives

    leave_letter(main, "platform")
    idle(house)
    assert_receive {:prompted, @main_pane, "📨 " <> _}, @arrives
    in_house(house, fn -> assert Storage.question(1).status == "sent" end)
  end

  test "a focus on a mouse does not hold it", %{main: main} do
    seed(main, fn -> :ok = Storage.set_focus("ma") end)
    leave_letter(main, "platform")
    open(main)
    assert_receive {:prompted, @main_pane, "📨 " <> _}, @arrives
  end

  test "it goes ahead of a queued question, which goes on the next idle", %{main: main, a: a} do
    main_is("working")
    house = open(main)
    leave_question(main, a, "[worktree-status: needs-decision] which db?")
    House.collect(house)
    leave_letter(main, "platform")
    Process.sleep(@wait * 2)
    refute_receive {:prompted, _, _}, @wait

    main_is("idle")
    idle(house)
    assert_receive {:prompted, @main_pane, "📨 " <> _}, @arrives
    refute_receive {:prompted, _, _}, @wait

    idle(house)
    assert_receive {:prompted, @main_pane, "🐱 " <> _}, @arrives
  end

  test "two letters go one per idle, oldest first", %{main: main} do
    first = leave_letter(main, "platform")
    second = leave_letter(main, "dotfiles")
    house = open(main)

    assert_receive {:prompted, @main_pane, line}, @arrives
    assert String.ends_with?(line, first)
    refute_receive {:prompted, _, _}, @wait

    idle(house)
    assert_receive {:prompted, @main_pane, line}, @arrives
    assert String.ends_with?(line, second)
  end

  test "a letter whose file is outside this house's letters is never typed, and holds nothing",
       %{main: main, a: a} do
    leave_letter(main, "platform", Path.join(System.user_home!(), ".ssh/id_ed25519"))
    house = open(main)
    leave_question(main, a, "[worktree-status: needs-decision] which db?")
    House.collect(house)

    assert_receive {:prompted, @main_pane, "🐱 " <> _}, @arrives
    refute_receive {:prompted, _, "📨 " <> _}, @wait
    in_house(house, fn -> assert [%{typed_at: %DateTime{}}] = Storage.letters() end)
  end

  test "a letter raises no hoot", %{main: main} do
    test = self()
    stub(Desktop, :notify, fn hoot -> send(test, {:hooted, hoot}) && {:ok, "osascript"} end)
    leave_letter(main, "platform")
    open(main)

    assert_receive {:prompted, @main_pane, "📨 " <> _}, @arrives
    refute_receive {:hooted, _}, @wait
  end

  test "with no main session recorded a letter holds delivery, and waits",
       %{main: main} do
    root = Path.dirname(main)
    bare = Path.join(root, "bare")
    File.mkdir_p!(Path.join(bare, ".git"))
    path = put_letter(bare, "platform")

    seed(bare, fn ->
      {:ok, _} =
        Storage.leave_letter(%{from_repo: "platform", from_checkout: "/p", path: path})
    end)

    house = open(bare)
    refute_receive {:prompted, _, _}, @wait
    assert House.held(house) == :unreachable
    in_house(house, fn -> assert [%{typed_at: nil}] = Storage.letters() end)
  end

  test "a prompt herdr refuses is tried again, and typed once", %{main: main} do
    test = self()
    tries = :counters.new(1, [])

    stub(Herdr, :prompt, fn @socket, pane, text ->
      :counters.add(tries, 1, 1)

      if :counters.get(tries, 1) == 1 do
        {:error, :closed}
      else
        send(test, {:prompted, pane, text})
        :ok
      end
    end)

    leave_letter(main, "platform")
    house = open(main)
    refute_receive {:prompted, _, _}, @wait
    assert House.held(house) == :unreachable

    idle(house)
    assert_receive {:prompted, @main_pane, "📨 " <> _}, @arrives
    idle(house)
    refute_receive {:prompted, _, _}, @wait
    in_house(house, fn -> assert [%{typed_at: %DateTime{}}] = Storage.letters() end)
  end
end
