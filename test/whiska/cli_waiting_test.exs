defmodule Whiska.CLIWaitingTest do
  @moduledoc """
  `whiska waiting` and `whiska jump` — the two commands a global hotkey drives.

  `waiting` reads every house in the open-houses record and changes nothing;
  `jump` asks herdr to focus one pane (ADR-0043), faked at the boundary
  ADR-0031 names. Houses are real SQLite files under a tmp root, and the record
  is this test's own file, pointed at through the `:home` setting.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import Mox

  alias Whiska.CLI
  alias Whiska.Herdr.Mock, as: Herdr
  alias Whiska.OpenHouses
  alias Whiska.Storage

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    root = Path.join(System.tmp_dir!(), "whiska-cliw-#{System.unique_integer([:positive])}")
    home = Path.join(root, "dot-whiska")
    previous = Application.get_env(:whiska, :home)
    Application.put_env(:whiska, :home, home)

    socket = Path.join(root, "herdr.sock")
    was_socket = System.get_env("HERDR_SOCKET_PATH")
    System.put_env("HERDR_SOCKET_PATH", socket)

    on_exit(fn ->
      Application.put_env(:whiska, :home, previous)

      if was_socket,
        do: System.put_env("HERDR_SOCKET_PATH", was_socket),
        else: System.delete_env("HERDR_SOCKET_PATH")

      File.rm_rf!(root)
    end)

    {:ok, root: root, socket: socket}
  end

  defp house!(root, name) do
    main = Path.join(root, name)
    File.mkdir_p!(Path.join(main, ".git"))
    {:ok, handle} = Storage.open(main)
    Storage.close(handle)
    OpenHouses.add(main)
    main
  end

  defp seed(main, fun) do
    {:ok, handle} = Storage.open(main)
    result = fun.()
    Storage.close(handle)
    result
  end

  defp mouse(id, branch, pane) do
    {:ok, _} =
      Storage.record_mouse(%{mouse_id: id, path: "/w/#{branch}", branch: branch, pane: pane})
  end

  defp ask(mouse_id, text, age_s \\ 0) do
    {:ok, _} =
      Storage.record_question(%{
        mouse_id: mouse_id,
        text: text,
        kind: "needs-decision",
        status: "open",
        asked_at:
          DateTime.utc_now() |> DateTime.add(-age_s, :second) |> DateTime.truncate(:second)
      })
  end

  describe "whiska waiting" do
    test "lists one line per waiting question, across every recorded house", %{root: root} do
      a = house!(root, "alpha")
      b = house!(root, "beta")

      seed(a, fn ->
        mouse("m1", "feat-a", "%1")
        ask("m1", "[worktree-status: needs-decision] newer", 10)
      end)

      seed(b, fn ->
        mouse("m2", "feat-b", "%2")
        ask("m2", "[worktree-status: needs-decision] older", 600)
      end)

      out = capture_io(fn -> assert CLI.run(["waiting"], a) == 0 end)
      [first, second] = out |> String.trim() |> String.split("\n")

      assert first =~ "beta"
      assert first =~ "feat-b"
      assert first =~ "older"
      assert first =~ "%2"
      assert second =~ "alpha"
      assert second =~ "newer"
    end

    test "says so plainly when nothing is waiting anywhere", %{root: root} do
      main = house!(root, "alpha")
      out = capture_io(fn -> assert CLI.run(["waiting"], main) == 0 end)
      assert out =~ "Nothing is waiting on you"
    end

    test "--json prints an array a script can read", %{root: root} do
      main = house!(root, "alpha")

      seed(main, fn ->
        mouse("m1", "feat-a", "%3")
        ask("m1", "[worktree-status: needs-decision] pick one")
      end)

      out = capture_io(fn -> assert CLI.run(["waiting", "--json"], main) == 0 end)

      assert {:ok, [entry]} = JSON.decode(String.trim(out))

      assert %{
               "repo" => "alpha",
               "branch" => "feat-a",
               "kind" => "needs-decision",
               "status" => "open",
               "pointer" => "pick one",
               "pane" => "%3"
             } = entry
    end

    test "--json on an empty machine is an empty array, not an error", %{root: root} do
      main = house!(root, "alpha")
      out = capture_io(fn -> assert CLI.run(["waiting", "--json"], main) == 0 end)
      assert {:ok, []} = JSON.decode(String.trim(out))
    end

    test "works from outside any checkout — it is not repo-scoped", %{root: root} do
      main = house!(root, "alpha")

      seed(main, fn ->
        mouse("m1", "feat-a", "%1")
        ask("m1", "[worktree-status: needs-decision] pick")
      end)

      plain = Path.join(root, "not-a-repo")
      File.mkdir_p!(plain)

      out = capture_io(fn -> assert CLI.run(["waiting"], plain) == 0 end)
      assert out =~ "feat-a"
    end

    test "is in the usage text" do
      out = capture_io(fn -> assert CLI.run(["--help"]) == 0 end)
      assert out =~ "waiting"
      assert out =~ "jump"
    end
  end

  describe "whiska jump" do
    test "focuses the pane of the oldest waiting question", %{root: root, socket: socket} do
      a = house!(root, "alpha")
      b = house!(root, "beta")

      seed(a, fn ->
        mouse("m1", "feat-a", "%1")
        ask("m1", "[worktree-status: needs-decision] newer", 10)
      end)

      seed(b, fn ->
        mouse("m2", "feat-b", "%2")
        ask("m2", "[worktree-status: needs-decision] older", 600)
      end)

      expect(Herdr, :focus, fn ^socket, "%2" -> :ok end)

      out = capture_io(fn -> assert CLI.run(["jump"], a) == 0 end)
      assert out =~ "feat-b"
      assert out =~ "beta"
      assert out =~ "%2"
    end

    test "says 'nothing waiting' and changes nothing when nothing is", %{root: root} do
      main = house!(root, "alpha")
      out = capture_io(fn -> assert CLI.run(["jump"], main) == 0 end)
      assert out =~ "nothing waiting"
    end

    test "with a branch, focuses that mouse's pane whether or not it is waiting", %{
      root: root,
      socket: socket
    } do
      a = house!(root, "alpha")
      b = house!(root, "beta")
      seed(a, fn -> mouse("m1", "feat-a", "%1") end)
      seed(b, fn -> mouse("m2", "feat-quiet", "%7") end)

      expect(Herdr, :focus, fn ^socket, "%7" -> :ok end)

      out = capture_io(fn -> assert CLI.run(["jump", "feat-quiet"], a) == 0 end)
      assert out =~ "feat-quiet"
      assert out =~ "%7"
    end

    test "refuses a branch no house has", %{root: root} do
      main = house!(root, "alpha")

      err =
        capture_io(:stderr, fn ->
          assert CLI.run(["jump", "feat-nope"], main) == 1
        end)

      assert err =~ "feat-nope"
    end

    test "says so when the branch's mouse has no pane recorded", %{root: root} do
      main = house!(root, "alpha")
      seed(main, fn -> mouse("m1", "feat-a", nil) end)

      err = capture_io(:stderr, fn -> assert CLI.run(["jump", "feat-a"], main) == 1 end)
      assert err =~ "no pane"
    end

    test "reports herdr refusing, and does not claim to have jumped", %{
      root: root,
      socket: socket
    } do
      main = house!(root, "alpha")

      seed(main, fn ->
        mouse("m1", "feat-a", "%1")
        ask("m1", "[worktree-status: needs-decision] pick")
      end)

      expect(Herdr, :focus, fn ^socket, "%1" ->
        {:error, {:herdr, %{"code" => "pane_not_found", "message" => "gone"}}}
      end)

      err = capture_io(:stderr, fn -> assert CLI.run(["jump"], main) == 1 end)
      assert err =~ "pane_not_found"
    end

    test "says so when herdr's socket is not set", %{root: root} do
      System.delete_env("HERDR_SOCKET_PATH")
      main = house!(root, "alpha")

      seed(main, fn ->
        mouse("m1", "feat-a", "%1")
        ask("m1", "[worktree-status: needs-decision] pick")
      end)

      err = capture_io(:stderr, fn -> assert CLI.run(["jump"], main) == 1 end)
      assert err =~ "HERDR_SOCKET_PATH"
    end
  end
end
