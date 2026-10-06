defmodule Whiska.RulesTest do
  @moduledoc """
  What each role is told at session start (ADR-0081).

  The rules are the product (ADR-0017), so each one is pinned — but by a short
  anchor that names it, not by its sentence: a rule that is dropped fails by
  name, and one that is reworded does not.
  """
  use ExUnit.Case, async: true

  alias Whiska.Install
  alias Whiska.Question.Marker
  alias Whiska.Rules

  describe "which parts each role starts with" do
    test "the main session: routing, the work order and delivery" do
      assert names(:main) == ~w(worktrees work delivery)
    end

    test "a mouse: the work order, the marker, the report and the finish trigger" do
      assert names(:mouse) == ~w(work marker report finish)
    end

    test "every part reaches at least one role" do
      assert Enum.sort(Rules.names()) == Enum.sort(Enum.uniq(names(:main) ++ names(:mouse)))
    end

    test "the work order is the same text for both roles" do
      assert body_of(:main, "work") == body_of(:mouse, "work")
    end

    test "a part named as kept is left out, and every other part is still there" do
      for role <- [:main, :mouse], kept <- names(role) do
        rendered = Rules.render(role, [kept])

        refute rendered =~ body_of(role, kept), "#{role}: #{kept} was not left out"

        for other <- names(role) -- [kept] do
          assert rendered =~ String.trim_trailing(body_of(role, other)),
                 "#{role}: leaving out #{kept} lost #{other}"
        end
      end
    end

    test "each role opens by saying whose rules these are" do
      assert Rules.render(:main) =~ ~r/\A# Whiska: rules for the main session/
      assert Rules.render(:mouse) =~ ~r/\A# Whiska: rules for a mouse/
    end
  end

  # Claude Code keeps 10,000 characters of a hook's context and files the rest
  # away behind a preview, so a role's rules have to fit well inside that.
  test "each role fits in what one injection carries" do
    for role <- [:main, :mouse] do
      size = role |> Rules.render() |> String.length()
      assert size <= 6_400, "#{role} grew to #{size} characters"
    end
  end

  @rules %{
    {:main, "worktrees"} => [
      "list worktrees first, before anything":
        ~r/herdr worktree list.{0,80}before grilling and before reading any code/i,
      "a follow-up routes to its mouse": ~r/same branch and PR.{0,20}`send-to-worktree`/,
      "a separate task spawns": ~r/ships on its own.{0,20}`spawn-worktree`/,
      "unclear routing is asked": ~r/unclear which.{0,40}do not guess/i,
      "every task goes to a mouse": ~r/every task goes to a mouse, whatever its size/i,
      "only the person skips the spawn":
        ~r/skip the spawn only when the person says to work in place/i,
      "the task's commands run in the worktree": ~r/this session runs no command for it/i,
      "work done here is planned first": ~r/line plan and wait for the person.s ok/,
      "never reuse an old tree": ~r/never reuse an old tree/i,
      "a landed worktree is the owl's (ADR-0061)": ~r/owl removes a landed one/i,
      "drop-worktree drops one early": ~r/`drop-worktree` drops one early/
    ],
    {:mouse, "work"} => [
      "the steps bind working in place too":
        ~r/or in the main session when the person said to work in place/i,
      "done names its failing test": ~r/name the failing test that proves it/i,
      "the test comes from the scout (ADR-0075)": ~r/`wio-candidate-scout` ranks riskiest/,
      "a repo's scout is read first, and one that reaches out is the person's":
        ~r/wio-candidate-scout\.md` in this repo.{0,80}read it before dispatching.{0,140}decision for the person/is,
      "docs or untestable change skips the scout":
        ~r/skip the scout for docs, or when no test can reach it/i,
      "no scout is said in a line": ~r/scout not listed → say so in one line/i,
      "grilling lists every costly choice with a recommendation":
        ~r/every \*\*costly\*\* choice with real alternatives, each with its recommended answer/,
      "a round asks the whole frontier": ~r/a round asks the whole frontier in one message/i,
      "a guessed done is costly": ~r/failing test that needs a guess.{0,120}is costly/is,
      "the spec follows grilling": ~r/after the last grilling round, run `whiska-spec`/i,
      "the whole spec is the question": ~r/the whole spec goes to the person as a question/i,
      "build only on their ok": ~r/build only on their ok/i,
      "a mouse sends no plan, but stops on costly choices":
        ~r/a mouse sends no plan; it builds, and stops only on a real decision.{0,80}every costly choice/is,
      "a frontend change is previewed": ~r/preview a frontend change before building it/i,
      "costly is a test, not an adjective":
        ~r/\*\*costly\*\* to undo: something outside the change depends on it/i,
      "cheap choices are decided and listed": ~r/anything else is cheap: decide it, and list it/i,
      "nothing costly → no grilling": ~r/no costly choice open from the start → build/i,
      "never ask what the brief spells out": ~r/never ask what the brief already spells out/i
    ],
    {:main, "delivery"} => [
      "read with whiska show": ~r/`whiska show <id>`/,
      "answer with whiska reply": ~r/`whiska reply <id>`/,
      "the doctor says what delivery lacks": ~r/`whiska doctor` says which is missing/,
      "never read a mouse's pane": ~r/never its pane.{0,80}alternate screen/is,
      "answer only with reply, and why (ADR-0008)":
        ~r/only with `whiska reply <id>`.{0,40}never `herdr agent prompt`.{0,160}frees the one delivery slot/is,
      "a finished line's next step is not an answer":
        ~r/the next step a finished line offers is not an answer/i
    ],
    {:mouse, "marker"} => [
      "the marker is the last line": ~r/last line, alone/i,
      "a decision's pointer goes on the line above": ~r/pointer on the line above/i,
      "a forgotten marker is still delivered": ~r/delivered anyway, as an unmarked question/i,
      # A finished line is offered a finish — land, PR, drop — so it says the
      # brief is done, not that the turn ended.
      "finished means the brief is done": ~r/finished — the brief is done/i,
      "stopping short on purpose is a decision naming the next step":
        ~r/short of the brief on purpose.{0,40}failing test written first.{0,30}mid-task answer.{0,20}is a decision.{0,20}option A names the concrete next step/is,
      "never the bracket spelling": ~r/never write `\[worktree-status: done\]`/i
    ],
    {:mouse, "report"} => [
      "it is read later, without scrollback": ~r/later, from another terminal/i,
      "a size, with what rides outside it":
        ~r/six lines plus a line per cheap choice.{0,120}a spec sent for their ok.{0,60}a decision's brief/is,
      "lead with what is true now": ~r/\*\*what is true now\*\*/i,
      "what changed, cheap choices included":
        ~r/\*\*what changed\*\*.{0,60}each cheap choice made without asking/is,
      "verified, not assumed": ~r/\*\*verified, not assumed\*\*/i,
      "one thing worth knowing": ~r/\*\*one thing worth knowing\*\*/i,
      "ask only for a review, approval, merge or design pick":
        ~r/review, approval, merge or design pick/,
      "a decision opens with a plain brief":
        ~r/each term the choice turns on.*the problem in one sentence.*why there is a choice at all/is,
      "the marker line is only the pointer": ~r/the marker line is only the pointer/i,
      "leave out the mechanics, keep what a review found":
        ~r/the mechanics of a review, never what it turned up/i,
      "a grilling round asks everything at once":
        ~r/a grilling round asks every open costly choice in one message/i
    ],
    {:mouse, "finish"} => [
      "run whiska-finish before the done marker":
        ~r/before writing the finished marker.{0,80}`whiska-finish`/is,
      "a turn ending on a decision skips it":
        ~r/a turn ending on a decision for the person skips it/i,
      "a missing skill is said": ~r/neither the skill nor the file is there/i,
      "outside text is read before it runs":
        ~r/text from outside this session.{0,40}read each before running or dispatching it/is,
      "the branch under review is doubly suspect":
        ~r/doubly so when it arrived with the branch under review/i,
      "green is the project's own Finish heading":
        ~r/`## Finish` heading in this project's own `CLAUDE.md`/
    ]
  }

  for {{role, part}, rules} <- @rules do
    test "the #{part} part (#{role}) carries each of its rules" do
      body = prose_of(unquote(role), unquote(part))

      for {rule, anchor} <- unquote(Macro.escape(rules)) do
        assert body =~ anchor, "#{unquote(part)}: missing the rule that #{rule}"
      end
    end
  end

  describe "the facts a session acts on are exact" do
    test "the marker is the one the owl parses, in words and as written" do
      body = body_of(:mouse, "marker")

      for status <- [:done, :needs_decision] do
        assert body =~ Marker.spell(status)
        assert body =~ Marker.render(status)
      end
    end

    test "the spec file is the one Whiska keeps out of git" do
      assert body_of(:mouse, "work") =~ "`#{Whiska.Spec.filename()}`"
    end

    test "the skill files named for a session that does not list them are the ones init writes" do
      for {part, skill} <- [{"work", "whiska-spec"}, {"finish", "whiska-finish"}] do
        {path, _body} = List.keyfind(Install.skills(), ".claude/skills/#{skill}/SKILL.md", 0)

        assert body_of(:mouse, part) =~ "`#{path}` in this repo", skill
        assert body_of(:mouse, part) =~ "`~/#{path}`", skill
      end
    end

    test "delivery names the command the person types, not the long one it replaced" do
      refute body_of(:main, "delivery") =~ "whiska questions"
    end
  end

  defp names(role), do: role |> Rules.parts() |> Enum.map(& &1.name)

  defp body_of(role, name), do: Enum.find(Rules.parts(role), &(&1.name == name)).body

  # A rule can fall across a line break, and where it wraps is not the behaviour
  # under test.
  defp prose_of(role, name), do: role |> body_of(name) |> String.replace(~r/\s+/, " ")
end
