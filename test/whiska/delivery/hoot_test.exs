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

  @none %{open: 0}

  defp question(attrs) do
    struct(
      %Question{id: 12, mouse_id: "m1", kind: "needs-decision", status: "open", text: ""},
      attrs
    )
  end

  test "names the house, the branch and what the mouse did" do
    q = question(text: "Which db?\n[worktree-status: needs-decision] pick one")

    assert %{title: title, body: body} = Hoot.compose(q, "whiska", "feat-a", @none)

    assert title == "🐱 whiska · feat-a needs a decision"
    assert body == ~s(#12 · "pick one")
  end

  test "the owl's own question is Whiska's in the hoot too" do
    q = question(asked_by: "owl", kind: "needs-decision")
    assert %{title: title} = Hoot.compose(q, "whiska", "feat-a", @none)

    assert title == "🦉 whiska · Whiska asks about feat-a"
  end

  test "a finished branch gets the same hoot with the quieter sound, saying what it came to" do
    q = question(kind: "done", text: "## Summary\nImporter \e[1mmerged.\n\u2063\u2063\u2063")

    assert Hoot.compose(q, "whiska", "feat-a", @none) == %{
             title: "🐱 whiska · feat-a finished",
             body: ~s(#12 · "Importer [1mmerged."),
             sound: :done
           }
  end

  test "a question that needs a decision gets the sound that asks for attention" do
    for kind <- ["needs-decision", "unmarked"] do
      assert %{sound: :request} = Hoot.compose(question(kind: kind), "whiska", "feat-a", @none)
    end
  end

  test "the verb is the delivered line's verb, never a second phrasing for it" do
    for kind <- ["needs-decision", "done", "unmarked"] do
      q = question(kind: kind, text: "[worktree-status: needs-decision] pick one")
      %{title: title} = Hoot.compose(q, "whiska", "feat-a", @none)
      line = Text.compose(q, "feat-a", @none, [])

      assert String.ends_with?(title, Text.verb(kind))
      assert line =~ Text.verb(kind)
    end
  end

  test "says how many more are waiting behind it, in the line's own words" do
    q = question(text: "[worktree-status: needs-decision] pick one")

    assert %{body: body} = Hoot.compose(q, "whiska", "feat-a", %{open: 2})
    assert body == ~s(#12 · "pick one" · 2 more open)
  end

  test "a branch is cut and flattened: the title is one line, whatever a mouse wrote" do
    q = question(text: "[worktree-status: needs-decision] pick one")

    %{title: wrapped} = Hoot.compose(q, "whiska", "feat/a\nSECOND LINE", @none)
    refute wrapped =~ "\n"
    assert wrapped == "🐱 whiska · feat/a SECOND LINE needs a decision"

    %{title: long} = Hoot.compose(q, "whiska", String.duplicate("b", 400), @none)
    assert String.length(long) < 120
    assert long =~ "…"
    assert String.ends_with?(long, "needs a decision")
  end

  test "the house name is flattened and cut the same way" do
    q = question(text: "[worktree-status: needs-decision] pick one")

    %{title: title} = Hoot.compose(q, String.duplicate("h", 400), "feat-a", @none)

    assert String.length(title) < 120
    refute title =~ "\n"
  end

  describe "reminder/3 (ADR-0062)" do
    defp report(branch, asked_at) do
      question(
        mouse_id: branch,
        kind: "done",
        status: "closed",
        asked_at: asked_at,
        mouse: %Whiska.Schema.Mouse{mouse_id: branch, branch: branch}
      )
    end

    test "names every finished branch in one hoot, each with how long ago it finished" do
      now = ~U[2026-10-14 12:00:00Z]

      reports = [
        report("feat/a", ~U[2026-10-14 07:00:00Z]),
        report("fix/b", ~U[2026-10-14 11:20:00Z]),
        report("feat/c", ~U[2026-10-11 12:00:00Z])
      ]

      assert Hoot.reminder(reports, "whiska", now) == %{
               title: "🐱 whiska · 3 finished, not landed",
               body: "no merge request: feat/a (5h), fix/b (40m), feat/c (3d)",
               sound: :done
             }
    end

    test "a branch is one plain line: no control or invisible characters" do
      reports = [
        report("feat/\e[31ma\u202E", ~U[2026-10-14 11:00:00Z]),
        report("fix/\u200Bb", ~U[2026-10-14 11:00:00Z])
      ]

      assert %{body: "no merge request: feat/[31ma (1h), fix/b (1h)"} =
               Hoot.reminder(reports, "whiska", ~U[2026-10-14 12:00:00Z])
    end

    test "names eight branches at most, and counts the rest" do
      reports = for i <- 1..10, do: report("b#{i}", ~U[2026-10-14 11:00:00Z])

      assert %{title: "🐱 whiska · 10 finished, not landed", body: body} =
               Hoot.reminder(reports, "whiska", ~U[2026-10-14 12:00:00Z])

      assert String.ends_with?(body, "b8 (1h), and 2 more")
    end

    test "a branch is flattened and cut as in any other hoot" do
      reports = [
        report("feat/a\nSECOND " <> String.duplicate("b", 400), ~U[2026-10-14 11:00:00Z])
      ]

      %{body: body} = Hoot.reminder(reports, "whiska", ~U[2026-10-14 12:00:00Z])

      refute body =~ "\n"
      assert body =~ "…"
      assert String.ends_with?(body, "(1h)")
    end
  end

  test "a long pointer is cut, so the hoot stays one glance" do
    q = question(text: "[worktree-status: needs-decision] " <> String.duplicate("x", 300))

    assert %{body: body} = Hoot.compose(q, "whiska", "feat-a", @none)
    assert String.length(body) < 200
    assert body =~ "…"
  end
end
