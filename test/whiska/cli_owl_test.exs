defmodule Whiska.CLIOwlTest do
  @moduledoc "The two commands the owl slice adds to the binary."
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import Mox

  alias Whiska.CLI
  alias Whiska.Doorstep
  alias Whiska.Herdr.Mock, as: Herdr

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    root = Path.join(System.tmp_dir!(), "whiska-cliowl-#{System.unique_integer([:positive])}")
    main = Path.join(root, "myrepo")
    worktree = Path.join(main, "worktrees/feat-thing")
    File.mkdir_p!(Path.join(main, ".git"))
    File.mkdir_p!(worktree)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root, main: main, worktree: worktree}
  end

  describe "whiska hook stop" do
    test "reads the payload on stdin and leaves an entry, exiting 0", %{
      main: main,
      worktree: worktree
    } do
      payload =
        JSON.encode!(%{"cwd" => worktree, "last_assistant_message" => "[worktree-status: done]"})

      output =
        capture_io([input: payload, capture_prompt: false], fn ->
          send(self(), {:status, CLI.run(["hook", "stop"])})
        end)

      assert_received {:status, 0}
      assert output == ""
      assert [{_, entry}] = Doorstep.waiting(main)
      assert entry.text == "[worktree-status: done]"
    end
  end

  describe "whiska owl" do
    setup do
      stub(Herdr, :list_panes, fn _ -> {:ok, []} end)

      stub(Herdr, :subscribe, fn _, _, _ -> {:ok, spawn(fn -> receive do: (:stop -> :ok) end)} end)

      on_exit(fn -> CLI.stop_owl() end)
      :ok
    end

    test "opens a house for each repo named and says so", %{main: main, root: root} do
      other = Path.join(root, "other")
      File.mkdir_p!(Path.join(other, ".git"))

      output = capture_io(fn -> assert {:ok, _} = CLI.start_owl([main, other]) end)

      assert output =~ "Opened 2 houses"
      assert output =~ "myrepo"
      assert output =~ "other"
      assert Enum.sort(Whiska.Owl.open_houses()) == Enum.sort([main, other])
    end

    test "with no repo named, opens the house for the current checkout", %{main: main} do
      capture_io(fn -> assert {:ok, _} = CLI.start_owl([], main) end)
      assert Whiska.Owl.open_houses() == [main]
    end

    test "refuses a path that is not a git checkout", %{root: root} do
      not_a_repo = Path.join(root, "plain")
      File.mkdir_p!(not_a_repo)

      err = capture_io(:stderr, fn -> assert {:error, _} = CLI.start_owl([not_a_repo]) end)
      assert err =~ "not a git checkout"
    end

    test "runs from a worktree by opening its main checkout's house", %{
      main: main,
      worktree: worktree
    } do
      capture_io(fn -> assert {:ok, _} = CLI.start_owl([], worktree) end)
      assert Whiska.Owl.open_houses() == [main]
    end
  end
end
