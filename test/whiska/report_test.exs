defmodule Whiska.ReportTest do
  use ExUnit.Case, async: true

  alias Whiska.Report

  @document """
  # Why the sidebar hangs

  ## Summary
  herdr's socket blocks when its queue is full.
  The owl waits on it with no timeout.

  ## What to change
  - Found: the owl's herdr call has no timeout.
  - Build: give it one, and retry once.
  - Why: the sidebar stops freezing.

  ## Question
  Why does the sidebar hang?

  ## Found
  The call at house.ex:120 waits forever.
  """

  test "a document's summary is its Summary section and the first line of What to change" do
    assert Report.summary(@document) == """
           ## Summary
           herdr's socket blocks when its queue is full.
           The owl waits on it with no timeout.

           ## What to change
           - Found: the owl's herdr call has no timeout.\
           """
  end

  test "a document with nothing to change is summed up by its Summary alone" do
    text = "# Checked the cache\n\n## Summary\nNothing is wrong.\n\n## Found\nAll keys hit.\n"

    assert Report.summary(text) == "## Summary\nNothing is wrong."
  end

  test "a message with no Summary heading of its own is not a document" do
    refute Report.document?("Which one?\n\n1. Keep it. Recommended.")
    refute Report.document?("The report goes under ## Summary next time.")
    assert Report.summary("Which one?") == nil
    assert Report.document?(@document)
  end

  test "a heading inside a code block belongs to the block, not the message" do
    quoted = "The brief now asks for:\n\n```\n# Title\n\n## Summary\n3-5 lines.\n```\n"

    refute Report.document?(quoted)
    assert Report.summary(quoted) == nil

    assert Report.summary("## Summary\nShort.\n\n```\n## Found\n```\n\n## Found\nx") ==
             "## Summary\nShort.\n\n```\n## Found\n```"
  end

  test "an empty Summary makes no document" do
    refute Report.document?("# Title\n\n## Summary\n\n## Found\nx")
    assert Report.summary("# Title\n\n## Summary\n\n## Found\nx") == nil
  end

  test "a code block that never closes runs to the end" do
    assert Report.summary("## Summary\nA\n```\n## Found\nx") == "## Summary\nA\n```\n## Found\nx"
  end

  test "a document is kept without its marker line" do
    assert Report.text(@document <> "\n⁣⁣⁣") == @document
  end

  describe "outcome/1" do
    @ledger "Agent usage this session\nmouse (whole session) · claude-opus-5-5\n⁣⁣⁣"

    test "is the first line of the summary, not the ledger" do
      assert Report.outcome("# T\n\n## Summary\nMerged; 31 pass.\nMore.\n\n" <> @ledger) ==
               "Merged; 31 pass."
    end

    test "a summary line starting with # is still the outcome" do
      assert Report.outcome("## Summary\n#471 merged.\n\n" <> @ledger) == "#471 merged."
    end

    test "a heading inside a code block is not the summary" do
      text = "```\n## Summary\nfoo\n```\n## Summary\nReal outcome\n" <> @ledger
      assert Report.outcome(text) == "Real outcome"
    end

    test "prose mentioning the ledger heading does not cut the summary" do
      text = "## Summary\nCut the Agent usage this session block.\n\n" <> @ledger
      assert Report.outcome(text) == "Cut the Agent usage this session block."
    end

    test "an empty summary falls back to the last line before the ledger" do
      assert Report.outcome("## Summary\n\n## Done\nAll green.\n\n---\n" <> @ledger) ==
               "All green."
    end

    test "no summary: the last line before the ledger" do
      assert Report.outcome("Merged.\n\nAll 31 tests pass.\n\n" <> @ledger) ==
               "All 31 tests pass."
    end
  end
end
