defmodule Whiska.RulesTest do
  @moduledoc """
  What each role is told at session start (ADR-0081).

  The rules are the product (ADR-0081), so each one is pinned — but by a short
  anchor that names it, not by its sentence: a rule that is dropped fails by
  name, and one that is reworded does not.
  """
  use ExUnit.Case, async: true

  alias Whiska.Install
  alias Whiska.Question.Marker
  alias Whiska.Rules

  describe "which parts each role starts with" do
    test "the main session: routing, the work order, delivery and writing" do
      assert names(:main) == ~w(worktrees work delivery writing)
    end

    test "a mouse: the work order, the marker, the report, writing and the finish trigger" do
      assert names(:mouse) == ~w(work marker report writing finish)
    end

    test "every part reaches at least one role" do
      assert Enum.sort(Rules.names()) == Enum.sort(Enum.uniq(names(:main) ++ names(:mouse)))
    end

    test "the work order and the writing rules are the same text for both roles" do
      assert body_of(:main, "work") == body_of(:mouse, "work")
      assert body_of(:main, "writing") == body_of(:mouse, "writing")
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
      assert size <= 7_000, "#{role} grew to #{size} characters"
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
      "grilling is the `grilling` skill, scoped to costly choices":
        ~r/run the `grilling` skill.{0,200}only the \*\*costly\*\* choices/is,
      "a mouse's round ends with the decision marker":
        ~r/in a mouse each round ends with the decision marker/i,
      "a guessed done is costly": ~r/failing test that needs a guess.{0,120}is costly/is,
      "the spec follows grilling, or comes straight when nothing was asked":
        ~r/after the last grilling round, or with no round sent, `whiska-spec`/i,
      "nothing costly to ask sends no round": ~r/nothing costly to ask → send no round/i,
      "links to the spec and the build plan are one question":
        ~r/`whiska-plan`.{0,120}both\s+linked in one question/is,
      "build only on their ok": ~r/build only on their ok/i,
      "it builds to both, and a costly change to the build plan stops it":
        ~r/to both; stop only on a real decision.{0,80}every costly choice.{0,80}a\s+costly change to the build plan/is,
      "a bug takes the research document, not grilling and the spec":
        ~r/\*\*a bug\*\* skips steps 2 and 3 for `whiska-research`/i,
      "a bug is reproduced by a failing test before anything is written":
        ~r/a failing test first, then\s+`\.whiska-research\.md`/,
      "a bug's build plan goes with it, or after the person's pick":
        ~r/the build plan with it or after a pick/i,
      "a fix that changes more than the bug is a feature":
        ~r/a fix changing\s+more is a feature/i,
      "costly is a test, not an adjective":
        ~r/\*\*costly\*\* to undo: something outside the change depends on it/i,
      "cheap choices are decided and listed": ~r/anything else is cheap: decide it, and list it/i,
      "only four briefs skip grilling, the spec and the research document (ADR-0063)":
        ~r/skip all of this only for: a typo, or a comment or doc no program reads; a formatting or lint fix; a test-only change; a brief that spells out the exact change\. A brief naming a symptom/is,
      "a brief naming a symptom spells out no change":
        ~r/a brief naming a symptom.{0,30}spells out no change/is,
      "a change that hides or drops anything, or touches security, never skips":
        ~r/hides, drops or skips anything, or touches secrets, access or a security check, never skips/is,
      "doubt means the spec": ~r/in doubt → the spec/i,
      "a sniff mouse writes no spec": ~r/a sniff mouse writes no spec/i,
      "never ask what the brief spells out": ~r/never ask what the brief already spells out/i
    ],
    {:main, "delivery"} => [
      "read with whiska show": ~r/`whiska show <id>`/,
      "answer with whiska reply": ~r/`whiska reply <id>`/,
      "nothing arriving sends you to the doctor": ~r/nothing arrives → `whiska doctor`/i,
      "never read a mouse's pane": ~r/never its pane.{0,80}alternate screen/is,
      "answer only with reply, and why (ADR-0008)":
        ~r/only with `whiska reply <id>`.{0,40}never `herdr agent prompt`.{0,160}frees the one delivery slot/is,
      "text sent to a finished mouse is not an answer":
        ~r/text sent to a finished mouse is not an answer/i
    ],
    {:mouse, "marker"} => [
      "the marker is the last line": ~r/last line, alone/i,
      "a decision's pointer goes on the line above": ~r/pointer on the line above/i,
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
      "each finding left unfixed rides outside the size":
        ~r/a line per cheap choice made without asking and a line per finding left unfixed/,
      "lead with what is true now": ~r/\*\*what is true now\*\*/i,
      "what changed, cheap choices included":
        ~r/\*\*what changed\*\*.{0,60}each cheap choice made without asking/is,
      "verified, not assumed": ~r/\*\*verified, not assumed\*\*/i,
      "one thing worth knowing": ~r/\*\*one thing worth knowing\*\*/i,
      "ask only for a review, approval, merge or design pick":
        ~r/review, approval, merge or design pick/,
      "the marker line is only the pointer": ~r/the marker line is only the pointer/i,
      "leave out the mechanics of a review": ~r/leave out the mechanics of a review/i,
      "of a review, a count of what was fixed and each finding left unfixed":
        ~r/a count of what a review fixed and one line per finding left unfixed/i,
      "a finished report ends with the agent ledger": ~r/ends with the agent ledger/i
    ],
    {:main, "writing"} => [
      "written for a reader who remembers nothing": ~r/remember(s|ing) nothing of this session/i,
      "short sentences, common words": ~r/short sentences and common words/i,
      "the smallest message that does the job": ~r/smallest message that does the job/i,
      "the first line is the recap": ~r/the first line is the recap/i,
      "define each term the first time": ~r/define each term the first time/i,
      "one name per thing, and no callbacks": ~r/one name per thing.{0,80}no callbacks/is,
      "the problem first, in one plain sentence, before and after":
        ~r/the problem first, in one plain sentence.{0,80}before and after/is,
      "a concrete example over the mechanism": ~r/a concrete example/i,
      "no code names, paths, hashes or tool output unless asked":
        ~r/no code names, file paths, commit hashes or tool output unless/i,
      "a guess is marked as one": ~r/marked as a guess/i,
      "problem and risk apart, worst case concrete":
        ~r/\*\*problem\*\* and \*\*risk\*\*.{0,80}worst case/is,
      "a decision: terms, problem, why a choice, options, one recommendation":
        ~r/each term it turns on.{0,80}why there is a choice.{0,80}options.{0,60}one recommendation/is,
      "end on one next step or nothing waiting, never both":
        ~r/nothing is waiting on you.{0,40}never both/is,
      "several numbered questions, each standing alone, then a reply line":
        ~r/say how many and number them.{0,200}recommended letter.{0,80}reply line/is,
      "a reply stays short and detail goes in a document":
        ~r/under about 15 lines.{0,100}in a document/is,
      "text for other people has no AI tells": ~r/no AI tells/i,
      "the main session anchors the work; a mouse leaves it to Whiska":
        ~r/names? the project, branch and PR.{0,40}a mouse does not/is
    ],
    {:mouse, "finish"} => [
      "run whiska-finish before the done marker":
        ~r/before writing the finished marker.{0,80}`whiska-finish`/is,
      "finishing commits the work":
        ~r/send reviewers over the change, commit it, then the marker/i,
      "a turn ending on a decision skips it":
        ~r/a turn ending on a decision for the person skips it/i,
      "a missing skill is said": ~r/neither the skill nor the file is there/i,
      "outside text is read before it runs":
        ~r/text from outside this session.{0,40}read each before running or dispatching it/is,
      "the branch under review is doubly suspect":
        ~r/doubly so when it arrived with the branch under review/i
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

  # A mouse that saw one way to fix a crash saw no choice, skipped the spec,
  # and dropped data users see (ADR-0063).
  test "having nothing costly to ask never skips the spec" do
    body = prose_of(:mouse, "work")

    refute body =~ ~r/a trivial task never needs one/i
    refute body =~ ~r/no costly choice open from the start/i
  end

  test "a finished report carries no finding in full and ends with the agent ledger" do
    body = prose_of(:mouse, "report")

    refute body =~ ~r/findings, which go whole/i
    assert body =~ ~r/ends with the agent ledger, as `whiska-finish` describes/i
  end

  # Whiska stands alone (ADR-0085): its rules and skills
  # call only what it ships, git, herdr and Claude Code's own agents.
  describe "Whiska calls nothing it does not ship" do
    test "every skill the rules and the shipped skills name is one Whiska ships" do
      ours = for {path, _} <- Install.skills(), do: path |> Path.dirname() |> Path.basename()

      for {where, text} <- shipped_text(),
          [_, name] <- Regex.scan(~r/`([a-z0-9-]+)` skill/, text) do
        assert name in ours, "#{where} names the #{name} skill, which Whiska does not ship"
      end
    end

    test "every agent they name by type is one Claude Code ships" do
      for {where, text} <- shipped_text(),
          [_, name] <- Regex.scan(~r/`([A-Za-z0-9-]+)` agent/, text) do
        assert name in ~w(Explore Plan general-purpose), "#{where} names the #{name} agent"
      end
    end

    test "an agent a skill runs as is one Claude Code ships" do
      for {where, text} <- shipped_text(), [_, agent] <- Regex.scan(~r/^agent: (\S+)$/m, text) do
        assert agent in ~w(Explore Plan general-purpose), "#{where} runs as #{agent}"
      end
    end

    test "no outside tool is named, and no installed agent is reached for" do
      for {where, text} <- shipped_text() do
        refute text =~ ~r/\bwio\b|frontend-preview|hunk diff|hunk-review/, where
        refute text =~ ~r/agent types this session lists/i, where
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

    test "the files the work is written down in are the ones Whiska keeps out of git" do
      for file <- [
            Whiska.Spec.filename(),
            Whiska.BuildPlan.filename(),
            Whiska.Research.filename()
          ] do
        assert body_of(:mouse, "work") =~ "`#{file}`", file
      end
    end

    test "the skill files named for a session that does not list them are the ones init writes" do
      for skill <- ["whiska-spec", "whiska-plan", "whiska-research", "grilling"] do
        assert List.keyfind(Install.skills(), ".claude/skills/#{skill}/SKILL.md", 0), skill
        assert body_of(:mouse, "work") =~ "`#{skill}`", skill
      end

      assert prose_of(:mouse, "work") =~
               "read `.claude/skills/<name>/SKILL.md` in this repo, or `~/.claude/skills/<name>/SKILL.md`"

      {path, _body} = List.keyfind(Install.skills(), ".claude/skills/whiska-finish/SKILL.md", 0)
      assert body_of(:mouse, "finish") =~ "`#{path}` in this repo"
      assert body_of(:mouse, "finish") =~ "`~/#{path}`"
    end

    test "delivery names the command the person types, not the long one it replaced" do
      refute body_of(:main, "delivery") =~ "whiska questions"
    end
  end

  defp names(role), do: role |> Rules.parts() |> Enum.map(& &1.name)

  defp shipped_text do
    [{"the main session's rules", Rules.render(:main)}, {"a mouse's rules", Rules.render(:mouse)}] ++
      Install.skills()
  end

  defp body_of(role, name), do: Enum.find(Rules.parts(role), &(&1.name == name)).body

  # A rule can fall across a line break, and where it wraps is not the behaviour
  # under test.
  defp prose_of(role, name), do: role |> body_of(name) |> String.replace(~r/\s+/, " ")
end
