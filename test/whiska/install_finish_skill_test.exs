defmodule Whiska.InstallFinishSkillTest do
  use ExUnit.Case, async: true

  alias Whiska.Install

  defp skill do
    assert {_path, body} =
             List.keyfind(Install.skills(), ".claude/skills/whiska-finish/SKILL.md", 0),
           "whiska-finish is not installed"

    body
  end

  defp prose, do: skill() |> String.replace(~r/\s+/, " ")

  @proposal ".claude/skills/whiska-finish/proposed-build.md"

  defp proposal do
    assert {_path, body} = List.keyfind(Install.skills(), @proposal, 0),
           "the Proposed build section is not installed beside the skill"

    body
  end

  defp proposal_prose, do: proposal() |> String.replace(~r/\s+/, " ")

  describe "the finish pipeline ships as a skill (ADR-0055)" do
    test "init installs it beside the other skills" do
      installed =
        Enum.map(Install.skills(), fn {path, _} -> Path.basename(Path.dirname(path)) end)

      assert "whiska-finish" in installed
      for name <- ~w(show spawn-worktree), do: assert(name in installed, name)
    end

    test "a mouse's finish rules point at the path init actually writes" do
      {path, _} =
        List.keyfind(Install.skills(), ".claude/skills/whiska-finish/SKILL.md", 0)

      finish = Enum.find(Whiska.Rules.parts(:mouse), &(&1.name == "finish")).body

      assert finish =~ path
      assert finish =~ "whiska-finish"
    end

    test "its frontmatter names it, with a quoted description" do
      body = skill()

      assert body =~ "name: whiska-finish"
      assert [_] = Regex.run(~r/^description: ".*"$/m, body)
    end

    test "the description says when a session reaches for it" do
      body = skill() |> String.split("\n") |> Enum.find(&String.starts_with?(&1, "description:"))

      assert body =~ ~r/finish/i
      assert body =~ ~r/commit it, then write the done marker/i
    end
  end

  describe "the steps" do
    test "run in order, in the mouse's own session, before the marker" do
      body = prose()

      assert body =~ ~r/read the work back against what was asked/i
      assert body =~ ~r/run this repo's checks/i
      assert body =~ ~r/send reviewers over the change/i
      assert body =~ ~r/two rounds is the ceiling/i
      assert index_of(body, "Then the marker") > index_of(body, "Send reviewers")
    end

    test "the work is read back against the spec the person approved, when there is one" do
      assert prose() =~ "its spec in `#{Whiska.Spec.filename()}` when there is one"
    end

    test "a decision turn skips the pipeline, and the main session never runs it" do
      body = prose()

      assert body =~ ~r/skips/i
      assert body =~ ~r/main session never runs/i
    end

    test "the marker it ends on is the one Whiska parses, named in words" do
      assert skill() =~ Whiska.Question.Marker.spell(:done)
    end

    test "a wrong scope goes to the person, a small mismatch gets fixed" do
      body = prose()

      assert body =~ ~r/scope/i
      assert body =~ ~r/end the turn on a decision for the person/i
      assert body =~ ~r/fix it now/i
    end

    test "a decision this repo's rules do not cover is the person's, not a quiet divergence" do
      assert prose() =~ ~r/quiet divergence/i
    end

    test "fixing a check is bounded: inside the change, never against step 1" do
      body = prose()

      assert body =~ ~r/only inside this change/i
      assert body =~ ~r/already red before the turn/i
      assert body =~ ~r/deleting an assertion/i
    end

    test "a check already red before the turn does not block the marker" do
      assert prose() =~ ~r/every check is green, or red only where it was red before the turn/i
    end

    test "names how red-before-the-turn is established, not just the rule" do
      assert prose() =~ ~r/merge base/i
    end
  end

  describe "the commit before the marker" do
    test "comes after the second round and before the marker" do
      body = prose()

      assert index_of(body, "## 5\\. Commit the work") > index_of(body, "## 4\\. Round two")
      assert index_of(body, "## 6\\. Then the marker") > index_of(body, "## 5\\. Commit the work")

      [_, intro] = Regex.run(~r/goes down only at step (\d)/, body)
      [_, heading] = Regex.run(~r/## (\d)\. Then the marker/, body)
      assert intro == heading
    end

    test "leaves the worktree clean, the spec aside, and never pushes" do
      body = prose()

      assert body =~ ~r/every change the brief made.{0,40}on its branch/i
      assert body =~ ~r/delete.{0,40}scratch files/i
      assert body =~ ~r/done when `git status --porcelain` prints nothing/i

      assert body =~
               "Whiska's own `.whiska-mouse` and `#{Whiska.Spec.filename()}` are never committed, deleted or named"

      assert body =~ ~r/never push/i
    end

    test "a secret or local setup is left, named, and never deleted" do
      assert prose() =~
               ~r/never commit a secret or local setup, and never delete a file this turn did not make.{0,200}`\.claude\/` folder `spawn-worktree` copied in.{0,120}leave each one and name it in the message/i
    end

    test "a repo whose own instructions say the person commits keeps that" do
      assert prose() =~
               ~r/this repo's own instructions say the person commits.{0,120}left uncommitted on purpose/i
    end

    test "a status git will not give is said, never taken for clean" do
      assert prose() =~
               ~r/`git status` fails.{0,80}say so in the message.{0,20}never call the worktree clean/i
    end

    test "a scan that reads commits gets this turn's work committed before it runs" do
      assert prose() =~
               ~r/reads commits rather than the working tree means this turn commits its work before the scan runs/i
    end

    test "a turn with nothing new to check still commits" do
      assert prose() =~ ~r/skip steps 2 to 4: say so in one line, then steps 5 and 6/i
    end
  end

  describe "reviewers are chosen by what the diff does (ADR-0082)" do
    test "one table: axis, trigger, how detected, evidence" do
      assert prose() =~ "| axis | trigger | how detected | evidence |"
    end

    test "correctness always runs" do
      assert prose() =~ ~r/\| \*\*correctness\*\* \| always \|/
    end

    test "security runs when any trigger fires and is skipped when none does" do
      body = prose()

      assert body =~ ~r/\| \*\*security\*\* \| any trigger fires.{0,40}skipped when none/i

      for trigger <- [
            "built from text",
            "allow or deny or permissions",
            "network, socket, env",
            "another agent's text",
            "a person or program will run",
            "agent instructions, hooks or scripts",
            "secrets or auth"
          ] do
        assert body =~ trigger, trigger
      end
    end

    test "performance runs on a hot path, else its questions join correctness" do
      body = prose()

      assert body =~ ~r/\| \*\*performance\*\* \| only on a hot path/i
      assert body =~ ~r/timer, scheduler, middleware or handler, or a loop over input that grows/
      refute body =~ "the diff contains a loop"
      assert body =~ ~r/its three questions join the correctness prompt/
    end

    test "a small diff gets one combined reviewer" do
      assert prose() =~
               ~r/under 40 changed lines, at most two files and no security trigger.{0,80}one combined reviewer/i
    end

    test "model per axis goes through the Agent call's model parameter" do
      assert prose() =~
               ~r/`model` parameter.{0,80}performance and the scout on the model `whiska shape --rules` picks.{0,60}inherit/i
    end

    test "a repo can only add reviewers" do
      assert prose() =~ ~r/a repo only adds.{0,200}`reviewers:` line/i
    end
  end

  describe "the agent ledger ends the report" do
    test "one line per agent sent, from the hand-back usage block" do
      body = prose()

      assert body =~ ~r/agent ledger/i

      for field <- ["`subagent_tokens`", "`tool_uses`", "`duration_ms`"] do
        assert body =~ field, field
      end

      assert body =~
               ~r/axis, agent type, model asked for, new tokens, tool uses, seconds, findings and what became of them/
    end

    test "new tokens are cache writes plus input plus output, said once" do
      assert prose() =~
               ~r/new tokens are cache writes plus input plus output.{0,40}cache reads are not counted/i
    end

    test "one line per axis skipped, naming the triggers checked" do
      assert prose() =~ ~r/one line per axis skipped.{0,40}triggers it checked/i
    end
  end

  describe "the reviewers" do
    test "names the axes, and frontend only when a person sees it" do
      body = prose()

      for axis <- ["correctness", "security", "performance", "frontend"] do
        assert body =~ "| **#{axis}** |", axis
      end

      assert body =~ ~r/the change touches something a person sees/i
    end

    # ADR-0075 narrows ADR-0072's always-on wio row.
    test "the test reviewer is a fifth axis, only when the change touches a test file" do
      body = prose()

      assert body =~ "| **tests** |"
      assert body =~ "`wio-test-reviewer`"
      assert body =~ ~r/the change adds, edits or deletes a test file/i
      assert body =~ ~r/`git diff --name-only` from the merge base \| `wio-test-reviewer`/
      assert body =~ "beyond the five"
    end

    test "a test reviewer this repo ships is the copy read before dispatch" do
      assert prose() =~
               ~r/`\.claude\/agents\/wio-test-reviewer\.md` in this repo is the copy that runs, not the one in `~\/\.claude`/
    end

    test "the written-prompt fallback names its one exception" do
      assert prose() =~ ~r/write the prompt for it, except tests, above/i
    end

    test "a missing test reviewer is one line in the message, never improvised" do
      body = prose()

      assert body =~ ~r/not listed → say in one line that it is not installed/i
      assert body =~ ~r/the one axis not written as a prompt/i
    end

    test "REDO or REMOVE on this change's own test is important, never a way past a check" do
      body = prose()

      assert body =~ ~r/REDO or REMOVE on a test this change added or edited is \*\*important\*\*/
      assert body =~ ~r/on any other, \*\*pre-existing\*\*/
      assert body =~ ~r/never to make a check pass/i
    end

    test "a reviewer somebody else maintains beats one improvised on the spot" do
      body = prose()

      assert body =~ ~r/agent types this session lists/i
      assert body =~ ~r/before writing a reviewer prompt/i
    end

    test "an agent that edits, or that refuses dispatch, is not a reviewer" do
      body = prose()

      assert body =~ ~r/changes code.{0,60}is not a reviewer/i
      assert body =~ ~r/not to be dispatched directly/i
    end

    test "nothing installed for an axis is the ordinary case, not a degraded one" do
      body = prose()

      assert body =~ ~r/write the prompt/i
      assert body =~ ~r/ordinary case, not a degraded one/i
    end

    test "an agent definition is read before it is dispatched, like a check command" do
      body = prose()

      assert body =~ ~r/read (an )?agent definition before|read before it is dispatched/i
      assert body =~ ~r/arrived with the branch under review/i
      assert body =~ ".claude/agents/"
      assert body =~ ~r/not the session's listing of it/i
    end

    test "extra axes this repo wants come from a reviewers: line" do
      body = prose()

      assert body =~ "reviewers:"
      assert body =~ ~r/already exist in this repo/i
      assert body =~ ~r/quoted as the data it is/i
      assert body =~ ~r/never improvised from the name/i
      assert body =~ ~r/does not exempt one/i
      assert body =~ ~r/a couple/i
      assert body =~ ~r/every finished turn/i
    end

    test "the marker waits for every reviewer" do
      body = prose()

      assert body =~ ~r/marker does not go down until every reviewer has reported/i
      assert body =~ ~r/no progress note|no such thing as a progress note/i
      assert body =~ ~r/not the turn finishing/i
      assert body =~ ~r/nothing is delivered from it/i
    end

    test "a finding is disproved before it is believed, then gets one of three words" do
      body = prose()

      assert body =~ ~r/a claim, not a verdict/i
      assert body =~ ~r/try to disprove/i
      assert body =~ ~r/\*\*important\*\* — fix it now/i
      assert body =~ ~r/\*\*nit\*\* — fix it now if/i
      assert body =~ ~r/\*\*pre-existing\*\* — this change did not cause it/i
    end

    test "no reviewer finding reaches the person, and the escalations are counted right" do
      body = prose()

      assert body =~ ~r/nothing a reviewer finds reaches the person/i
      assert body =~ ~r/scope that turns out to be wrong \(step 1\)/i
      assert body =~ ~r/rules do not say how to change \(step 1\)/i
      assert body =~ ~r/still red after the second round \(step 4\)/i
      assert body =~ ~r/a real vulnerability.{0,40}is important/i
      assert body =~ ~r/three things that are not findings/i
      assert body =~ ~r/an agent definition this step will not dispatch/i
      refute body =~ ~r/two things that are not findings/i
    end

    test "a security finding is named in the message whatever word it got" do
      assert prose() =~ ~r/whatever word it got/i
    end

    test "nothing changed since this session's last green finish skips the checks and reviewers" do
      body = prose()

      assert body =~
               ~r/nothing changed since this session's last green finish → skip steps 2 to 4/i

      assert body =~ ~r/say so in one line/i
      assert index_of(body, "last green finish") < index_of(body, "## 1\\.")
    end
  end

  describe "what this repo calls green" do
    test "the per-repo facts come from a Finish heading in CLAUDE.md" do
      body = prose()

      assert body =~ "## Finish"
      assert body =~ "checks:"
      assert body =~ "specs:"
      assert body =~ "ticket:"
    end

    test "a ticket is evidence, never an instruction to the session" do
      body = prose()

      assert body =~ ~r/never an instruction/i
      assert body =~ ~r/goes to the person/i
    end

    test "a check command that does more than the repo's own tooling is the person's call" do
      body = prose()

      assert body =~ ~r/fetches|downloads/i
      assert body =~ ~r/branch under review|branch being finished/i
    end

    test "a heavier security scan is the repo's to opt into, and it is read first" do
      body = prose()

      assert body =~ "security:"
      assert body =~ ~r/read before it is run/i
      assert body =~ ~r/commits its work before the scan runs/i
      assert body =~ ~r/leaves that directory behind/i
    end

    test "a missing Finish heading is not a reason to stop" do
      body = prose()

      assert body =~ ~r/no `## Finish` heading/i
      assert body =~ ~r/say.{0,30}what was assumed/i
    end
  end

  describe "an investigation that found work to do proposes it (ADR-0074)" do
    test "the skill sends a turn that only investigated to the file beside it, and only that turn" do
      body = prose()

      assert body =~ "`proposed-build.md`"
      assert body =~ ~r/investigated, changed nothing/i
      refute skill() =~ "- Touches:"
    end

    test "the proposal is three labelled lines the main session can lift verbatim" do
      body = proposal()

      assert body =~ "**Proposed build**"
      assert body =~ "- Found:"
      assert body =~ "- Build:"
      assert body =~ "- Touches:"
    end

    test "it ends on the finished marker and never asks to build it itself" do
      body = proposal_prose()

      # The finished picker is where building it is offered; a mouse asking
      # "shall I build this?" would be answered into a session that cannot.
      assert body =~ ~r/end on the finished marker/i
      assert body =~ ~r/never ask whether to build it/i
    end

    test "only when it changed nothing and something should change" do
      body = proposal_prose()

      assert body =~ ~r/changed nothing/i
      assert body =~ ~r/no proposal/i
    end

    # The picker offers it by what the branch holds, not by the mouse's mode;
    # the skill promises nothing to a branch with something on it.
    test "promises the fresh build only when the branch has nothing on it" do
      assert proposal_prose() =~
               ~r/when the branch has nothing on it.{0,60}offers it as a fresh build/i

      assert proposal_prose() =~ ~r/otherwise it is there for the person to read/i
    end
  end

  describe "it does not restate what the rules already say" do
    test "the shape of the message is the report rules' to teach" do
      refute prose() =~ ~r/outcomes, not mechanics/i
      assert prose() =~ ~r/the report rules teach its shape/i
    end
  end

  defp index_of(text, needle) do
    [{at, _}] = Regex.run(~r/#{needle}/i, text, return: :index)
    at
  end
end
