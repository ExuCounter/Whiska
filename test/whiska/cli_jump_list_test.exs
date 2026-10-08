defmodule Whiska.CLIJumpListTest do
  @moduledoc """
  `whiska jump --list` — every whiska `jump` can land on, one tab-separated line
  each, the ones waiting on the person first. A script reads it (a herdr popup
  pipes it into fzf), so the fields and their order are the interface.

  Houses are real SQLite files under a tmp root, and the open-houses record is
  this test's own file, pointed at through the `:home` setting.
  """
  # Serial: the code under test opens the house under the one VM-wide name
  # `Whiska.Repo`, and the tests move the global `:home`.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Whiska.CLI
  alias Whiska.OpenHouses
  alias Whiska.Storage

  setup do
    root = Path.join(System.tmp_dir!(), "whiska-clijl-#{System.unique_integer([:positive])}")
    previous = Application.get_env(:whiska, :home)
    Application.put_env(:whiska, :home, Path.join(root, "dot-whiska"))

    on_exit(fn ->
      Application.put_env(:whiska, :home, previous)
      File.rm_rf!(root)
    end)

    {:ok, root: root}
  end

  defp house!(root, name, fun \\ fn -> :ok end) do
    main = Path.join(root, name)
    File.mkdir_p!(Path.join(main, ".git"))
    {:ok, handle} = Storage.open(main)
    fun.()
    Storage.close(handle)
    OpenHouses.add(main)
    main
  end

  defp mouse(id, branch) do
    {:ok, _} =
      Storage.record_mouse(%{mouse_id: id, path: "/w/#{branch}", branch: branch, pane: "%#{id}"})
  end

  defp ask(mouse_id, text, age_s) do
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

  defp lines(argv \\ ["jump", "--list"]) do
    capture_io(fn -> assert CLI.run(argv, nil) == 0 end)
    |> String.split("\n", trim: true)
    |> Enum.map(&String.split(&1, "\t"))
  end

  test "lists every whiska, waiting first and longest wait on top, then quiet, then unstarted",
       %{root: root} do
    late =
      house!(root, "late", fn ->
        :ok = Storage.set_main_pane("w1:p1")
        mouse("m1", "feat-late")
        ask("m1", "[worktree-status: needs-decision] newer\tpart", 30)
      end)

    early =
      house!(root, "early", fn ->
        :ok = Storage.set_main_pane("w2:p1")
        mouse("m2", "feat-early")
        ask("m2", "[worktree-status: needs-decision] first", 600)
        ask("m2", "[worktree-status: needs-decision] second", 60)
      end)

    quiet = house!(root, "quiet", fn -> :ok = Storage.set_main_pane("w3:p1") end)
    also_quiet = house!(root, "also-quiet", fn -> :ok = Storage.set_main_pane("w4:p1") end)
    unstarted = house!(root, "unstarted")

    assert [
             ["early", ^early, "2", age_early, "#1 needs a decision: first"],
             ["late", ^late, "1", age_late, "#1 needs a decision: newer part"],
             ["also-quiet", ^also_quiet, "0", "-", "quiet"],
             ["quiet", ^quiet, "0", "-", "quiet"],
             ["unstarted", ^unstarted, "0", "-", "no main session"]
           ] = lines()

    assert String.to_integer(age_early) >= 600
    assert String.to_integer(age_late) in 30..59
  end

  test "a held mouse's question is not counted as waiting", %{root: root} do
    main =
      house!(root, "parked", fn ->
        :ok = Storage.set_main_pane("w1:p1")
        mouse("m1", "feat-held")
        ask("m1", "[worktree-status: needs-decision] parked", 30)
        {:ok, _} = Storage.hold("m1")
      end)

    assert [["parked", ^main, "0", "-", "quiet"]] = lines()
  end

  test "prints nothing when no house is recorded" do
    assert capture_io(fn -> assert CLI.run(["jump", "--list"], nil) == 0 end) == ""
  end

  test "a house that will not open is left out, and said once on stderr", %{root: root} do
    broken = house!(root, "broken")
    File.rm_rf!(Storage.database_path(broken))
    File.mkdir_p!(Storage.database_path(broken))
    fine = house!(root, "fine", fn -> :ok = Storage.set_main_pane("w1:p1") end)

    stderr = capture_io(:stderr, fn -> assert [["fine", ^fine | _]] = lines() end)

    assert length(String.split(stderr, "could not read broken's house")) == 2
  end

  test "control characters a mouse wrote never reach the summary", %{root: root} do
    house!(root, "noisy", fn ->
      :ok = Storage.set_main_pane("w1:p1")
      mouse("m1", "feat-noisy")
      ask("m1", "[worktree-status: needs-decision] red \e[31mtext\a", 30)
    end)

    assert [["noisy", _, "1", _, "#1 needs a decision: red [31mtext"]] = lines()
  end

  test "--json carries the same fields, null and false where the line says - and no main session",
       %{root: root} do
    solo =
      house!(root, "solo", fn ->
        :ok = Storage.set_main_pane("w1:p1")
        mouse("m1", "feat-solo")
        ask("m1", "[worktree-status: needs-decision] pick one", 30)
      end)

    quiet = house!(root, "quiet", fn -> :ok = Storage.set_main_pane("w2:p1") end)
    unstarted = house!(root, "unstarted")

    out = capture_io(fn -> assert CLI.run(["jump", "--list", "--json"], nil) == 0 end)

    assert [
             %{
               "repo" => "solo",
               "main_checkout" => ^solo,
               "waiting" => 1,
               "oldest_wait_seconds" => age,
               "summary" => "#1 needs a decision: pick one",
               "main_session" => true
             },
             %{
               "repo" => "quiet",
               "main_checkout" => ^quiet,
               "waiting" => 0,
               "oldest_wait_seconds" => nil,
               "summary" => "quiet",
               "main_session" => true
             },
             %{
               "repo" => "unstarted",
               "main_checkout" => ^unstarted,
               "waiting" => 0,
               "oldest_wait_seconds" => nil,
               "summary" => "no main session",
               "main_session" => false
             }
           ] = JSON.decode!(out)

    assert age >= 30
  end
end
