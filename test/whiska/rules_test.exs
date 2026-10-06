defmodule Whiska.RulesTest do
  @moduledoc """
  What each role is told at session start (ADR-next-rules-arrive-by-role).
  Pinned by behaviour: a rule is present, and a fact a session acts on is
  exact. Wording is free to move.
  """
  use ExUnit.Case, async: true

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

    test "a part named as kept is left out, and nothing else is" do
      full = Rules.render(:mouse)
      without = Rules.render(:mouse, ["report"])

      refute without =~ body_of(:mouse, "report")
      assert without =~ body_of(:mouse, "marker")
      assert full =~ body_of(:mouse, "report")
    end

    test "each role opens by saying whose rules these are" do
      assert Rules.render(:main) =~ ~r/\A# Whiska: rules for the main session/
      assert Rules.render(:mouse) =~ ~r/\A# Whiska: rules for a mouse/
    end
  end

  describe "the rules stay short" do
    # Claude Code keeps 10,000 characters of a hook's context and files the rest
    # away behind a preview, so a role's rules have to fit well inside that.
    test "each role fits in what one injection carries" do
      for role <- [:main, :mouse] do
        size = role |> Rules.render() |> String.length()
        assert size <= 6_400, "#{role} grew to #{size} characters"
      end
    end

    test "no rule is buried deeper than one level of bullet" do
      for role <- [:main, :mouse],
          part <- Rules.parts(role),
          line <- String.split(part.body, "\n"),
          String.match?(line, ~r/^\s*[-*] /) do
        assert String.match?(line, ~r/^ {0,2}[-*] /), line
      end
    end
  end

  describe "the worktrees part (main session)" do
    test "names the commands the protocol runs on" do
      body = body_of(:main, "worktrees")

      assert body =~ "herdr worktree list"
      assert body =~ "send-to-worktree"
      assert body =~ "spawn-worktree"
      assert body =~ "drop-worktree"
    end

    test "a landed worktree is the owl's to take down, not the session's (ADR-0061)" do
      body = prose_of(:main, "worktrees")

      assert body =~ ~r/after the merge.{0,120}owl/is
      assert body =~ ~r/drop-worktree.{0,60}early/is
    end

    test "checks for an existing worktree before grilling or reading code" do
      body = prose_of(:main, "worktrees")

      assert body =~ ~r/herdr worktree list.{0,80}before/i
      assert body =~ ~r/before reading any code/i
      assert body =~ ~r/before grilling here/i
    end

    test "unclear routing is asked, never guessed" do
      assert prose_of(:main, "worktrees") =~ ~r/ask the person.{0,30}do not guess/i
    end

    test "every command for the task, the grilling included, happens in the worktree" do
      body = prose_of(:main, "worktrees")

      assert body =~ ~r/routes the raw idea there now, and that mouse does any grilling/i
      assert body =~ ~r/this session runs no command for it/i
    end

    test "every task goes to a mouse, whatever its size" do
      body = prose_of(:main, "worktrees")

      assert body =~ ~r/every task goes to a mouse, whatever its size/i
      refute body =~ ~r/several files|few minutes/i
    end

    test "only the person saying to work in place skips the spawn" do
      assert prose_of(:main, "worktrees") =~
               ~r/skip the spawn only when the person says to work in place/i
    end

    test "the main session plans before any work of its own" do
      assert prose_of(:main, "worktrees") =~ ~r/2.{0,3}4 line plan and wait for the person.s ok/i
    end

    test "an old tree is never reused" do
      assert prose_of(:main, "worktrees") =~ ~r/never reuse an old tree/i
    end
  end

  describe "the work part (both roles)" do
    test "is the same text for both" do
      assert body_of(:main, "work") == body_of(:mouse, "work")
    end

    test "binds a session working in place as well as a mouse" do
      assert prose_of(:mouse, "work") =~
               ~r/in a mouse, or in the main session when the person said to work in place/i
    end

    test "works through done, grill, spec and build, in that order" do
      body = body_of(:mouse, "work")

      at =
        for step <- ["**Done.**", "**Grill.**", "**Spec.**", "**Build.**"] do
          assert {at, _} = :binary.match(body, step), "#{step} is missing"
          at
        end

      assert at == Enum.sort(at)
    end

    test "a brief that names done and its failing test is not asked about them" do
      body = prose_of(:mouse, "work")

      assert body =~ ~r/what .done. looks like and name the failing test that proves it/i
      assert body =~ ~r/never ask what the brief already spells out/i
    end

    test "the failing test is picked from what the test scout ranks riskiest (ADR-0075)" do
      body = prose_of(:mouse, "work")

      assert body =~
               ~r/while none is named, pick it from what `wio-candidate-scout` ranks riskiest in the files the change will touch/i

      assert body =~ ~r/skip the scout for docs, or when no test can reach it/i
      assert body =~ ~r/scout not listed → say so in one line and name the test yourself/i
    end

    test "a scout this repo ships is read before it is dispatched, and one that reaches out is the person's call" do
      body = prose_of(:mouse, "work")

      assert body =~
               ~r/`\.claude\/agents\/wio-candidate-scout\.md` in this repo is the copy that runs: read it before dispatching it/i

      assert body =~
               ~r/writes outside the repo or touches credentials is a decision for the person/i
    end

    test "a mouse reads the code, then asks every costly choice with its recommendation" do
      body = prose_of(:mouse, "work")

      assert body =~ ~r/\*\*grill\.\*\* read the code first, then send one message/i
      assert body =~ ~r/every \*\*costly\*\* choice with real alternatives/i
      assert body =~ ~r/each with its recommended answer, and wait for the person.s ok/i
      assert body =~ ~r/a round asks the whole frontier in one message/i
      refute body =~ ~r/one round/i
    end

    test "a done or failing test that needs a guess is one of the costly choices" do
      assert prose_of(:mouse, "work") =~
               ~r/a .done. or failing test that needs a guess.{0,120}is costly\./i
    end

    test "costly to undo is a test a mouse can apply, not an adjective" do
      body = prose_of(:mouse, "work")

      assert body =~ ~r/\*\*costly\*\* to undo: something outside the change depends on it/i

      for thing <- [
            "a file format",
            "a command-line flag or interface",
            "stored data",
            "a dependency added or dropped",
            "behaviour the person would notice",
            "it touches secrets, access or a security check",
            "the rest of the change is built on it"
          ] do
        assert body =~ thing
      end
    end

    test "a cheap choice is decided and listed; with nothing costly open, a mouse just builds" do
      body = prose_of(:mouse, "work")

      assert body =~ ~r/anything else is cheap: decide it, and list it in the final report/i

      assert body =~
               ~r/no costly choice open from the start → build with no grilling message and no spec/i

      assert body =~
               ~r/a truly trivial task — a typo, a rename, a one-line fix, nothing costly — never needs one/i
    end

    test "after grilling, the spec is written and approved before any code" do
      body = prose_of(:mouse, "work")

      assert body =~ ~r/after the last grilling round, run `whiska-spec`: it/i
      assert body =~ "`#{Whiska.Spec.filename()}`"
      assert body =~ ~r/the whole spec goes to the person as a question/i
      assert body =~ ~r/build only on their ok/i
    end

    test "a spec skill the session does not list is read from either install's file" do
      body = prose_of(:mouse, "work")

      assert body =~ "`.claude/skills/whiska-spec/SKILL.md` in this repo"
      assert body =~ "`~/.claude/skills/whiska-spec/SKILL.md`"
    end

    test "a mouse sends no plan, but every costly choice stops it, before or during the build" do
      assert prose_of(:mouse, "work") =~
               ~r/a mouse sends no plan; it builds, and stops only on a real decision — every costly choice is one, found before the build or during it, and so is its spec/i
    end

    test "a frontend change is previewed before it is built" do
      assert prose_of(:mouse, "work") =~ ~r/preview a frontend change before building it/i
    end
  end

  describe "the delivery part (main session)" do
    test "names the commands the person actually types" do
      body = body_of(:main, "delivery")

      assert body =~ "whiska show <id>"
      assert body =~ "whiska reply <id>"
      assert body =~ "whiska doctor"
      refute body =~ "whiska questions"
    end

    test "forbids reading a mouse's pane, and says why" do
      body = prose_of(:main, "delivery")

      assert body =~ "herdr pane read"
      assert body =~ "alternate screen"
    end

    test "the answer goes through whiska reply and nothing else, with the reason (ADR-0008)" do
      body = prose_of(:main, "delivery")

      assert body =~ "herdr agent prompt"
      assert body =~ "send-to-worktree"
      assert body =~ ~r/frees the one delivery slot/i
    end

    test "uses the repo's own words for what is going on" do
      for word <- ~w(mouse doorstep owl), do: assert(body_of(:main, "delivery") =~ word, word)
    end
  end

  describe "the marker part (mouse)" do
    test "names both values in words and agrees with the marker Whiska parses" do
      body = body_of(:mouse, "marker")

      for status <- [:done, :needs_decision] do
        assert body =~ Marker.spell(status)
        assert body =~ Marker.render(status)
      end

      assert body =~ "last line"
    end

    test "still names the bracket spelling, which Whiska keeps reading, as never to write" do
      body = prose_of(:mouse, "marker")

      assert body =~ "[worktree-status: done]"
      assert body =~ "[worktree-status: needs-decision]"
      assert body =~ ~r/never write/i
    end

    test "says where the pointer goes, and that a forgotten marker is delivered anyway" do
      body = prose_of(:mouse, "marker")

      assert body =~ ~r/line above/i
      assert body =~ ~r/unmarked question/i
    end
  end

  describe "the report part (mouse)" do
    test "says the message is stored and read later, without this session's scrollback" do
      assert prose_of(:mouse, "report") =~ ~r/stores the whole final message.{0,80}later/i
    end

    test "puts a size on the message, with the spec, the brief and cheap choices outside it" do
      body = prose_of(:mouse, "report")

      assert body =~ ~r/fits in six lines plus a line per cheap choice made without asking/i
      assert body =~ ~r/a spec sent for their ok, which goes whole/i
      assert body =~ ~r/a decision's brief/i
    end

    test "teaches the shape of the message, step by step" do
      body = prose_of(:mouse, "report")

      assert body =~ ~r/what is true now/i
      assert body =~ ~r/\*\*what changed\*\*.{0,60}and each cheap choice made without asking/i
      assert body =~ ~r/verified, not assumed/i
      assert body =~ ~r/one thing worth knowing/i
      assert body =~ "Nothing is waiting on you"
    end

    test "asks for the person's word only when a decision is genuinely needed" do
      assert prose_of(:mouse, "report") =~ ~r/review, approval, merge or design pick/i
    end

    test "a decision opens with a brief a reader with no context can follow" do
      body = prose_of(:mouse, "report")

      assert body =~
               ~r/each term the choice turns on.*the problem in one sentence.*why there is a choice at all.*then the options.*a recommendation, nothing else/i

      assert body =~ ~r/the marker line is only the pointer/i
    end

    test "the leave-out list drops the mechanics, not what the review turned up" do
      body = prose_of(:mouse, "report")

      assert body =~ ~r/Leave out:/
      assert body =~ ~r/the mechanics of a review, never what it turned up/i
      assert body =~ ~r/tool output/i
      assert body =~ ~r/lessons and reflections/
      assert body =~ ~r/pre-existing/i
    end

    test "a grilling round asks everything at once, whatever says one question at a time" do
      assert prose_of(:mouse, "report") =~
               ~r/a grilling round asks every open costly choice in one message, whatever else says one question at a time/i
    end

    test "leaves the general voice to the person's own CLAUDE.md" do
      body = prose_of(:mouse, "report")

      refute body =~ ~r/short sentences/i
      refute body =~ ~r/no filler/i
      refute body =~ ~r/an ordinary reply in five/i
    end
  end

  describe "the finish part (mouse)" do
    test "points at the shipped skill, in either install, instead of carrying the pipeline" do
      body = prose_of(:mouse, "finish")

      assert body =~ "whiska-finish"
      assert body =~ "`.claude/skills/whiska-finish/SKILL.md` in this repo"
      assert body =~ "`~/.claude/skills/whiska-finish/SKILL.md`"
      assert body =~ Marker.spell(:done)
    end

    test "says when the pipeline runs, who skips it, and that a missing one is said" do
      body = prose_of(:mouse, "finish")

      assert body =~ ~r/before writing the finished marker/i
      assert body =~ ~r/a turn ending on a decision for the person skips it/i
      assert body =~ ~r/neither the skill nor the file is there/i
    end

    test "says the per-repo facts are the project's own Finish heading" do
      assert prose_of(:mouse, "finish") =~
               ~r/`## Finish` heading in this project's own `CLAUDE.md`/
    end

    test "keeps in context the guards over what a session runs or dispatches" do
      body = prose_of(:mouse, "finish")

      assert body =~ ~r/text from outside this session/i
      assert body =~ ~r/read each before running or dispatching it/i
      assert body =~ ~r/branch under review/i
      assert body =~ ~r/decision for the person/i
    end

    test "stays a pointer: the pipeline's own rules are not restated" do
      body = prose_of(:mouse, "finish")

      for restated <- ["try to disprove", "merge base", "not to be dispatched directly"] do
        refute body =~ restated, restated
      end
    end
  end

  defp names(role), do: role |> Rules.parts() |> Enum.map(& &1.name)

  defp body_of(role, name), do: Enum.find(Rules.parts(role), &(&1.name == name)).body

  # A phrase the part teaches can fall across a line break, and where it wraps is
  # not the behaviour under test.
  defp prose_of(role, name), do: role |> body_of(name) |> String.replace(~r/\s+/, " ")
end
