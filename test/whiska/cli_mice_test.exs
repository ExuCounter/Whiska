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
    on_exit(fn -> File.rm_rf!(root) end)
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

    test "names the model, and says when a mouse was never shaped", %{main: main} do
      seed(main, [{"ma", "feat-a", false}, {"mb", "feat-b", false}])
      {:ok, handle} = Storage.open(main, name: :seed)
      {:ok, _} = Storage.shape("ma", "sniff", "sonnet")
      Storage.close(handle)
      stub(Herdr, :list_panes, fn _ -> {:ok, []} end)

      out = capture_io(fn -> assert CLI.run(["mice"], main) == 0 end)

      assert out =~ ~r/feat-a\s+sniff on sonnet\s/
      assert out =~ ~r/feat-b\s+never shaped, reads only\s/
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
