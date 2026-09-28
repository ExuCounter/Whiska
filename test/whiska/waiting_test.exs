defmodule Whiska.WaitingTest do
  @moduledoc """
  `Whiska.Waiting`: one entry per thing waiting on the person, across every
  house in the open-houses record (ADR-0039) rather than just the one you
  happen to be standing in.

  Houses are real SQLite files under a tmp root, and the record is this test's
  own file. Nothing here asks herdr: a waiting entry is on-disk data, and it
  reads the same whether the owl is up or down.
  """
  use ExUnit.Case, async: false

  alias Whiska.Doorstep
  alias Whiska.Doorstep.Entry
  alias Whiska.OpenHouses
  alias Whiska.Storage
  alias Whiska.Waiting

  setup do
    root = Path.join(System.tmp_dir!(), "whiska-waiting-#{System.unique_integer([:positive])}")
    record = Path.join(root, "dot-whiska/houses")
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root, record: record}
  end

  # A repo with a house, recorded as open.
  defp house!(root, name, record) do
    main = Path.join(root, name)
    File.mkdir_p!(Path.join(main, ".git"))
    {:ok, handle} = Storage.open(main)
    Storage.close(handle)
    OpenHouses.add(main, record)
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

  defp ask(mouse_id, text, opts \\ []) do
    {:ok, q} =
      Storage.record_question(%{
        mouse_id: mouse_id,
        text: text,
        kind: Keyword.get(opts, :kind, "needs-decision"),
        status: Keyword.get(opts, :status, "open"),
        asked_at: Keyword.get(opts, :asked_at, ago(0))
      })

    q
  end

  defp leave(main, mouse_id, branch, text, age_s) do
    {:ok, _} =
      Doorstep.leave(main, %Entry{
        mouse_id: mouse_id,
        branch: branch,
        worktree_root: "/w/#{branch}",
        stamped_at: DateTime.add(DateTime.utc_now(), -age_s, :second),
        text: text
      })
  end

  defp ago(seconds),
    do: DateTime.utc_now() |> DateTime.add(-seconds, :second) |> DateTime.truncate(:second)

  describe "list/1" do
    test "is empty when no house is recorded", %{record: record} do
      assert Waiting.list(open_houses: record) == []
    end

    test "one entry per open question, with everything the person needs", %{
      root: root,
      record: record
    } do
      main = house!(root, "myrepo", record)

      seed(main, fn ->
        mouse("m1", "feat-a", "%3")
        ask("m1", "[worktree-status: needs-decision] pick one", asked_at: ago(120))
      end)

      assert [entry] = Waiting.list(open_houses: record)

      assert %{
               repo: "myrepo",
               main_checkout: ^main,
               branch: "feat-a",
               id: id,
               kind: "needs-decision",
               status: "open",
               pointer: "pick one",
               pane: "%3"
             } = entry

      assert is_integer(id)
      assert entry.age_s >= 120
    end

    test "reads every recorded house, not just one", %{root: root, record: record} do
      a = house!(root, "alpha", record)
      b = house!(root, "beta", record)

      seed(a, fn ->
        mouse("m1", "feat-a", "%1")
        ask("m1", "[worktree-status: needs-decision] a")
      end)

      seed(b, fn ->
        mouse("m2", "feat-b", "%2")
        ask("m2", "[worktree-status: needs-decision] b")
      end)

      assert Waiting.list(open_houses: record) |> Enum.map(& &1.repo) |> Enum.sort() ==
               ["alpha", "beta"]
    end

    test "oldest first, across houses", %{root: root, record: record} do
      a = house!(root, "alpha", record)
      b = house!(root, "beta", record)

      seed(a, fn ->
        mouse("m1", "feat-a", "%1")
        ask("m1", "[worktree-status: needs-decision] newer", asked_at: ago(10))
      end)

      seed(b, fn ->
        mouse("m2", "feat-b", "%2")
        ask("m2", "[worktree-status: needs-decision] older", asked_at: ago(600))
      end)

      assert Waiting.list(open_houses: record) |> Enum.map(& &1.pointer) == ["older", "newer"]
    end

    test "includes an uncollected doorstep entry, classified by its own marker", %{
      root: root,
      record: record
    } do
      main = house!(root, "myrepo", record)
      seed(main, fn -> mouse("m1", "feat-a", "%9") end)
      leave(main, "m1", "feat-a", "[worktree-status: done] shipped it", 30)

      assert [entry] = Waiting.list(open_houses: record)

      assert %{
               repo: "myrepo",
               branch: "feat-a",
               id: nil,
               kind: "done",
               status: "doorstep",
               pointer: "shipped it",
               pane: "%9"
             } = entry

      assert entry.age_s >= 30
    end

    test "an unmarked turn is a waiting entry too (ADR-0009)", %{root: root, record: record} do
      main = house!(root, "myrepo", record)
      seed(main, fn -> mouse("m1", "feat-a", "%1") end)
      leave(main, "m1", "feat-a", "I stopped without saying why", 5)

      assert [%{kind: "unmarked"}] = Waiting.list(open_houses: record)
    end

    test "a sent question is still waiting; answered and closed ones are not", %{
      root: root,
      record: record
    } do
      main = house!(root, "myrepo", record)

      seed(main, fn ->
        mouse("m1", "feat-a", "%1")
        ask("m1", "[worktree-status: needs-decision] sent", status: "sent")
        ask("m1", "[worktree-status: done] told", status: "closed")
        ask("m1", "[worktree-status: needs-decision] gone", status: "orphaned")
      end)

      assert [%{status: "sent", pointer: "sent"}] = Waiting.list(open_houses: record)
    end

    test "a recorded house with no database yet is simply empty", %{root: root, record: record} do
      main = Path.join(root, "fresh")
      File.mkdir_p!(Path.join(main, ".git"))
      OpenHouses.add(main, record)

      assert Waiting.list(open_houses: record) == []
    end

    test "a recorded checkout that is gone is skipped, not an error", %{
      root: root,
      record: record
    } do
      main = house!(root, "myrepo", record)
      OpenHouses.add(Path.join(root, "vanished"), record)

      seed(main, fn ->
        mouse("m1", "feat-a", "%1")
        ask("m1", "[worktree-status: needs-decision] still here")
      end)

      assert [%{repo: "myrepo"}] = Waiting.list(open_houses: record)
    end

    test "a mouse with no pane recorded still lists, with no pane", %{root: root, record: record} do
      main = house!(root, "myrepo", record)

      seed(main, fn ->
        mouse("m1", "feat-a", nil)
        ask("m1", "[worktree-status: needs-decision] pick")
      end)

      assert [%{pane: nil}] = Waiting.list(open_houses: record)
    end
  end

  describe "waiting?/1 — the statusline's own question, shared" do
    test "true for an open question, true for an uncollected doorstep entry", %{
      root: root,
      record: record
    } do
      main = house!(root, "myrepo", record)
      refute Waiting.waiting?(main)

      seed(main, fn ->
        mouse("m1", "feat-a", "%1")
        ask("m1", "[worktree-status: needs-decision] pick")
      end)

      assert Waiting.waiting?(main)
    end

    test "false for a house that cannot be read", %{root: root} do
      refute Waiting.waiting?(Path.join(root, "nowhere"))
    end
  end

  describe "pane_for/2 — where a branch's mouse lives" do
    test "finds the mouse's pane in whichever house has that branch", %{
      root: root,
      record: record
    } do
      _a = house!(root, "alpha", record)
      b = house!(root, "beta", record)

      seed(b, fn -> mouse("m2", "feat-b", "%7") end)

      assert {:ok, %{pane: "%7", repo: "beta", branch: "feat-b"}} =
               Waiting.pane_for("feat-b", open_houses: record)
    end

    test "says so when no house has that branch", %{root: root, record: record} do
      _a = house!(root, "alpha", record)
      assert Waiting.pane_for("feat-nope", open_houses: record) == {:error, :no_such_branch}
    end

    test "says so when the branch's mouse has no pane", %{root: root, record: record} do
      a = house!(root, "alpha", record)
      seed(a, fn -> mouse("m1", "feat-a", nil) end)

      assert Waiting.pane_for("feat-a", open_houses: record) == {:error, :no_pane}
    end

    test "a house that will not open is skipped, not a crash", %{root: root, record: record} do
      a = house!(root, "alpha", record)
      b = house!(root, "beta", record)
      seed(b, fn -> mouse("m2", "feat-b", "%7") end)

      # A database that exists but cannot be opened: one repo's problem, and
      # `whiska doctor` is where it is explained — never a machine-wide crash.
      File.rm_rf!(Storage.database_path(a))
      File.mkdir_p!(Storage.database_path(a))

      assert {:ok, %{pane: "%7"}} = Waiting.pane_for("feat-b", open_houses: record)
      assert [] = Waiting.house(a)
    end

    test "skips a dead mouse in favour of a live one on the same branch", %{
      root: root,
      record: record
    } do
      a = house!(root, "alpha", record)

      seed(a, fn ->
        mouse("dead", "feat-a", "%1")
        {:ok, _} = Storage.mark_dead("dead")
        mouse("live", "feat-a", "%2")
      end)

      assert {:ok, %{pane: "%2"}} = Waiting.pane_for("feat-a", open_houses: record)
    end
  end

  describe "render/1 — the plain-text listing" do
    test "one line per entry, oldest first, with a word for what it is" do
      lines =
        Waiting.render([
          %{
            repo: "whiska",
            main_checkout: "/r/whiska",
            branch: "feat-a",
            id: 12,
            kind: "needs-decision",
            status: "open",
            pointer: "pick one",
            age_s: 7200,
            pane: "%3"
          }
        ])

      assert lines =~ "whiska"
      assert lines =~ "feat-a"
      assert lines =~ "needs a decision"
      assert lines =~ "2h 0m"
      assert lines =~ "#12"
      assert lines =~ "%3"
    end

    test "says so plainly when nothing is waiting" do
      assert Waiting.render([]) == "Nothing is waiting on you, in any house."
    end
  end

  describe "json/1 — what a Raycast script reads" do
    test "an array of objects, with an age in seconds and a null id for a doorstep entry" do
      json =
        Waiting.json([
          %{
            repo: "whiska",
            main_checkout: "/r/whiska",
            branch: "feat-a",
            id: nil,
            kind: "done",
            status: "doorstep",
            pointer: "shipped",
            age_s: 30,
            pane: "%3"
          }
        ])

      assert {:ok,
              [
                %{
                  "repo" => "whiska",
                  "main_checkout" => "/r/whiska",
                  "branch" => "feat-a",
                  "id" => nil,
                  "kind" => "done",
                  "status" => "doorstep",
                  "pointer" => "shipped",
                  "age_seconds" => 30,
                  "pane" => "%3"
                }
              ]} = JSON.decode(json)
    end

    test "an empty list is an empty array, not an error" do
      assert {:ok, []} = JSON.decode(Waiting.json([]))
    end
  end
end
