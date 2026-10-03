defmodule Whiska.CLIDoctorTest do
  @moduledoc "`whiska doctor` from the command line: where it runs, what it prints, how it exits."
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import Mox

  alias Whiska.CLI
  alias Whiska.Herdr.Mock, as: Herdr

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    root = Path.join(System.tmp_dir!(), "whiska-cli-doctor-#{System.unique_integer([:positive])}")
    main = Path.join(root, "myrepo")
    worktree = Path.join(main, "worktrees/feat-thing")
    File.mkdir_p!(Path.join(main, ".git"))
    File.mkdir_p!(worktree)
    on_exit(fn -> File.rm_rf!(root) end)
    stub(Herdr, :notify, fn _socket, _notification -> {:ok, :shown} end)
    {:ok, root: root, main: main, worktree: worktree}
  end

  test "refuses outside a repo", %{root: root} do
    elsewhere = Path.join(root, "not-a-repo")
    File.mkdir_p!(elsewhere)

    err = capture_io(:stderr, fn -> assert CLI.run(["doctor"], elsewhere) == 1 end)
    assert err =~ "not a git checkout"
  end

  test "an uninitialised repo prints the report and exits 1", %{main: main} do
    stub(Herdr, :list_panes, fn _ -> {:ok, []} end)

    {out, status} = with_status(fn -> CLI.run(["doctor"], main) end)

    assert status == 1
    assert out =~ "whiska doctor — myrepo"
    assert out =~ ~r/FAIL  Stop/
    assert out =~ "fix: whiska init"
    assert out =~ "failed"
  end

  test "run from inside a worktree, it examines that worktree's repo", %{worktree: worktree} do
    stub(Herdr, :list_panes, fn _ -> {:ok, []} end)

    {out, _status} = with_status(fn -> CLI.run(["doctor"], worktree) end)

    assert out =~ "whiska doctor — myrepo"
  end

  test "the report says whether a delivered question will be heard (ADR-0062)", %{main: main} do
    stub(Herdr, :list_panes, fn _ -> {:ok, []} end)

    {out, _status} = with_status(fn -> CLI.run(["doctor"], main) end)

    assert out =~ ~r/(ok|warn)\s+hoot/
  end

  test "help lists it" do
    out = capture_io(fn -> CLI.run(["--help"]) end)
    assert out =~ "doctor"
  end

  # stderr is deliberately let through: a doctor's diagnostics are the point.
  defp with_status(fun) do
    holder = self()
    out = capture_io(fn -> capture_io(:stderr, fn -> send(holder, {:code, fun.()}) end) end)
    receive do: ({:code, code} -> {out, code})
  end
end
