defmodule Whiska.ReminderTest do
  use ExUnit.Case, async: true

  alias Whiska.Delivery.Mode
  alias Whiska.Reminder
  alias Whiska.Schema.Mouse
  alias Whiska.Schema.Question
  alias Whiska.Test.GitRepo

  @now ~U[2026-10-14 12:00:00Z]
  @two_hours 7_200_000

  defp report(mouse_id, hooted_at) do
    %Question{
      id: System.unique_integer([:positive]),
      mouse_id: mouse_id,
      kind: "done",
      status: "closed",
      hooted_at: hooted_at,
      mouse: %Mouse{mouse_id: mouse_id, branch: mouse_id}
    }
  end

  defp house(overrides \\ %{}) do
    Map.merge(
      %{
        mode: Mode.none(),
        now: @now,
        remind_ms: @two_hours,
        reminded_at: DateTime.add(@now, -3, :hour),
        nothing_to_land: %{},
        work?: fn _report -> true end
      },
      overrides
    )
  end

  defp ago(hours), do: DateTime.add(@now, -hours * 3600)

  describe "due/2" do
    test "a report never hooted is owed its finish hoot, whatever the reminder clock says" do
      owed = report("ma", nil)

      assert %{finish: [^owed], remind: [], nothing_to_land: []} =
               Reminder.due([owed], house(%{reminded_at: @now}))
    end

    test "a reminder names each report hooted at least remind_ms ago, once the house is due" do
      old = report("ma", ago(5))
      due = report("mb", ago(2))
      fresh = report("mc", ago(1))

      assert %{finish: [], remind: [^old, ^due]} = Reminder.due([old, due, fresh], house())
    end

    test "nothing is reminded while the house reminded less than remind_ms ago" do
      assert %{remind: []} =
               Reminder.due([report("ma", ago(5))], house(%{reminded_at: ago(1)}))
    end

    test "a branch with no work of its own to land is never reminded, and said to have nothing to land" do
      idle = report("ma", ago(5))
      busy = report("mb", ago(5))

      assert %{remind: [^busy], nothing_to_land: [^idle]} =
               Reminder.due([idle, busy], house(%{work?: &(&1.mouse_id == "mb")}))
    end

    test "git is asked only once the house is due, and only about reports due themselves" do
      test = self()
      work? = fn report -> send(test, {:asked, report.mouse_id}) && true end

      Reminder.due([report("ma", ago(5))], house(%{reminded_at: ago(1), work?: work?}))
      Reminder.due([report("mb", ago(1)), report("mc", nil)], house(%{work?: work?}))
      refute_received {:asked, _}
    end

    test "a report found with nothing to land is asked about again only remind_ms later" do
      test = self()
      landless = report("ma", ago(5))
      work? = fn report -> send(test, {:asked, report.mouse_id}) && false end

      assert %{remind: [], nothing_to_land: []} =
               Reminder.due(
                 [landless],
                 house(%{nothing_to_land: %{landless.id => ago(1)}, work?: work?})
               )

      refute_received {:asked, _}

      assert %{remind: [], nothing_to_land: [^landless]} =
               Reminder.due(
                 [landless],
                 house(%{nothing_to_land: %{landless.id => ago(2)}, work?: work?})
               )

      assert_received {:asked, "ma"}
    end

    test "away, a focus on another branch, or a hold leaves a report owed nothing" do
      reports = [report("ma", nil), report("mb", ago(5))]

      for mode <- [
            %{Mode.none() | away?: true},
            %{Mode.none() | focus: "mz"},
            %{Mode.none() | held: MapSet.new(["ma", "mb"])}
          ] do
        assert Reminder.due(reports, house(%{mode: mode})) == %{
                 finish: [],
                 remind: [],
                 nothing_to_land: []
               }
      end
    end
  end

  describe "work?/2" do
    setup do
      root = Path.join(System.tmp_dir!(), "whiska-remind-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(root) end)
      {:ok, repo: GitRepo.create(root)}
    end

    defp mouse(branch, path),
      do: %Mouse{mouse_id: branch, branch: branch, path: path, base: "main"}

    test "a commit beyond its base is work", %{repo: repo} do
      path = GitRepo.worktree(repo, "feat-a", push: false)
      assert Reminder.work?(repo.checkout, mouse("feat-a", path))
    end

    test "a branch where it was cut is not", %{repo: repo} do
      path = GitRepo.worktree(repo, "feat-a", commit: false, push: false)
      refute Reminder.work?(repo.checkout, mouse("feat-a", path))
    end

    test "a file not committed is not, and git never runs in the worktree", %{repo: repo} do
      path = GitRepo.worktree(repo, "feat-a", commit: false, push: false)
      File.write!(Path.join(path, "notes.md"), "draft")
      File.write!(Path.join(path, ".git"), "gitdir: #{Path.join(repo.root, "nowhere")}\n")

      refute Reminder.work?(repo.checkout, mouse("feat-a", path))
    end

    test "a branch landed on its base is not", %{repo: repo} do
      path = GitRepo.worktree(repo, "feat-a")
      :ok = GitRepo.land(repo, "feat-a")
      refute Reminder.work?(repo.checkout, mouse("feat-a", path))
    end

    test "a mouse with no branch has nothing to land", %{repo: repo} do
      path = GitRepo.worktree(repo, "feat-a", push: false)
      refute Reminder.work?(repo.checkout, %Mouse{mouse_id: "ma", path: path, branch: nil})
    end

    test "a branch git cannot read counts as work", %{repo: repo} do
      gone = Path.join(repo.root, "worktrees/nowhere")
      assert Reminder.work?(repo.checkout, mouse("nowhere", gone))
    end
  end
end
