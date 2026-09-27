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
end
