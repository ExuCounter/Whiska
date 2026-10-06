defmodule Whiska.CLIInboxTest do
  @moduledoc """
  The one-word commands (ADR-0079):
  `inbox`, `show`, `dismiss` as short spellings of the long names, and `away`,
  `focus`, `hold`, `resume` as the three delivery modes and their end.
  """
  # Serial: the code under test opens the house under the one VM-wide name
  # `Whiska.Repo`, writes the one away file, and sets HERDR_* in the OS env.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import Mox

  alias Whiska.CLI
  alias Whiska.Delivery.Mode
  alias Whiska.Herdr.Mock, as: Herdr
  alias Whiska.OpenHouses
  alias Whiska.Storage

  setup :verify_on_exit!

  @socket "/fake/herdr.sock"

  setup do
    root = Path.join(System.tmp_dir!(), "whiska-inbox-#{System.unique_integer([:positive])}")
    main = house!(root, "myrepo")
    worktree = Path.join(main, "worktrees/feat-a")
    File.mkdir_p!(worktree)
    File.write!(Path.join(worktree, ".git"), "gitdir: #{main}/.git/worktrees/feat-a\n")

    was = {System.get_env("HERDR_PANE_ID"), System.get_env("HERDR_SOCKET_PATH")}
    System.put_env("HERDR_PANE_ID", "w1:p2")
    System.put_env("HERDR_SOCKET_PATH", @socket)

    on_exit(fn ->
      Mode.clear_away()
      OpenHouses.write([])
      File.rm_rf!(root)
      {pane, socket} = was
      if pane, do: System.put_env("HERDR_PANE_ID", pane), else: System.delete_env("HERDR_PANE_ID")

      if socket,
        do: System.put_env("HERDR_SOCKET_PATH", socket),
        else: System.delete_env("HERDR_SOCKET_PATH")
    end)

    stub(Herdr, :pane, fn @socket, pane ->
      {:ok, %{pane_id: pane, cwd: main, agent: "claude", agent_status: "idle"}}
    end)

    {:ok, root: root, main: main, worktree: worktree}
  end

  defp house!(root, name) do
    main = Path.join(root, name)
    File.mkdir_p!(Path.join(main, ".git"))
    {:ok, handle} = Storage.open(main, name: :seed)
    Storage.close(handle)
    OpenHouses.add(main)
    main
  end

  defp run(argv, cwd) do
    {{status, stdout}, stderr} =
      with_io(:stderr, fn ->
        with_io(fn -> CLI.run(argv, cwd) end)
      end)

    {status, stdout, stderr}
  end

  defp in_house(main, fun) do
    {:ok, handle} = Storage.open(main, name: :seed)

    try do
      fun.()
    after
      Storage.close(handle)
    end
  end

  defp seed(main, fun) do
    in_house(main, fn ->
      {:ok, _} =
        Storage.record_mouse(%{
          mouse_id: "ma",
          path: Path.join(main, "worktrees/feat-a"),
          branch: "feat-a",
          pane: "w1R:p1"
        })

      {:ok, _} =
        Storage.record_mouse(%{
          mouse_id: "mb",
          path: Path.join(main, "worktrees/feat-b"),
          branch: "feat-b",
          pane: "w1R:p2"
        })

      fun.()
    end)
  end

  defp ask(mouse_id, text, attrs \\ %{}) do
    {:ok, q} =
      Storage.record_question(
        Map.merge(%{mouse_id: mouse_id, text: text, kind: "needs-decision"}, attrs)
      )

    q
  end

  describe "inbox" do
    test "is `whiska waiting`, from anywhere", %{main: main, root: root} do
      seed(main, fn -> ask("ma", "[worktree-status: needs-decision] pick one") end)
      elsewhere = Path.join(root, "not-a-repo")
      File.mkdir_p!(elsewhere)

      {0, out, _} = run(["inbox"], elsewhere)
      assert out =~ "myrepo"
      assert out =~ "feat-a"
      assert out =~ ~s(pick one)
      assert out =~ "#1"
    end

    test "says away on its first line, and why each row waits", %{main: main} do
      seed(main, fn ->
        ask("ma", "[worktree-status: needs-decision] a?")
        ask("mb", "[worktree-status: needs-decision] b?")
        {:ok, _} = Storage.hold("mb")
      end)

      {0, _, _} = run(["away"], main)
      {0, out, _} = run(["inbox"], main)

      [first, a, b] = out |> String.trim() |> String.split("\n")
      assert first =~ "away"
      assert first =~ "resume"
      assert a =~ ~r/#1 .*away$/
      assert b =~ ~r/#2 .*held$/
    end

    test "--json carries the same rows", %{main: main} do
      seed(main, fn ->
        ask("ma", "[worktree-status: needs-decision] a?")
        {:ok, _} = Storage.hold("ma")
      end)

      {0, out, _} = run(["inbox", "--json"], main)
      assert {:ok, [%{"id" => 1, "waits" => "held", "held" => true}]} = JSON.decode(out)
    end
  end

  describe "show" do
    test "with no id prints every open question of this repo in full", %{main: main} do
      seed(main, fn ->
        ask("ma", "Which db?\n[worktree-status: needs-decision] pick one")
        ask("mb", "Which cache?\n[worktree-status: needs-decision] pick another")
      end)

      {0, out, _} = run(["show"], main)
      assert out =~ "Which db?"
      assert out =~ "Which cache?"
    end

    test "with an id prints that one, with why it waits", %{main: main} do
      seed(main, fn ->
        ask("ma", "Which db?\n[worktree-status: needs-decision] pick one")
        :ok = Storage.set_focus("mb")
      end)

      {0, out, _} = run(["show", "1"], main)
      assert out =~ "Which db?"
      assert out =~ "(waits: focus on feat-b, asked"
    end

    test "works from a worktree of the repo, and refuses outside any repo", %{
      main: main,
      worktree: worktree,
      root: root
    } do
      seed(main, fn -> ask("ma", "[worktree-status: needs-decision] hi") end)
      {0, out, _} = run(["show", "1"], worktree)
      assert out =~ "hi"

      elsewhere = Path.join(root, "not-a-repo")
      File.mkdir_p!(elsewhere)
      {1, _, err} = run(["show", "1"], elsewhere)
      assert err =~ "not a git checkout"
    end
  end

  describe "dismiss" do
    test "closes a question without answering it", %{main: main} do
      seed(main, fn -> ask("ma", "?") end)
      {0, out, _} = run(["dismiss", "1"], main)
      assert out =~ "#1"
      in_house(main, fn -> assert Storage.question(1).status == "closed" end)
    end
  end

  describe "away and resume" do
    test "away stops delivery everywhere, and says what that means", %{main: main} do
      {0, out, _} = run(["away"], main)
      assert Mode.away?()
      assert out =~ "resume"
      assert out =~ "mice keep working"
    end

    test "away twice is still away, and says so", %{main: main} do
      {0, _, _} = run(["away"], main)
      {0, out, _} = run(["away"], main)
      assert out =~ "already away"
    end

    test "resume in a repo ends away and this repo's focus, and says so", %{main: main} do
      seed(main, fn -> :ok = Storage.set_focus("ma") end)
      {0, _, _} = run(["away"], main)

      {0, out, _} = run(["resume"], main)
      refute Mode.away?()
      in_house(main, fn -> assert Storage.focus() == nil end)
      assert out =~ "away ended"
      assert out =~ "focus on feat-a ended"
      assert out =~ "oldest first"
    end

    test "resume outside any repo ends away and every repo's focus, naming each", %{
      main: main,
      root: root
    } do
      other = house!(root, "other")
      seed(main, fn -> :ok = Storage.set_focus("ma") end)

      in_house(other, fn ->
        {:ok, _} = Storage.record_mouse(%{mouse_id: "mo", path: "/w/o", branch: "feat-o"})
        :ok = Storage.set_focus("mo")
      end)

      {0, _, _} = run(["away"], main)
      elsewhere = Path.join(root, "not-a-repo")
      File.mkdir_p!(elsewhere)

      {0, out, _} = run(["resume"], elsewhere)
      refute Mode.away?()
      in_house(main, fn -> assert Storage.focus() == nil end)
      in_house(other, fn -> assert Storage.focus() == nil end)
      assert out =~ "myrepo: focus on feat-a ended"
      assert out =~ "other: focus on feat-o ended"
    end

    test "resume with nothing set aside says so", %{main: main} do
      {0, out, _} = run(["resume"], main)
      assert out =~ "Nothing was set aside"
    end
  end

  describe "focus" do
    test "focuses this repo on a live mouse, by branch", %{main: main} do
      seed(main, fn -> :ok end)
      {0, out, _} = run(["focus", "feat-b"], main)
      assert out =~ "feat-b"
      assert out =~ "resume"
      in_house(main, fn -> assert Storage.focus() == "mb" end)
    end

    test "with no branch prints the focus, or that there is none", %{main: main} do
      seed(main, fn -> :ok end)
      {0, out, _} = run(["focus"], main)
      assert out =~ "No focus"

      {0, _, _} = run(["focus", "feat-a"], main)
      {0, out, _} = run(["focus"], main)
      assert out =~ "feat-a"
    end

    test "refuses a branch that is not a live mouse of this repo", %{main: main} do
      seed(main, fn -> {:ok, _} = Storage.mark_dead("mb") end)
      {1, _, err} = run(["focus", "feat-b"], main)
      assert err =~ "feat-b"
      {1, _, err} = run(["focus", "nope"], main)
      assert err =~ "nope"
      in_house(main, fn -> assert Storage.focus() == nil end)
    end

    test "while away, a focus is recorded and the reply says away still blocks", %{main: main} do
      seed(main, fn -> :ok end)
      {0, _, _} = run(["away"], main)
      {0, out, _} = run(["focus", "feat-a"], main)
      assert out =~ "away"
      in_house(main, fn -> assert Storage.focus() == "ma" end)
    end
  end

  describe "hold" do
    test "puts a live mouse on hold, by branch", %{main: main} do
      seed(main, fn -> :ok end)
      {0, out, _} = run(["hold", "feat-a"], main)
      assert out =~ "feat-a"
      assert out =~ "resume feat-a"
      in_house(main, fn -> assert %DateTime{} = Storage.mouse("ma").held_at end)
    end

    test "refuses a branch that is not a live mouse", %{main: main} do
      seed(main, fn -> {:ok, _} = Storage.mark_dead("mb") end)
      {1, _, err} = run(["hold", "feat-b"], main)
      assert err =~ "feat-b"
      {1, _, err} = run(["hold", "nope"], main)
      assert err =~ "nope"
    end
  end

  describe "resume <branch>" do
    test "lifts the hold and tells a mouse that stopped because of it to carry on", %{
      main: main
    } do
      seed(main, fn ->
        {:ok, _} = Storage.hold("ma")
        Process.sleep(1_100)
        ask("ma", "[worktree-status: needs-decision] stopped at the migration")
      end)

      expect(Herdr, :prompt, fn @socket, "w1R:p1", line ->
        assert line =~ "hold"
        assert line =~ ~r/carry on/i
        :ok
      end)

      {0, out, _} = run(["resume", "feat-a"], main)
      assert out =~ "feat-a"
      assert out =~ "carry on"

      in_house(main, fn ->
        assert %{held_at: nil, worked_at: %DateTime{}} = Storage.mouse("ma")
        # The line answers the stop, so it is never delivered as a decision —
        # and it went straight into the pane, so there is nothing for the owl
        # to ring for.
        assert %{status: "answered", taken_at: %DateTime{}} = Storage.question(1)
        assert Storage.chased() == []
      end)
    end

    test "a mouse that finished after being held gets no line, and its finished line is told",
         %{main: main} do
      seed(main, fn ->
        {:ok, _} = Storage.hold("ma")
        Process.sleep(1_100)
        ask("ma", "all done\n[worktree-status: done]", %{kind: "done"})
      end)

      {0, out, _} = run(["resume", "feat-a"], main)
      assert out =~ "finished line is told once nothing else is out waiting on you"

      in_house(main, fn ->
        assert Storage.mouse("ma").held_at == nil
        assert Storage.question(1).status == "open"
      end)
    end

    test "types nothing into a mouse that was waiting on an answer when held, and names it", %{
      main: main
    } do
      seed(main, fn ->
        q = ask("ma", "[worktree-status: needs-decision] which db?")
        {:ok, _} = Storage.mark_sent(q.id)
        Process.sleep(1_100)
        {:ok, _} = Storage.hold("ma")
      end)

      {0, out, _} = run(["resume", "feat-a"], main)
      assert out =~ "#1"
      assert out =~ "reply 1"
      in_house(main, fn -> assert Storage.mouse("ma").held_at == nil end)
    end

    test "a mouse that is not on hold is said so, and nothing else happens", %{main: main} do
      seed(main, fn -> :ok end)
      {0, out, _} = run(["resume", "feat-a"], main)
      assert out =~ "not on hold"
    end

    test "a hold is lifted even when herdr refuses the line, and the refusal is said", %{
      main: main
    } do
      seed(main, fn ->
        {:ok, _} = Storage.hold("ma")
        Process.sleep(1_100)
        ask("ma", "[worktree-status: needs-decision] stopped")
      end)

      expect(Herdr, :prompt, fn @socket, "w1R:p1", _ ->
        {:error, {:herdr, %{"code" => "agent_blocked", "message" => "at a dialog"}}}
      end)

      {1, out, err} = run(["resume", "feat-a"], main)
      assert out =~ "lifted" or err =~ "lifted"
      assert err =~ "agent_blocked"
      in_house(main, fn -> assert Storage.mouse("ma").held_at == nil end)
    end
  end

  describe "reply to a held mouse" do
    test "lifts the hold before it rings the doorbell", %{main: main} do
      seed(main, fn ->
        q = ask("ma", "[worktree-status: needs-decision] which?")
        {:ok, _} = Storage.mark_sent(q.id)
        {:ok, _} = Storage.hold("ma")
      end)

      expect(Herdr, :prompt, fn @socket, "w1R:p1", line ->
        assert line == Whiska.Doorbell.line(1)
        assert Storage.mouse("ma").held_at == nil
        :ok
      end)

      {0, out, _} = run(["reply", "1", "SQLite"], main)
      assert out =~ "hold"
      in_house(main, fn -> assert Storage.mouse("ma").held_at == nil end)
    end
  end

  test "the eight words are in the usage text, and jump is not one of them" do
    out = capture_io(fn -> assert CLI.run(["--help"]) == 0 end)

    for word <- ~w(inbox show reply dismiss focus away hold resume) do
      assert out =~ ~r/^ {2,4}#{word}\b/m, "#{word} is not in the usage text"
    end

    assert out =~ ~r/^ {2,4}jump \[<repo\|branch>\]/m
    refute out =~ ~r/^ {2,4}jump\s{2,}/m
  end
end
