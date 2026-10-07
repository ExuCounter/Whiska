defmodule Whiska.CLIWatchTest do
  @moduledoc "`whiska watch` at the binary: the sidebar's lines, printed once."
  # Serial: the code under test opens the house under the one VM-wide name `Whiska.Repo`.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import Mox

  alias Whiska.CLI
  alias Whiska.Herdr.Mock, as: Herdr
  alias Whiska.Storage

  setup :verify_on_exit!

  setup do
    root = Path.join(System.tmp_dir!(), "whiska-cliwatch-#{System.unique_integer([:positive])}")
    main = Path.join(root, "myrepo")
    File.mkdir_p!(Path.join(main, ".git"))
    # The herdr mock answers for any socket; a herdr pane's shell names one,
    # and the run must not depend on whether the suite was started in one.
    socket = System.get_env("HERDR_SOCKET_PATH")
    System.put_env("HERDR_SOCKET_PATH", Path.join(root, "herdr.sock"))

    on_exit(fn ->
      if socket,
        do: System.put_env("HERDR_SOCKET_PATH", socket),
        else: System.delete_env("HERDR_SOCKET_PATH")

      File.rm_rf!(root)
    end)

    {:ok, main: main}
  end

  defp seed_mouse(main, id, branch) do
    {:ok, handle} = Storage.open(main, name: :seed)
    path = Path.join(main, "worktrees/#{branch}")
    File.mkdir_p!(path)
    File.write!(Path.join(path, ".git"), "gitdir: #{main}/.git/worktrees/#{branch}\n")
    {:ok, _} = Storage.record_mouse(%{mouse_id: id, path: path, branch: branch})
    Storage.close(handle)
    path
  end

  defp seed_question(main, mouse_id, text) do
    {:ok, handle} = Storage.open(main, name: :seed)

    {:ok, q} =
      Storage.record_question(%{
        mouse_id: mouse_id,
        text: text,
        kind: "needs-decision",
        asked_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    Storage.close(handle)
    q
  end

  defp pane(cwd, status),
    do: %{pane_id: "w1:p1", cwd: cwd, agent: "claude", agent_status: status}

  defp no_workspaces, do: stub(Herdr, :workspaces, fn _ -> {:ok, []} end)

  describe "whiska watch" do
    test "prints each mouse under its branch, with the line the sidebar shows", %{main: main} do
      path = seed_mouse(main, "ma", "feat-a")
      no_workspaces()

      stub(Herdr, :list_panes, fn _ ->
        {:ok, [Map.put(pane(path, "working"), :title, "Order builder")]}
      end)

      out = capture_io(fn -> assert CLI.run(["watch"], main) == 0 end)

      assert out =~ "feat-a\n  ◐ Order builder"
    end

    test "a mouse waiting on the person shows its question, wrapped", %{main: main} do
      path = seed_mouse(main, "ma", "feat-a")
      q = seed_question(main, "ma", "Body.\n\nwhich db?\n⁣⁣")
      no_workspaces()
      stub(Herdr, :list_panes, fn _ -> {:ok, [pane(path, "idle")]} end)

      out = capture_io(fn -> assert CLI.run(["watch"], main) == 0 end)

      assert out =~ "feat-a\n  🐭 ##{q.id} · waiting on you\n  which db?"
    end

    test "a dead mouse has no lines, and what it left is counted as orphaned", %{main: main} do
      seed_mouse(main, "ma", "feat-a")
      seed_question(main, "ma", "Body.\n\npick one\n⁣⁣")

      {:ok, handle} = Storage.open(main, name: :seed)
      {:ok, _} = Storage.mark_dead("ma")
      Storage.close(handle)

      no_workspaces()
      stub(Herdr, :list_panes, fn _ -> {:ok, []} end)

      out = capture_io(fn -> assert CLI.run(["watch"], main) == 0 end)

      refute out =~ "\nfeat-a"
      refute out =~ "waiting"
      assert out =~ "◌ 1 orphaned (feat-a)"
    end

    test "a question whose mouse has no workspace is counted on the main checkout's line", %{
      main: main
    } do
      path = seed_mouse(main, "ma", "feat-a")
      seed_question(main, "ma", "Body.\n\nwhich db?\n⁣⁣")
      stub(Herdr, :list_panes, fn _ -> {:ok, [pane(path, "idle")]} end)

      stub(Herdr, :workspaces, fn _ ->
        {:ok, [%{workspace_id: "w1", number: 1, path: main, linked?: false, tokens: %{}}]}
      end)

      out = capture_io(fn -> assert CLI.run(["watch"], main) == 0 end)

      assert out =~ "🐭 1 more: whiska questions"
    end

    test "a stale record for a folder a branch nests under is on neither list", %{main: main} do
      seed_mouse(main, "mstale", "feat")
      nested = seed_mouse(main, "mnested", "feat/checkout-form")
      no_workspaces()
      stub(Herdr, :list_panes, fn _ -> {:ok, [pane(nested, "working")]} end)

      board = capture_io(fn -> assert CLI.run(["watch"], main) == 0 end)
      mice = capture_io(fn -> assert CLI.run(["mice"], main) == 0 end)

      assert board =~ "feat/checkout-form\n"
      refute board =~ ~r/^feat$/m
      assert mice =~ "feat/checkout-form"
      refute mice =~ "feat  "
    end

    test "a quiet house says so, rather than printing nothing", %{main: main} do
      no_workspaces()
      stub(Herdr, :list_panes, fn _ -> {:ok, []} end)

      assert capture_io(fn -> assert CLI.run(["watch"], main) == 0 end) =~
               "Nothing on the sidebar"
    end

    test "finds herdr at its own socket when nothing set the variable", %{main: main} do
      path = seed_mouse(main, "ma", "feat-a")
      home = Path.dirname(main)
      default = Path.join(home, ".config/herdr/herdr.sock")
      File.mkdir_p!(Path.dirname(default))
      File.write!(default, "")
      System.delete_env("HERDR_SOCKET_PATH")
      previous_home = System.get_env("HOME")
      System.put_env("HOME", home)
      on_exit(fn -> System.put_env("HOME", previous_home) end)

      no_workspaces()

      stub(Herdr, :list_panes, fn ^default ->
        {:ok, [Map.put(pane(path, "working"), :title, "Order builder")]}
      end)

      out = capture_io(fn -> assert CLI.run(["watch"], main) == 0 end)

      assert out =~ "◐ Order builder"
    end

    test "is in the usage text" do
      out = ExUnit.CaptureIO.capture_io(fn -> assert CLI.run(["--help"]) == 0 end)

      assert out =~ ~r/^\s+watch\s+\S/m
    end

    test "statusline --here, which an older statusline script runs, prints nothing", %{
      main: main
    } do
      path = seed_mouse(main, "ma", "feat-a")
      seed_question(main, "ma", "Body.\n\nwhich db?\n⁣⁣")

      assert capture_io(fn -> assert CLI.run(["statusline", "--here"], main) == 0 end) == ""
      assert capture_io(fn -> assert CLI.run(["statusline", "--here"], path) == 0 end) == ""
    end

    test "run inside a worktree it still reports that worktree's own house", %{main: main} do
      path = seed_mouse(main, "ma", "feat-a")
      no_workspaces()
      stub(Herdr, :list_panes, fn _ -> {:ok, [pane(path, "working")]} end)

      out = capture_io(fn -> assert CLI.run(["watch"], path) == 0 end)

      assert out =~ "feat-a\n  ◐"
    end
  end
end
