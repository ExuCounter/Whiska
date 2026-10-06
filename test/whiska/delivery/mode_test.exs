defmodule Whiska.Delivery.ModeTest do
  @moduledoc """
  What may reach the person right now (ADR-0079):
  away is machine-wide and on disk, a focus is one house's, a hold is one
  mouse's. The queue is judged against all three before the gate ever sees it.
  """
  use ExUnit.Case, async: true

  alias Whiska.Delivery.Mode
  alias Whiska.Schema.Question

  setup do
    root = Path.join(System.tmp_dir!(), "whiska-mode-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, away: Path.join(root, "away")}
  end

  defp q(id, mouse_id, status, kind \\ "needs-decision"),
    do: %Question{id: id, mouse_id: mouse_id, status: status, kind: kind}

  defp mode(attrs \\ []) do
    Map.merge(Mode.none(), Map.new(attrs))
  end

  describe "away, on disk" do
    test "is off until the person sets it", %{away: away} do
      refute Mode.away?(away)
    end

    test "set_away/1 turns it on and clear_away/1 off", %{away: away} do
      assert :ok = Mode.set_away(away)
      assert Mode.away?(away)
      assert :ok = Mode.clear_away(away)
      refute Mode.away?(away)
    end

    test "setting it twice and clearing it twice are fine", %{away: away} do
      :ok = Mode.set_away(away)
      assert :ok = Mode.set_away(away)
      :ok = Mode.clear_away(away)
      assert :ok = Mode.clear_away(away)
    end

    test "the file lives under the whiska home, beside the open-houses record" do
      assert Path.dirname(Mode.away_path()) == Whiska.OpenHouses.home()
    end

    test "a symlink where the file would go is refused, and its target untouched", %{away: away} do
      target = away <> "-target"
      File.write!(target, "mine\n")
      File.ln_s!(target, away)

      assert {:error, :symlink} = Mode.set_away(away)
      assert File.read!(target) == "mine\n"
    end
  end

  describe "deliverable?/2" do
    test "with no mode set, everything is" do
      assert Mode.deliverable?(q(1, "ma", "open"), mode())
    end

    test "nothing is while away" do
      refute Mode.deliverable?(q(1, "ma", "open"), mode(away?: true))
    end

    test "a held mouse's question is not" do
      refute Mode.deliverable?(q(1, "ma", "open"), mode(held: MapSet.new(["ma"])))
      assert Mode.deliverable?(q(2, "mb", "open"), mode(held: MapSet.new(["ma"])))
    end

    test "under a focus only the focused mouse's is" do
      assert Mode.deliverable?(q(1, "ma", "open"), mode(focus: "ma"))
      refute Mode.deliverable?(q(2, "mb", "open"), mode(focus: "ma"))
    end

    test "a focused mouse that is also held is not" do
      refute Mode.deliverable?(q(1, "ma", "open"), mode(focus: "ma", held: MapSet.new(["ma"])))
    end
  end

  describe "waits/2 — why a question is not being delivered" do
    test "nil when nothing stands in its way" do
      assert Mode.waits(q(1, "ma", "open"), mode()) == nil
    end

    test "held comes first, then away, then the focus" do
      held = MapSet.new(["ma"])
      assert Mode.waits(q(1, "ma", "open"), mode(away?: true, focus: "mb", held: held)) == :held
      assert Mode.waits(q(2, "mb", "open"), mode(away?: true, focus: "mc")) == :away
      assert Mode.waits(q(3, "mb", "open"), mode(focus: "mc")) == {:focus, "mc"}
    end
  end

  describe "next/2 — what goes next, if the main session will have it" do
    test "a finished report first, then the oldest open question" do
      questions = [q(1, "ma", "open"), q(2, "mb", "open", "done")]
      assert %Question{id: 2} = Mode.next(questions, mode())
    end

    test "nothing while a deliverable question is already sent" do
      assert Mode.next([q(1, "ma", "sent"), q(2, "mb", "open")], mode()) == nil
    end

    test "a finished report never waits for the slot" do
      assert %Question{id: 2} =
               Mode.next([q(1, "ma", "sent"), q(2, "mb", "open", "done")], mode())
    end

    test "nothing at all while away, a finished report included" do
      refute Mode.next([q(1, "ma", "open"), q(2, "mb", "open", "done")], mode(away?: true))
    end

    test "a held mouse's question is skipped, and its sent one frees the slot" do
      held = mode(held: MapSet.new(["ma"]))
      assert %Question{id: 2} = Mode.next([q(1, "ma", "sent"), q(2, "mb", "open")], held)
      assert Mode.next([q(1, "ma", "open")], held) == nil
    end

    test "under a focus the focused mouse's question goes although another's is sent" do
      questions = [q(1, "ma", "sent"), q(2, "mb", "open"), q(3, "mc", "open")]
      assert %Question{id: 3} = Mode.next(questions, mode(focus: "mc"))
    end

    test "under a focus the focused mouse's own sent question still holds the slot" do
      questions = [q(1, "mc", "sent"), q(2, "mc", "open")]
      assert Mode.next(questions, mode(focus: "mc")) == nil
    end

    test "oldest first, never newest" do
      questions = [q(5, "mb", "open"), q(3, "ma", "open"), q(9, "mc", "open")]
      assert %Question{id: 3} = Mode.next(questions, mode())
    end
  end

  describe "slot/2 and open_count/2" do
    test "the slot is the sent question that is deliverable, or nil" do
      assert Mode.slot([q(1, "ma", "sent"), q(2, "mb", "open")], mode()) == 1
      assert Mode.slot([q(1, "ma", "sent")], mode(held: MapSet.new(["ma"]))) == nil
      assert Mode.slot([q(1, "ma", "sent"), q(2, "mc", "sent")], mode(focus: "mc")) == 2
    end

    test "open_count counts only what could be delivered" do
      questions = [q(1, "ma", "open"), q(2, "mb", "open"), q(3, "mc", "sent")]
      assert Mode.open_count(questions, mode()) == 2
      assert Mode.open_count(questions, mode(focus: "mb")) == 1
      assert Mode.open_count(questions, mode(away?: true)) == 0
    end
  end
end
