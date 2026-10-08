defmodule Whiska.InstallSpecSkillTest do
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

  describe "the spec ships as a skill Whiska owns" do
    test "its frontmatter names it, with a quoted description" do
      body = skill("whiska-spec")

      assert body =~ "name: whiska-spec"
      assert [_] = Regex.run(~r/^description: ".*"$/m, body)
    end

    test "a session may run it on its own" do
      refute skill("whiska-spec") =~ "disable-model-invocation"
    end

    test "the description says it runs after grilling, before any code" do
      assert description("whiska-spec") =~ ~r/after .*grilling/i
      assert description("whiska-spec") =~ ~r/before any code/i
    end
  end

  describe "when it runs" do
    test "a brief that needed no grilling skips it; a tweak or quick fix does not" do
      body = prose("whiska-spec")

      refute body =~ ~r/tweak or quick fix/i
      assert body =~ ~r/needed no grilling/i
    end

    test "it asks nothing new: the grilling already did" do
      assert prose("whiska-spec") =~ ~r/ask the person nothing new/i
    end
  end

  describe "where the spec lives" do
    test "an untracked file at the worktree root, by the name Whiska ignores" do
      body = prose("whiska-spec")

      assert body =~ "`#{Whiska.Spec.filename()}`"
      assert body =~ "git rev-parse --show-toplevel"
      assert body =~ ~r/never committed/i
    end

    # From a worktree the exclude file is in the main checkout, which a mouse
    # never edits (ADR-0013).
    test "a mouse whose spec git does not ignore says so, and never writes the exclude file" do
      body = prose("whiska-spec")

      assert body =~ "git check-ignore -q #{Whiska.Spec.filename()}"
      assert body =~ "`#{Whiska.Spec.exclude_line()}`"
      assert body =~ ~r/in a worktree, never write the exclude file yourself/i
      assert body =~ ~r/say so in one line under the spec/i
      refute body =~ "--git-path"
    end

    test "a session in the main checkout adds the line itself" do
      assert prose("whiska-spec") =~ ~r/in the main checkout, add the line/i
    end

    test "nothing goes to an issue tracker" do
      body = prose("whiska-spec")

      refute body =~ ~r/issue tracker/i
      refute body =~ "ready-for-agent"
      refute body =~ "setup-matt-pocock-skills"
    end
  end

  describe "the person sees it before the build" do
    test "the whole spec goes to them as the question, and the session waits" do
      body = prose("whiska-spec")

      assert body =~ ~r/send the whole spec to the person as the question/i
      assert body =~ ~r/build only after they say ok/i
    end

    test "only a worktree session ends the question on a marker" do
      assert prose("whiska-spec") =~ ~r/the decision marker a mouse's rules describe/i
    end

    test "any other answer revises the file and sends the whole spec again" do
      assert prose("whiska-spec") =~ ~r/anything else → change the file to match/i
    end

    test "the test seams are approved with the spec, not in a round of their own" do
      assert prose("whiska-spec") =~ ~r/ok on the spec is their ok on the seams/i
    end

    test "a costly choice the spec does not settle is a new decision, not a quiet edit" do
      assert prose("whiska-spec") =~ ~r/not a quiet edit/i
    end
  end

  describe "the template keeps the person's sections and shrinks what goes under them (ADR-0063)" do
    test "keeps every section, in order" do
      body = skill("whiska-spec")

      sections = [
        "Problem Statement",
        "Solution",
        "User Stories",
        "Implementation Decisions",
        "Testing Decisions",
        "Out of Scope",
        "Further Notes"
      ]

      at = Enum.map(sections, &index_of(body, "## #{&1}"))
      assert at == Enum.sort(at)
    end

    test "the spec fits on one screen; longer means the brief holds more than one build" do
      body = prose("whiska-spec")

      refute body =~ ~r/no length cap/i
      assert body =~ ~r/fits on one screen, about 500 words/i

      assert body =~
               ~r/longer means the brief holds more than one build: say so above the spec and name the split/i
    end

    test "anything beyond the brief is one line under Out of Scope" do
      assert prose("whiska-spec") =~
               ~r/anything more the code suggests is one line under out of scope/i
    end

    test "user stories are about the person's users, ten at most" do
      body = prose("whiska-spec")

      assert body =~ "As an <actor>, I want a <feature>, so that <benefit>"
      assert body =~ ~r/ten at most/i

      assert body =~
               ~r/actor is a mouse, the main session or a future reader is an implementation step: drop it/i

      refute body =~ "A LONG, numbered list"
      refute body =~ ~r/extremely extensive/i
    end

    test "implementation decisions are the costly choices, one line each, citing the ADR" do
      body = prose("whiska-spec")

      assert body =~ ~r/costly choices the build rests on, one line each, citing the adr/i

      assert body =~
               ~r/docs upkeep are left to the build/i
    end

    test "testing decisions name the seam, the first failing test and prior art" do
      assert prose("whiska-spec") =~
               ~r/the seam, the first failing test, and prior art in one line/i
    end

    test "further notes hold only what changes the ok; a grilling answer appears once" do
      body = prose("whiska-spec")

      assert body =~ ~r/only what changes the person's ok/i
      assert body =~ ~r/grilling answers appear once, as decisions/i
    end
  end

  describe "the grilling skill ships with Whiska too" do
    test "init installs it under its own name" do
      body = skill("grilling")

      assert body =~ "name: grilling"
      assert description("grilling") =~ ~r/grill/i
    end

    test "rounds ask the whole frontier, each with a recommended answer, then wait" do
      body = prose("grilling")

      assert body =~ ~r/ask the whole frontier in one round/i
      assert body =~ ~r/give your recommended answer/i
      assert body =~ ~r/wait for the user's answers before the next round/i
    end

    test "facts are looked up, decisions are put to the person" do
      body = prose("grilling")

      assert body =~ ~r/finding _facts_ is your job/i
      assert body =~ ~r/the _decisions_ are the user's/i
    end
  end

  defp index_of(text, needle) do
    case :binary.match(text, needle) do
      {at, _} -> at
      :nomatch -> flunk("#{needle} is missing")
    end
  end
end
