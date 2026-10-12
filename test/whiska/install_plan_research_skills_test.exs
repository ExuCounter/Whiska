defmodule Whiska.InstallPlanResearchSkillsTest do
  use ExUnit.Case, async: true

  alias Whiska.Install

  defp skill(name) do
    assert {_path, body} =
             List.keyfind(Install.skills(), ".claude/skills/#{name}/SKILL.md", 0),
           "#{name} is not installed"

    body
  end

  defp prose(name), do: skill(name) |> String.replace(~r/\s+/, " ")

  defp description(name),
    do: skill(name) |> String.split("\n") |> Enum.find(&String.starts_with?(&1, "description:"))

  describe "the build plan ships as a skill Whiska owns (ADR-0063)" do
    test "its frontmatter names it, with a quoted description" do
      body = skill("whiska-plan")

      assert body =~ "name: whiska-plan"
      assert [_] = Regex.run(~r/^description: ".*"$/m, body)
      assert description("whiska-plan") =~ ~r/before any code/i
    end

    test "it is written at the worktree root, by the name Whiska ignores, never committed" do
      body = prose("whiska-plan")

      assert body =~ "`#{Whiska.BuildPlan.filename()}`"
      assert body =~ "git check-ignore -q #{Whiska.BuildPlan.filename()}"
      assert body =~ "`#{Whiska.BuildPlan.exclude_line()}`"
      assert body =~ ~r/never committed/i
    end

    test "it is the shape of the change, never a step-by-step plan, a few lines to one screen" do
      body = prose("whiska-plan")

      assert body =~ ~r/not a step-by-step plan/i
      assert body =~ ~r/a few lines for a small change, one screen at most/i
    end

    test "it is text, with code only for interfaces, data shapes and output the user sees" do
      body = prose("whiska-plan")

      assert body =~ ~r/interfaces \(signatures, command flags\)/i

      assert body =~
               ~r/data shapes \(a column, a JSON field, a file format, a 3 to 5 line example\)/i

      assert body =~ ~r/output the user sees/i
      assert body =~ ~r/never function bodies or step-by-step code/i
    end

    test "a diagram only when the change moves data across three or more parts" do
      assert prose("whiska-plan") =~
               ~r/a diagram only when the change moves data across three or more parts/i
    end

    test "it keeps the sections the person asked for, in order" do
      body = skill("whiska-plan")

      at =
        Enum.map(
          ["Where it lives", "Interfaces and data", "Testing", "Rejected approach"],
          &index_of(body, "## #{&1}")
        )

      assert at == Enum.sort(at)
    end

    test "testing names the seam, the first failing test and prior art, approved with it" do
      body = prose("whiska-plan")

      assert body =~ ~r/the seam, the first failing test, and prior art/i
      assert body =~ ~r/their ok on it is their ok on the seams/i
    end

    # The cold review compares the diff with what the person wanted, never with
    # how the builder chose to build it (ADR-0049).
    test "nothing the cold review reads points at it" do
      assert prose("whiska-plan") =~
               ~r/never name it in the spec or the research document/i
    end

    test "a costly change to it mid-build stops the build, a cheap one goes in the report" do
      body = prose("whiska-plan")

      assert body =~ ~r/a costly change to it is a decision for the person/i
      assert body =~ ~r/a cheap one goes in the final report/i
    end
  end

  describe "the research document ships as a skill Whiska owns" do
    test "its frontmatter names it, with a quoted description naming both kinds" do
      body = skill("whiska-research")

      assert body =~ "name: whiska-research"
      assert [_] = Regex.run(~r/^description: ".*"$/m, body)
      assert description("whiska-research") =~ ~r/bug/i
      assert description("whiska-research") =~ ~r/investigat/i
    end

    test "one template, its sections switched on by the kind of work" do
      body = skill("whiska-research")

      for section <- [
            "Question",
            "Before and after",
            "Cause",
            "What else the fix affects",
            "Options",
            "Picked",
            "Proposed build"
          ] do
        assert body =~ "## #{section}", section
      end

      assert prose("whiska-research") =~ ~r/kind: bug \| investigation/i
    end

    test "it is written at the worktree root, by the name Whiska ignores" do
      assert prose("whiska-research") =~ "`#{Whiska.Research.filename()}`"
    end
  end

  describe "a bug" do
    test "is reproduced by a failing test first: the test is the evidence of the cause" do
      assert prose("whiska-research") =~
               ~r/reproduce it with a failing test first.{0,40}the test is the evidence of the cause/i
    end

    test "one that cannot be reproduced stops on a question, with what was tried and no fix" do
      assert prose("whiska-research") =~
               ~r/cannot reproduce it.{0,120}what you tried.{0,40}no fix/is
    end

    test "options come only with a real choice; one obvious fix is the cause, the fix, the test" do
      body = prose("whiska-research")

      assert body =~ ~r/only when there is a real choice/i
      assert body =~ ~r/one obvious fix → the cause, the fix and the test/i
    end

    test "one obvious fix sends the research document and the build plan in one question" do
      assert prose("whiska-research") =~
               ~r/one obvious fix.{0,80}`whiska-plan`.{0,200}one question/is
    end

    test "a real choice sends the research document first, then the build plan after the pick" do
      body = prose("whiska-research")

      assert body =~ ~r/a real choice → send the research document alone/i
      assert body =~ ~r/write their pick under Picked/i
      assert body =~ ~r/then `whiska-plan`.{0,120}its own question/is
    end

    test "links go through `whiska spec-link`, then ok to build" do
      body = prose("whiska-research")

      assert body =~ "`whiska spec-link '<title>'`"
      assert body =~ "`Review research here: [<title>](<link>)`"
      assert body =~ ~s("ok to build?")
    end

    test "a fix that changes behaviour beyond the bug goes the feature way, with a spec" do
      assert prose("whiska-research") =~
               ~r/changes behaviour beyond the bug.{0,80}`whiska-spec`/is
    end

    # The cold review holds a bug fix against the before and after and the
    # option picked, never the build plan (ADR-0049).
    test "the research document never names the build plan" do
      assert prose("whiska-research") =~ ~r/never name the build plan in it/i
    end
  end

  describe "an investigation" do
    test "ends with the Proposed build block, and its report carries no link" do
      body = prose("whiska-research")

      assert body =~ ~r/an investigation.{0,200}`whiska show` links it/is
      refute body =~ ~r/an investigation.{0,80}`whiska spec-link`/is
    end
  end

  defp index_of(text, needle) do
    case :binary.match(text, needle) do
      {at, _} -> at
      :nomatch -> flunk("#{needle} is missing")
    end
  end
end
