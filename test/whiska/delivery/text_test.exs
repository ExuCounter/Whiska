defmodule Whiska.Delivery.TextTest do
  @moduledoc """
  The one line typed into the main session. A pointer, not the message: the
  full text is one command away (`whiska questions <id>`), and the line must
  never contain a newline, since the prompt box would submit early.
  """
  use ExUnit.Case, async: true

  alias Whiska.Delivery.Text
  alias Whiska.Schema.Question

  defp question(attrs) do
    struct(
      %Question{id: 12, mouse_id: "m1", kind: "needs-decision", status: "open", text: ""},
      attrs
    )
  end

  test "a done report says the mouse finished, and offers no reply (ADR-0009)" do
    q = question(kind: "done", text: "Merged and pushed.\n[worktree-status: done]")
    assert Text.compose(q, "feat-a", 0, []) == "🐱 feat-a finished · #12"
  end

  test "names the branch, that it needs a decision, the id, and the mouse's pointer" do
    q =
      question(text: "Which db?\n[worktree-status: needs-decision] 3 questions ready, see above")

    line = Text.compose(q, "feat-delivery", 0, [])

    assert line == ~s(🐱 feat-delivery needs a decision · #12 · "3 questions ready, see above")
    refute line =~ "\n"
  end

  test "carries no command and never names whiska: the id is the whole pointer (ADR-0005)" do
    q = question(text: "[worktree-status: needs-decision] pick one")

    for line <- [
          Text.compose(q, "b", 3, [:status_unknown]),
          Text.compose(question(kind: "done"), "b", 0, [])
        ] do
      refute line =~ "whiska"
      refute line =~ "read:"
      refute line =~ "answer:"
      assert String.starts_with?(line, "🐱 ")
      assert line =~ " · #12"
    end
  end

  test "the order is branch and verb, then id, then pointer, then more open, then notes" do
    q = question(text: "[worktree-status: needs-decision] pick one")
    line = Text.compose(q, "b", 2, [:status_unknown])

    assert line ==
             ~s(🐱 b needs a decision · #12 · "pick one" · 2 more open · ) <>
               "delivered blind: herdr cannot tell whether you are idle, so this may interrupt"
  end

  test "says how many more are open, and nothing when there are none" do
    q = question(text: "[worktree-status: needs-decision] pick one")
    assert Text.compose(q, "b", 2, []) =~ "2 more open"
    assert Text.compose(q, "b", 1, []) =~ "1 more open"
    refute Text.compose(q, "b", 0, []) =~ "more open"
  end

  test "an unmarked question says the mouse stopped without saying why (ADR-0009)" do
    q = question(kind: "unmarked", text: "I ran out of things to do.")
    line = Text.compose(q, "b", 0, [])
    assert line =~ "stopped without saying why"
    assert line =~ ~s("I ran out of things to do.")
  end

  test "a pointer that runs long is cut, and never carries a newline" do
    long = String.duplicate("word ", 60)
    q = question(kind: "unmarked", text: "\n" <> long <> "\nline two")
    line = Text.compose(q, "b", 0, [])
    refute line =~ "\n"
    assert String.length(line) < 400
    assert line =~ "…"
  end

  test "the unknown-status note is appended when delivery went ahead blind (ADR-0008)" do
    q = question(text: "[worktree-status: needs-decision] x")
    line = Text.compose(q, "b", 0, [:status_unknown])
    assert line =~ "herdr cannot tell whether you are idle"
  end

  test "a nudge names the waiting repos by folder and nothing else (ADR-0041)" do
    assert Text.nudge(["/Users/me/projects/whiska"]) == "⚡ whiska waiting"
    assert Text.nudge(["/Users/me/projects/whiska", "/srv/crew"]) == "⚡ crew, whiska waiting"
  end
end
