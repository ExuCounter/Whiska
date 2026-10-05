defmodule Whiska.CLIMiceTest do
  @moduledoc "`whiska mice` at the binary."
  # Serial: the code under test opens the house under the one VM-wide name `Whiska.Repo`.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import Mox

  alias Whiska.CLI
  alias Whiska.Herdr.Mock, as: Herdr
  alias Whiska.Storage

  setup :verify_on_exit!

  setup do
    root = Path.join(System.tmp_dir!(), "whiska-climice-#{System.unique_integer([:positive])}")
    main = Path.join(root, "myrepo")
    worktree = Path.join(main, "worktrees/feat-thing")
    File.mkdir_p!(Path.join(main, ".git"))
    File.mkdir_p!(worktree)
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

    {:ok, root: root, main: main, worktree: worktree}
  end

  defp seed(main, mice) do
    {:ok, handle} = Storage.open(main, name: :seed)

    for {id, branch, dead?} <- mice do
      path = Path.join(main, "worktrees/#{branch}")
      {:ok, _} = Storage.record_mouse(%{mouse_id: id, path: path, branch: branch})
      if dead?, do: {:ok, _} = Storage.mark_dead(id)
    end

    Storage.close(handle)
  end

  describe "whiska mice" do
    test "lists each alive mouse on its own line and leaves dead ones out", %{main: main} do
      seed(main, [{"ma", "feat-a", false}, {"mb", "feat-b", false}, {"mc", "feat-c", true}])
      stub(Herdr, :list_panes, fn _ -> {:ok, []} end)

      out = capture_io(fn -> assert CLI.run(["mice"], main) == 0 end)

      assert out =~ "feat-a"
      assert out =~ "feat-b"
      refute out =~ "feat-c"
      assert length(String.split(String.trim(out), "\n")) == 2
    end

    test "shows branch, mode, status and uptime", %{main: main} do
      seed(main, [{"ma", "feat-a", false}])
      {:ok, handle} = Storage.open(main, name: :seed)
      {:ok, _} = Storage.set_mode("ma", "sniff")
      Storage.close(handle)

      stub(Herdr, :list_panes, fn _ ->
        {:ok,
         [
           %{
             pane_id: "w1:p1",
             cwd: Path.join(main, "worktrees/feat-a"),
             agent: "claude",
             agent_status: "idle"
           }
         ]}
      end)

      out = capture_io(fn -> assert CLI.run(["mice"], main) == 0 end)

      assert out =~ ~r/feat-a\s+sniff\s+idle\s+\d+s/
    end

    test "names the model and effort, and says when a mouse was never shaped", %{main: main} do
      seed(main, [{"ma", "feat-a", false}, {"mb", "feat-b", false}])
      {:ok, handle} = Storage.open(main, name: :seed)
      {:ok, _} = Storage.shape("ma", "sniff", "m-light", "xhigh")
      Storage.close(handle)
      stub(Herdr, :list_panes, fn _ -> {:ok, []} end)

      out = capture_io(fn -> assert CLI.run(["mice"], main) == 0 end)

      assert out =~ ~r/feat-a\s+sniff on m-light, xhigh effort\s/
      assert out =~ ~r/feat-b\s+never shaped, reads only\s/
    end

    # A sniff mouse moved to build by hand keeps the model and effort chosen
    # for the investigation; the listing is where that shows rather than hides.
    test "says when a mouse's mode was moved off what it was shaped as", %{main: main} do
      seed(main, [{"ma", "feat-a", false}, {"mb", "feat-b", false}])
      {:ok, handle} = Storage.open(main, name: :seed)
      {:ok, _} = Storage.shape("ma", "sniff", "m-heavy", "xhigh")
      {:ok, _} = Storage.set_mode("ma", "build")
      {:ok, _} = Storage.shape("mb", "sniff", "m-heavy", "xhigh")
      Storage.close(handle)
      stub(Herdr, :list_panes, fn _ -> {:ok, []} end)

      out = capture_io(fn -> assert CLI.run(["mice"], main) == 0 end)

      assert out =~ ~r/feat-a\s+build on m-heavy, xhigh effort \(shaped as sniff\)\s/
      assert out =~ ~r/feat-b\s+sniff on m-heavy, xhigh effort\s/
      refute out =~ ~r/feat-b.*shaped as/
    end

    test "names the model that actually ran, once a turn has said", %{main: main} do
      seed(main, [{"ma", "feat-a", false}])
      {:ok, handle} = Storage.open(main, name: :seed)
      {:ok, _} = Storage.shape("ma", "build", "m-light", nil)
      {:ok, _} = Storage.record_mouse(%{mouse_id: "ma", ran_on: "claude-m-light-5"})
      Storage.close(handle)
      stub(Herdr, :list_panes, fn _ -> {:ok, []} end)

      out = capture_io(fn -> assert CLI.run(["mice"], main) == 0 end)

      assert out =~ ~r/feat-a\s+build on claude-m-light-5\s/
    end

    test "works from inside a worktree, listing the whole house", %{
      main: main,
      worktree: worktree
    } do
      seed(main, [{"ma", "feat-a", false}])
      stub(Herdr, :list_panes, fn _ -> {:ok, []} end)

      out = capture_io(fn -> assert CLI.run(["mice"], worktree) == 0 end)

      assert out =~ "feat-a"
    end

    test "says so when nothing is alive", %{main: main} do
      stub(Herdr, :list_panes, fn _ -> {:ok, []} end)

      out = capture_io(fn -> assert CLI.run(["mice"], main) == 0 end)

      assert out =~ "No mice alive"
    end

    test "explains itself outside a git checkout", %{root: root} do
      plain = Path.join(root, "plain")
      File.mkdir_p!(plain)

      stderr = capture_io(:stderr, fn -> assert CLI.run(["mice"], plain) == 1 end)

      assert stderr =~ "not a git checkout"
    end

    test "is in the usage text" do
      stderr = capture_io(:stderr, fn -> assert CLI.run([]) == 1 end)
      assert stderr =~ "mice"
    end
  end
end
