defmodule Whiska.Question.MarkerTest do
  use ExUnit.Case, async: true

  alias Whiska.Question.Marker

  # The marker a mouse writes now: a last line of invisible characters, three
  # for done and two for needs-decision, so the pane shows nothing (ADR-0009).
  @done "⁣⁣⁣"
  @needs "⁣⁣"

  describe "classify/1 (ADR-0009: no marker means deliver)" do
    test "done is a last line of three invisible separators" do
      assert Marker.classify("Merged.\n#{@done}") == "done"
    end

    test "needs-decision is a last line of two" do
      assert Marker.classify("Three options.\npick one\n#{@needs}") == "needs-decision"
    end

    test "the older bracket spelling still classifies, so a mouse mid-flight is not lost" do
      assert Marker.classify("Merged.\n[worktree-status: done]") == "done"

      assert Marker.classify("Three options.\n[worktree-status: needs-decision] pick one") ==
               "needs-decision"
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

    test "an invisible line of the wrong length names nothing, so it is unmarked" do
      assert Marker.classify("ok\n⁣") == "unmarked"
      assert Marker.classify("ok\n⁣⁣⁣⁣") == "unmarked"
    end

    test "surrounding whitespace on the marker line does not hide it" do
      assert Marker.classify("ok\n  #{@done}  ") == "done"
    end

    test "the last marker line wins" do
      assert Marker.classify("[worktree-status: needs-decision] earlier\n...\n#{@done}") == "done"
    end

    test "a marker quoted mid-prose loses to the real one at the end" do
      text = """
      The old spelling was `[worktree-status: done]`, which printed in the pane.
      pick one
      #{@needs}\
      """

      assert Marker.classify(text) == "needs-decision"
    end

    test "an unclosed bracket is prose about the marker, not a marker" do
      assert Marker.classify("The old spelling was [worktree-status: done, which printed") ==
               "unmarked"
    end

    test "the bracket form may sit mid-line, since the hook reads the whole message" do
      assert Marker.classify("Result: [worktree-status: done] all set") == "done"
    end

    test "the bracket form may carry the old invisible prefix" do
      for invisible <- ["​", "⁠", "﻿"] do
        assert Marker.classify("ok\n#{invisible}[worktree-status: done]") == "done",
               "prefix #{inspect(invisible)} was not recognised"
      end
    end
  end

  describe "pointer/1" do
    test "for a quiet needs-decision it is the readable line before the marker" do
      text = "body\n3 questions ready, see above\n#{@needs}"
      assert Marker.pointer(text) == "3 questions ready, see above"
    end

    test "blank lines between the pointer and the marker are skipped" do
      assert Marker.pointer("body\npick one\n\n\n#{@needs}") == "pick one"
    end

    test "a finished turn points at nothing — its report speaks for itself" do
      assert Marker.pointer("Merged and green.\n#{@done}") == ""
    end

    test "for the bracket form it is what the mouse wrote after the marker" do
      assert Marker.pointer(
               "body\n[worktree-status: needs-decision] 3 questions ready, see above"
             ) ==
               "3 questions ready, see above"
    end

    test "is empty when a bracket marker stands alone" do
      assert Marker.pointer("done\n[worktree-status: done]") == ""
      assert Marker.pointer("[worktree-status: done]\n") == ""
    end

    test "for an unmarked message it is the first non-empty line" do
      assert Marker.pointer("\n\nI stopped here.\nmore") == "I stopped here."
      assert Marker.pointer("") == ""
    end

    test "the last marker line wins here too" do
      text = "[worktree-status: done] old\nnew\n#{@needs}"
      assert Marker.pointer(text) == "new"
    end
  end

  describe "render/1 and spell/1 — the marker Whiska tells a mouse to write" do
    test "renders exactly what classify/1 reads back" do
      for {status, kind} <- [{:done, "done"}, {:needs_decision, "needs-decision"}] do
        assert Marker.classify(Marker.render(status)) == kind
      end
    end

    test "is the invisible spelling, so nothing shows in the mouse's pane" do
      assert Marker.render(:done) == @done
      assert Marker.render(:needs_decision) == @needs
    end

    test "spell/1 names the codepoint, since the characters cannot be read" do
      assert Marker.spell(:done) =~ "three"
      assert Marker.spell(:needs_decision) =~ "two"

      for status <- [:done, :needs_decision] do
        assert Marker.spell(status) =~ "U+2063"
      end
    end
  end

  describe "strip/1 — the message as a person reads it" do
    test "the quiet marker line goes, leaving no blank line behind" do
      assert Marker.strip("Merged.\n#{@done}") == "Merged."
      assert Marker.strip("Three options.\npick one\n#{@needs}") == "Three options.\npick one"
    end

    test "a marker quoted mid-prose survives — only the last marker line is touched" do
      text = """
      The old spelling was `[worktree-status: done]`, which printed in the pane.
      Writing `[worktree-status: needs-decision] pick one` is the older form.
      #{@done}\
      """

      assert Marker.strip(text) == """
             The old spelling was `[worktree-status: done]`, which printed in the pane.
             Writing `[worktree-status: needs-decision] pick one` is the older form.\
             """
    end

    test "drops a bracket marker token, keeps the pointer sentence" do
      assert Marker.strip("Three options.\n[worktree-status: needs-decision] pick one") ==
               "Three options.\npick one"
    end

    test "a bare bracket marker leaves no empty line behind" do
      assert Marker.strip("Merged.\n[worktree-status: done]") == "Merged."
    end

    test "an invisible prefix goes with the bracket marker" do
      assert Marker.strip("Done.\n⁣[worktree-status: done]") == "Done."
    end

    test "an unmarked message is returned as it is" do
      assert Marker.strip("Still working.") == "Still working."
    end
  end
end
