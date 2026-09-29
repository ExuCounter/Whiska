defmodule Whiska.Question.MarkerTest do
  use ExUnit.Case, async: true

  alias Whiska.Question.Marker

  describe "classify/1 (ADR-0009: no marker means deliver)" do
    test "needs-decision" do
      assert Marker.classify("Three options.\n[worktree-status: needs-decision] pick one") ==
               "needs-decision"
    end

    test "done" do
      assert Marker.classify("Merged.\n[worktree-status: done]") == "done"
    end

    test "no marker at all is unmarked" do
      assert Marker.classify("Still working on it, back soon.") == "unmarked"
    end

    test "an empty message is unmarked" do
      assert Marker.classify("") == "unmarked"
    end

    test "a marker naming something unknown is unmarked, not silently done" do
      assert Marker.classify("[worktree-status: finished]") == "unmarked"
    end

    test "the last marker wins" do
      text = "[worktree-status: needs-decision] earlier\n...\n[worktree-status: done]"
      assert Marker.classify(text) == "done"
    end

    test "the marker may carry an invisible prefix so it never shows in the transcript" do
      for invisible <- ["​", "⁠", "﻿"] do
        assert Marker.classify("ok\n#{invisible}[worktree-status: done]") == "done",
               "prefix #{inspect(invisible)} was not recognised"
      end
    end

    test "a needs-decision marker that mentions done is still needs-decision" do
      assert Marker.classify("[worktree-status: needs-decision] is the migration done?") ==
               "needs-decision"
    end

    test "the marker may sit mid-line, since the hook reads the whole message" do
      assert Marker.classify("Result: [worktree-status: done] all set") == "done"
    end
  end

  describe "pointer/1" do
    test "is what the mouse wrote after its marker on the same line" do
      assert Marker.pointer(
               "body\n[worktree-status: needs-decision] 3 questions ready, see above"
             ) ==
               "3 questions ready, see above"
    end

    test "is empty when the marker stands alone" do
      assert Marker.pointer("done\n[worktree-status: done]") == ""
      assert Marker.pointer("[worktree-status: done]\n") == ""
    end

    test "for an unmarked message it is the first non-empty line" do
      assert Marker.pointer("\n\nI stopped here.\nmore") == "I stopped here."
      assert Marker.pointer("") == ""
    end

    test "the last marker wins here too" do
      text = "[worktree-status: done] old\n[worktree-status: needs-decision] new"
      assert Marker.pointer(text) == "new"
    end
  end

  describe "render/1 — the marker Whiska tells a mouse to write" do
    test "renders exactly what classify/1 reads back" do
      for {status, kind} <- [{:done, "done"}, {:needs_decision, "needs-decision"}] do
        assert Marker.classify(Marker.render(status)) == kind
      end
    end

    test "is the literal spelling, so the CLAUDE.md block can quote it" do
      assert Marker.render(:done) == "[worktree-status: done]"
      assert Marker.render(:needs_decision) == "[worktree-status: needs-decision]"
    end
  end
end
