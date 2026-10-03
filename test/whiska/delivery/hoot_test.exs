defmodule Whiska.Delivery.HootTest do
  @moduledoc """
  The desktop notification raised at the moment a question is delivered. It
  says the same thing the delivered line says, in the same words, plus the one
  thing the line cannot carry: which house it came from.
  """
  use ExUnit.Case, async: true

  alias Whiska.Delivery.Hoot
  alias Whiska.Delivery.Text
  alias Whiska.Schema.Question

  defp question(attrs) do
    struct(
      %Question{id: 12, mouse_id: "m1", kind: "needs-decision", status: "open", text: ""},
      attrs
    )
  end

  test "names the house, the branch and what the mouse did" do
    q = question(text: "Which db?\n[worktree-status: needs-decision] pick one")

    assert %{title: title, body: body} = Hoot.compose(q, "whiska", "feat-a", 0)

    assert title == "🐱 whiska · feat-a needs a decision"
    assert body == ~s(#12 · "pick one")
  end

  test "a finished branch gets the same hoot with the quieter sound" do
    q = question(kind: "done", text: "Merged and pushed.\n[worktree-status: done]")

    assert Hoot.compose(q, "whiska", "feat-a", 0) == %{
             title: "🐱 whiska · feat-a finished",
             body: "#12",
             sound: :done
           }
  end

  test "a question that needs a decision gets the sound that asks for attention" do
    for kind <- ["needs-decision", "unmarked"] do
      assert %{sound: :request} = Hoot.compose(question(kind: kind), "whiska", "feat-a", 0)
    end
  end

  test "the verb is the delivered line's verb, never a second phrasing for it" do
    for kind <- ["needs-decision", "done", "unmarked"] do
      q = question(kind: kind, text: "[worktree-status: needs-decision] pick one")
      %{title: title} = Hoot.compose(q, "whiska", "feat-a", 0)
      line = Text.compose(q, "feat-a", 0, [])

      assert String.ends_with?(title, Text.verb(kind))
      assert line =~ Text.verb(kind)
    end
  end

  test "says how many more are waiting behind it, in the line's own words" do
    q = question(text: "[worktree-status: needs-decision] pick one")

    assert %{body: body} = Hoot.compose(q, "whiska", "feat-a", 2)
    assert body == ~s(#12 · "pick one" · 2 more open)
  end

  test "a branch is cut and flattened: the title is one line, whatever a mouse wrote" do
    q = question(text: "[worktree-status: needs-decision] pick one")

    %{title: wrapped} = Hoot.compose(q, "whiska", "feat/a\nSECOND LINE", 0)
    refute wrapped =~ "\n"
    assert wrapped == "🐱 whiska · feat/a SECOND LINE needs a decision"

    %{title: long} = Hoot.compose(q, "whiska", String.duplicate("b", 400), 0)
    assert String.length(long) < 120
    assert long =~ "…"
    assert String.ends_with?(long, "needs a decision")
  end

  test "the house name is flattened and cut the same way" do
    q = question(text: "[worktree-status: needs-decision] pick one")

    %{title: title} = Hoot.compose(q, String.duplicate("h", 400), "feat-a", 0)

    assert String.length(title) < 120
    refute title =~ "\n"
  end

  test "a long pointer is cut, so the hoot stays one glance" do
    q = question(text: "[worktree-status: needs-decision] " <> String.duplicate("x", 300))

    assert %{body: body} = Hoot.compose(q, "whiska", "feat-a", 0)
    assert String.length(body) < 200
    assert body =~ "…"
  end
end
