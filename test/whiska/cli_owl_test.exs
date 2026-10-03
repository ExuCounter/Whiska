defmodule Whiska.CLIOwlTest do
  @moduledoc "The two commands the owl slice adds to the binary."
  # Serial: `whiska owl` starts the one named owl, whose houses call herdr from
  # their own processes (hence the global mock), and the test moves `:home`.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import Mox

  alias Whiska.CLI
  alias Whiska.Doorstep
  alias Whiska.Herdr.Mock, as: Herdr
  alias Whiska.OpenHouses
  alias Whiska.Storage

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    root = Path.join(System.tmp_dir!(), "whiska-cliowl-#{System.unique_integer([:positive])}")
    main = Path.join(root, "myrepo")
    worktree = Path.join(main, "worktrees/feat-thing")
    File.mkdir_p!(Path.join(main, ".git"))
    File.mkdir_p!(worktree)
    File.write!(Path.join(worktree, ".git"), "gitdir: #{main}/.git/worktrees/feat-thing\n")

    previous_home = Application.get_env(:whiska, :home)
    Application.put_env(:whiska, :home, Path.join(root, "dot-whiska"))

    on_exit(fn ->
      Application.put_env(:whiska, :home, previous_home)
      File.rm_rf!(root)
    end)

    {:ok, root: root, main: main, worktree: worktree}
  end

  # A repo whose house exists on disk: a `.git` and an opened database.
  defp house!(root, name) do
    main = Path.join(root, name)
    File.mkdir_p!(Path.join(main, ".git"))
    {:ok, handle} = Storage.open(main)
    Storage.close(handle)
    main
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

      output = capture_io(fn -> assert {:ok, _} = CLI.start_owl([main, other], root) end)

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

      err = capture_io(:stderr, fn -> assert {:error, _} = CLI.start_owl([not_a_repo], root) end)
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

  # The refusal that keeps two owls off the same doorstep (ADR-0040) has to
  # know which owl it is talking about. Under launchd there is only one
  # process: the wrapper execs, so the job's pid is this BEAM's own pid.
  describe "the owl and launchd's job (ADR-0040)" do
    setup do
      stub(Herdr, :list_panes, fn _ -> {:ok, []} end)

      stub(Herdr, :subscribe, fn _, _, _ -> {:ok, spawn(fn -> receive do: (:stop -> :ok) end)} end)

      on_exit(fn -> CLI.stop_owl() end)
      :ok
    end

    # `launchctl print` for a loaded job whose owl is alive with this pid.
    defp print_pid(pid) do
      out = "com.whiska.owl = {\n\tstate = running\n\tpid = #{pid}\n}\n"
      runner = fn ["print" | _] -> {out, 0} end
      Application.put_env(:whiska, :launchctl, runner)
      on_exit(fn -> Application.put_env(:whiska, :launchctl, &Whiska.Test.NoLaunchctl.run/1) end)
    end

    test "the supervised owl does not refuse itself", %{main: main} do
      print_pid(System.pid())

      output = capture_io(fn -> assert {:ok, _} = CLI.start_owl([], main) end)

      assert output =~ "Opened 1 house"
      assert Whiska.Owl.open_houses() == [main]
    end

    test "a foreground owl still refuses while launchd's owl is up", %{main: main} do
      print_pid(String.to_integer(System.pid()) + 1)

      err =
        capture_io(:stderr, fn ->
          assert {:error, :supervised} = CLI.start_owl([], main)
        end)

      assert err =~ "already running under launchd"
      assert Process.whereis(Whiska.Owl) == nil
    end
  end

  describe "the open-houses record (ADR-0039)" do
    setup do
      stub(Herdr, :list_panes, fn _ -> {:ok, []} end)

      stub(Herdr, :subscribe, fn _, _, _ -> {:ok, spawn(fn -> receive do: (:stop -> :ok) end)} end)

      on_exit(fn -> CLI.stop_owl() end)
      :ok
    end

    test "every house opened is recorded", %{main: main, root: root} do
      other = Path.join(root, "other")
      File.mkdir_p!(Path.join(other, ".git"))

      capture_io(fn -> assert {:ok, _} = CLI.start_owl([main, other], root) end)

      assert OpenHouses.read() == Enum.sort([main, other])
    end

    test "with no repo named, every recorded house is opened, plus the current one when it has a house",
         %{main: main, root: root} do
      recorded = house!(root, "dotfiles")
      OpenHouses.add(recorded)
      {:ok, handle} = Storage.open(main)
      Storage.close(handle)

      output = capture_io(fn -> assert {:ok, _} = CLI.start_owl([], main) end)

      assert output =~ "Opened 2 houses"
      assert Enum.sort(Whiska.Owl.open_houses()) == Enum.sort([main, recorded])
      assert OpenHouses.read() == Enum.sort([main, recorded])
    end

    test "with no repo named, a current checkout with no house is not opened when the record has others",
         %{main: main, root: root} do
      recorded = house!(root, "dotfiles")
      OpenHouses.add(recorded)

      capture_io(fn -> assert {:ok, _} = CLI.start_owl([], main) end)

      assert Whiska.Owl.open_houses() == [recorded]
      refute File.exists?(Storage.database_path(main))
    end

    test "with a repo named, it is opened alongside the recorded ones and added to the record",
         %{main: main, root: root} do
      recorded = house!(root, "dotfiles")
      OpenHouses.add(recorded)

      capture_io(fn -> assert {:ok, _} = CLI.start_owl([main], root) end)

      assert Enum.sort(Whiska.Owl.open_houses()) == Enum.sort([main, recorded])
      assert OpenHouses.read() == Enum.sort([main, recorded])
    end

    test "a recorded house whose checkout is gone is skipped, said so, and dropped from the record",
         %{main: main, root: root} do
      gone = Path.join(root, "gone")
      OpenHouses.add(gone)
      OpenHouses.add(main)

      err =
        capture_io(:stderr, fn ->
          capture_io(fn -> assert {:ok, _} = CLI.start_owl([], main) end)
        end)

      assert err =~ "gone"
      assert Whiska.Owl.open_houses() == [main]
      assert OpenHouses.read() == [main]
    end

    test "shutting a house takes it out of the record; stopping the owl leaves it", %{
      main: main,
      root: root
    } do
      other = Path.join(root, "other")
      File.mkdir_p!(Path.join(other, ".git"))
      capture_io(fn -> assert {:ok, _} = CLI.start_owl([main, other], root) end)

      assert :ok = Whiska.Owl.shut_house(other)
      assert OpenHouses.read() == [main]

      CLI.stop_owl()
      assert OpenHouses.read() == [main]
    end
  end
end
