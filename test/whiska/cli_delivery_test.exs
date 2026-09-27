defmodule Whiska.CLIDeliveryTest do
  @moduledoc """
  The commands the delivery slice adds: `whiska start` records the main
  session (ADR-0020); `whiska questions` shows what is waiting; `whiska reply`
  answers by question id (ADR-0005) and types the answer into the mouse's pane;
  `whiska close` settles one by hand.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import Mox

  alias Whiska.CLI
  alias Whiska.Herdr.Mock, as: Herdr
  alias Whiska.Storage

  setup :set_mox_global
  setup :verify_on_exit!

  @socket "/fake/herdr.sock"

  setup do
    root = Path.join(System.tmp_dir!(), "whiska-clid-#{System.unique_integer([:positive])}")
    main = Path.join(root, "myrepo")
    worktree = Path.join(main, "worktrees/feat-a")
    File.mkdir_p!(Path.join(main, ".git"))
    File.mkdir_p!(worktree)

    was = {System.get_env("HERDR_PANE_ID"), System.get_env("HERDR_SOCKET_PATH")}
    System.put_env("HERDR_PANE_ID", "w1:p2")
    System.put_env("HERDR_SOCKET_PATH", @socket)

    on_exit(fn ->
      File.rm_rf!(root)
      {pane, socket} = was
      if pane, do: System.put_env("HERDR_PANE_ID", pane), else: System.delete_env("HERDR_PANE_ID")

      if socket,
        do: System.put_env("HERDR_SOCKET_PATH", socket),
        else: System.delete_env("HERDR_SOCKET_PATH")
    end)

    {:ok, main: main, worktree: worktree}
  end

  # Run a command, returning {status, stdout, stderr}.
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

      fun.()
    end)
  end

  defp ask(text, attrs \\ %{}) do
    {:ok, q} =
      Storage.record_question(
        Map.merge(%{mouse_id: "ma", text: text, kind: "needs-decision"}, attrs)
      )

    q
  end

  describe "whiska start" do
    test "records the pane it is run from as the main session", %{main: main} do
      {0, out, _} = run(["start"], main)
      assert out =~ "w1:p2"
      assert out =~ "main session"
      in_house(main, fn -> assert Storage.main_pane() == "w1:p2" end)
    end

    test "works from a subdirectory of the main checkout", %{main: main} do
      sub = Path.join(main, "lib")
      File.mkdir_p!(sub)
      {0, _, _} = run(["start"], sub)
      in_house(main, fn -> assert Storage.main_pane() == "w1:p2" end)
    end

    test "refuses outside a herdr pane", %{main: main} do
      System.delete_env("HERDR_PANE_ID")
      {1, _, err} = run(["start"], main)
      assert err =~ "herdr pane"
      in_house(main, fn -> assert Storage.main_pane() == nil end)
    end

    test "refuses inside a worktree — the main session lives in the main checkout", %{
      worktree: worktree,
      main: main
    } do
      {1, _, err} = run(["start"], worktree)
      assert err =~ "main checkout"
      in_house(main, fn -> assert Storage.main_pane() == nil end)
    end

    test "refuses to replace a main session that is still running Claude, naming the pane", %{
      main: main
    } do
      in_house(main, fn -> Storage.set_main_pane("w1:p9") end)

      stub(Herdr, :pane, fn @socket, "w1:p9" ->
        {:ok, %{pane_id: "w1:p9", cwd: main, agent: "claude", agent_status: "idle"}}
      end)

      {1, _, err} = run(["start"], main)
      assert err =~ "w1:p9"
      assert err =~ "--force"
      in_house(main, fn -> assert Storage.main_pane() == "w1:p9" end)
    end

    test "--force switches it anyway", %{main: main} do
      in_house(main, fn -> Storage.set_main_pane("w1:p9") end)
      {0, _, _} = run(["start", "--force"], main)
      in_house(main, fn -> assert Storage.main_pane() == "w1:p2" end)
    end

    test "replaces a recorded pane that is gone or no longer running Claude", %{main: main} do
      in_house(main, fn -> Storage.set_main_pane("w1:p9") end)

      stub(Herdr, :pane, fn @socket, "w1:p9" ->
        {:error, {:herdr, %{"code" => "pane_not_found", "message" => "gone"}}}
      end)

      {0, _, _} = run(["start"], main)
      in_house(main, fn -> assert Storage.main_pane() == "w1:p2" end)
    end

    test "running it again from the same pane is fine", %{main: main} do
      {0, _, _} = run(["start"], main)
      {0, _, _} = run(["start"], main)
    end
  end

  describe "whiska questions" do
    test "says so when nothing is waiting", %{main: main} do
      {0, out, _} = run(["questions"], main)
      assert out =~ "Nothing is waiting"
    end

    test "lists open and sent questions, one line each, with the id and branch", %{main: main} do
      seed(main, fn ->
        ask("Which db?\n[worktree-status: needs-decision] pick one")
        b = ask("I just stopped.", %{kind: "unmarked"})
        {:ok, _} = Storage.mark_sent(b.id)
        c = ask("[worktree-status: done]", %{kind: "done", status: "closed"})
        _ = c
      end)

      {0, out, _} = run(["questions"], main)
      lines = String.split(String.trim(out), "\n")
      assert length(lines) == 2
      assert Enum.at(lines, 0) =~ "#1"
      assert Enum.at(lines, 0) =~ "feat-a"
      assert Enum.at(lines, 0) =~ ~s("pick one")
      assert Enum.at(lines, 0) =~ "open"
      assert Enum.at(lines, 1) =~ "#2"
      assert Enum.at(lines, 1) =~ "sent"
      refute out =~ "#3"
    end

    test "with an id prints that question in full", %{main: main} do
      seed(main, fn ->
        ask("Which db?\nPostgres or SQLite?\n[worktree-status: needs-decision] pick")
      end)

      {0, out, _} = run(["questions", "1"], main)
      assert out =~ "#1"
      assert out =~ "feat-a"
      assert out =~ "Which db?\nPostgres or SQLite?"
      assert out =~ ~s(whiska reply 1 ")
    end

    test "an unknown id is an error", %{main: main} do
      {1, _, err} = run(["questions", "42"], main)
      assert err =~ "42"
    end

    test "works from inside a worktree of the house", %{main: main, worktree: worktree} do
      seed(main, fn -> ask("[worktree-status: needs-decision] hi") end)
      {0, out, _} = run(["questions"], worktree)
      assert out =~ "#1"
    end
  end

  describe "whiska reply" do
    test "types the answer into the mouse's pane and marks the question answered (ADR-0005)",
         %{main: main} do
      seed(main, fn ->
        q = ask("[worktree-status: needs-decision] which?")
        {:ok, _} = Storage.mark_sent(q.id)
      end)

      expect(Herdr, :prompt, fn @socket, "w1R:p1", "go with SQLite" -> :ok end)

      {0, out, _} = run(["reply", "1", "go with SQLite"], main)
      assert out =~ "#1"
      assert out =~ "feat-a"

      in_house(main, fn ->
        assert %{status: "answered", answer: "go with SQLite"} = Storage.question(1)
      end)
    end

    test "joins several words into one answer", %{main: main} do
      seed(main, fn -> ask("?") end)
      expect(Herdr, :prompt, fn @socket, "w1R:p1", "yes please do" -> :ok end)
      {0, _, _} = run(["reply", "1", "yes", "please", "do"], main)
    end

    test "leaves the question as it was when herdr refuses", %{main: main} do
      seed(main, fn ->
        q = ask("?")
        {:ok, _} = Storage.mark_sent(q.id)
      end)

      expect(Herdr, :prompt, fn @socket, "w1R:p1", _ ->
        {:error, {:herdr, %{"code" => "agent_blocked", "message" => "at a dialog"}}}
      end)

      {1, _, err} = run(["reply", "1", "yes"], main)
      assert err =~ "agent_blocked"
      in_house(main, fn -> assert Storage.question(1).status == "sent" end)
    end

    test "refuses a dead mouse and says where its worktree is", %{main: main} do
      seed(main, fn ->
        ask("?")
        {:ok, _} = Storage.mark_dead("ma")
      end)

      {1, _, err} = run(["reply", "1", "yes"], main)
      assert err =~ "dead"
      assert err =~ "worktrees/feat-a"
    end

    test "refuses a question that is already settled, and an unknown one", %{main: main} do
      seed(main, fn ->
        q = ask("?")
        {:ok, _} = Storage.answer(q.id, "done")
      end)

      {1, _, err} = run(["reply", "1", "again"], main)
      assert err =~ "answered"
      {1, _, err} = run(["reply", "9", "x"], main)
      assert err =~ "9"
    end

    test "needs an answer", %{main: main} do
      {1, _, err} = run(["reply", "1"], main)
      assert err =~ "usage" or err =~ "Usage"
    end
  end

  describe "whiska close" do
    test "closes an open or sent question without answering it", %{main: main} do
      seed(main, fn -> ask("?") end)
      {0, out, _} = run(["close", "1"], main)
      assert out =~ "#1"
      in_house(main, fn -> assert Storage.question(1).status == "closed" end)
    end

    test "refuses an unknown or settled question", %{main: main} do
      {1, _, err} = run(["close", "7"], main)
      assert err =~ "7"
    end
  end
end
