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

  describe "the finish pipeline ships as a skill (ADR-0055)" do
    test "init installs it beside the other skills" do
      installed =
        Enum.map(Install.skills(), fn {path, _} -> Path.basename(Path.dirname(path)) end)

      assert "whiska-finish" in installed
      for name <- ~w(whiska-questions spawn-worktree), do: assert(name in installed, name)
    end

    test "the block points at the path init actually writes" do
      {path, _} =
        List.keyfind(Install.skills(), ".claude/skills/whiska-finish/SKILL.md", 0)

      finish = Enum.find(Whiska.ClaudeMd.parts(), &(&1.name == "finish")).body

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
      assert body =~ ~r/marker|done/i
    end
  end

  describe "the five steps" do
    test "run in order, in the mouse's own session, before the marker" do
      body = prose()

      assert body =~ ~r/read the work back against what was asked/i
      assert body =~ ~r/run this repo's checks/i
      assert body =~ ~r/send reviewers over the change/i
      assert body =~ ~r/two rounds is the ceiling/i
      assert index_of(body, "Then the marker") > index_of(body, "Send reviewers")
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

    test "names how red-before-the-turn is established, not just the rule" do
      assert prose() =~ ~r/merge base/i
    end
  end

  describe "the reviewers" do
    test "names the axes, and frontend only when a person sees it" do
      body = prose()

      for axis <- ["correctness", "security", "performance", "frontend"] do
        assert body =~ "**#{axis}** —", axis
      end

      assert body =~ ~r/only when the change touches something a person sees/i
    end

    # ADR-0075 narrows ADR-0072's always-on wio row.
    test "the test reviewer is a fifth axis, only when the change touches a test file" do
      body = prose()

      assert body =~ "**tests** —"
      assert body =~ "`wio-test-reviewer`"
      assert body =~ ~r/only when the change adds, edits or deletes a test file/i
      assert body =~ ~r/`git diff --name-only` from the merge base: `wio-test-reviewer`/
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
  end

  describe "what this repo calls green" do
    test "the per-repo facts come from a Finish heading in CLAUDE.md" do
      body = prose()

      assert body =~ "## Finish"
      assert body =~ "checks:"
      assert body =~ "specs:"
      assert body =~ "ticket:"
      assert body =~ ~r/outside Whiska's block/i
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
      assert body =~ ~r/commits before it finishes/i
      assert body =~ ~r/leaves that directory behind/i
    end

    test "a missing Finish heading is not a reason to stop" do
      body = prose()

      assert body =~ ~r/no `## Finish` heading/i
      assert body =~ ~r/say.{0,30}what was assumed/i
    end
  end

  describe "an investigation that found work to do proposes it (ADR-0074)" do
    test "the proposal is three labelled lines the main session can lift verbatim" do
      body = skill()

      assert body =~ "**Proposed build**"
      assert body =~ "- Found:"
      assert body =~ "- Build:"
      assert body =~ "- Touches:"
    end

    test "it ends on the finished marker and never asks to build it itself" do
      body = prose()

      # The finished picker is where building it is offered; a mouse asking
      # "shall I build this?" would be answered into a session that cannot.
      assert body =~ ~r/end on the finished marker/i
      assert body =~ ~r/never ask whether to build it/i
    end

    test "only when it changed nothing and something should change" do
      body = prose()

      assert body =~ ~r/changed nothing/i
      assert body =~ ~r/no proposal/i
    end

    # Only a mouse that may only look is offered a fresh build; the skill
    # promises nothing to the rest.
    test "promises the fresh build only to a mouse that may only look" do
      assert prose() =~ ~r/a mouse that may only look/i
    end
  end

  describe "it does not restate what the block already says" do
    test "the shape of the message is the block's to teach" do
      refute prose() =~ ~r/outcomes, not mechanics/i
    end
  end

  defp index_of(text, needle) do
    [{at, _}] = Regex.run(~r/#{needle}/i, text, return: :index)
    at
  end
end
