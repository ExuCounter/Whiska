defmodule Whiska.CLIWaitingTest do
  @moduledoc """
  `whiska waiting` and `whiska jump` — the two commands a global hotkey drives.

  `waiting` reads every house in the open-houses record and changes nothing;
  `jump` asks herdr to focus one pane (ADR-0043), faked at the boundary
  ADR-0031 names. Houses are real SQLite files under a tmp root, and the record
  is this test's own file, pointed at through the `:home` setting.
  """
  # Serial: the code under test opens the house under the one VM-wide name
  # `Whiska.Repo`, the tests move the global `:home`,
  # and they set HOME and HERDR_SOCKET_PATH in the OS env.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import Mox

  alias Whiska.CLI
  alias Whiska.Herdr.Mock, as: Herdr
  alias Whiska.OpenHouses
  alias Whiska.Storage

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

  # A shell with no HERDR_SOCKET_PATH in it — a Raycast hotkey runs a script
  # command with no shell environment at all — and herdr's socket sitting where
  # herdr always puts it (ADR-0040).
  defp no_variable_but_a_socket(root) do
    home = Path.join(root, "home")
    default = Path.join(home, ".config/herdr/herdr.sock")
    File.mkdir_p!(Path.dirname(default))
    File.touch!(default)
    pretend_home(home)
    default
  end

  defp pretend_home(home) do
    was_home = System.get_env("HOME")
    System.delete_env("HERDR_SOCKET_PATH")
    System.put_env("HOME", home)
    on_exit(fn -> if was_home, do: System.put_env("HOME", was_home) end)
    home
  end

  # What `whiska start` records: this house's main session (ADR-0043).
  defp started(pane), do: :ok = Storage.set_main_pane(pane)

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
      assert out =~ "🦉 Nothing needs you"
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

  # A jump lands on the house's main session, never on a mouse's pane
  # (ADR-0043, rewritten 2026-09-28): the main session is the pane the question
  # was delivered into and the pane the person answers from.
  describe "whiska jump" do
    test "focuses the main session of the house with the oldest waiting question", %{
      root: root,
      socket: socket
    } do
      a = house!(root, "alpha")
      b = house!(root, "beta")

      seed(a, fn ->
        started("w1:p1")
        mouse("m1", "feat-a", "%1")
        ask("m1", "[worktree-status: needs-decision] newer", 10)
      end)

      seed(b, fn ->
        started("w2:p1")
        mouse("m2", "feat-b", "%2")
        ask("m2", "[worktree-status: needs-decision] older", 600)
      end)

      expect(Herdr, :focus, fn ^socket, "w2:p1" -> :ok end)

      out = capture_io(fn -> assert CLI.run(["jump"], a) == 0 end)
      assert out =~ "beta"
      assert out =~ "w2:p1"
      refute out =~ "%2"
    end

    test "says 'nothing waiting' and changes nothing when nothing is", %{root: root} do
      main = house!(root, "alpha")
      out = capture_io(fn -> assert CLI.run(["jump"], main) == 0 end)
      assert out =~ "🦉 Nothing needs you"
    end

    test "with a repo name, focuses that house's main session, waiting or not", %{
      root: root,
      socket: socket
    } do
      a = house!(root, "alpha")
      b = house!(root, "beta")
      seed(a, fn -> started("w1:p1") end)
      seed(b, fn -> started("w2:p1") end)

      expect(Herdr, :focus, fn ^socket, "w2:p1" -> :ok end)

      out = capture_io(fn -> assert CLI.run(["jump", "beta"], a) == 0 end)
      assert out =~ "beta"
    end

    test "with a branch, focuses the main session of the house that mouse works in", %{
      root: root,
      socket: socket
    } do
      a = house!(root, "alpha")
      b = house!(root, "beta")
      seed(a, fn -> started("w1:p1") end)
      seed(b, fn -> started("w2:p1") end)
      seed(b, fn -> mouse("m2", "feat-quiet", "%7") end)

      expect(Herdr, :focus, fn ^socket, "w2:p1" -> :ok end)

      out = capture_io(fn -> assert CLI.run(["jump", "feat-quiet"], a) == 0 end)
      assert out =~ "beta"
      refute out =~ "%7"
    end

    test "refuses a name that is neither a repo nor a branch", %{root: root} do
      main = house!(root, "alpha")

      err =
        capture_io(:stderr, fn ->
          assert CLI.run(["jump", "feat-nope"], main) == 1
        end)

      assert err =~ "feat-nope"
    end

    # Exit 0, like nothing waiting: the hotkey is pressed on spec, and a house
    # nobody has run `whiska start` in is a thing to fix, not a failure.
    test "says so and exits 0 when the house has no main session recorded", %{root: root} do
      main = house!(root, "alpha")

      seed(main, fn ->
        mouse("m1", "feat-a", "%1")
        ask("m1", "[worktree-status: needs-decision] pick")
      end)

      out = capture_io(fn -> assert CLI.run(["jump"], main) == 0 end)
      assert out =~ "alpha"
      assert out =~ "whiska start"
    end

    test "reports herdr refusing, and does not claim to have jumped", %{
      root: root,
      socket: socket
    } do
      main = house!(root, "alpha")

      seed(main, fn ->
        started("w1:p1")
        mouse("m1", "feat-a", "%1")
        ask("m1", "[worktree-status: needs-decision] pick")
      end)

      expect(Herdr, :focus, fn ^socket, "w1:p1" ->
        {:error, {:herdr, %{"code" => "pane_not_found", "message" => "gone"}}}
      end)

      err = capture_io(:stderr, fn -> assert CLI.run(["jump"], main) == 1 end)
      assert err =~ "pane_not_found"
    end

    # Bug, 2026-09-28: a Raycast hotkey running `open -a kitty && whiska jump`
    # got "HERDR_SOCKET_PATH is not set — cannot ask herdr to focus a pane",
    # because Raycast runs a script command with no shell environment. The owl
    # under launchd has the same problem and already falls back (ADR-0040).
    test "falls back to herdr's default socket when the variable is unset", %{root: root} do
      default = no_variable_but_a_socket(root)
      main = house!(root, "alpha")

      seed(main, fn ->
        started("w1:p1")
        mouse("m1", "feat-a", "%1")
        ask("m1", "[worktree-status: needs-decision] pick")
      end)

      expect(Herdr, :focus, fn ^default, "w1:p1" -> :ok end)

      out = capture_io(fn -> assert CLI.run(["jump"], main) == 0 end)
      assert out =~ "Jumped"
    end

    test "says herdr's default socket is not there when nothing set the variable", %{
      root: root
    } do
      pretend_home(Path.join(root, "home"))
      main = house!(root, "alpha")

      seed(main, fn ->
        started("w1:p1")
        mouse("m1", "feat-a", "%1")
        ask("m1", "[worktree-status: needs-decision] pick")
      end)

      err = capture_io(:stderr, fn -> assert CLI.run(["jump"], main) == 1 end)
      assert err =~ "HERDR_SOCKET_PATH"
      assert err =~ ".config/herdr/herdr.sock"
    end
  end
end
