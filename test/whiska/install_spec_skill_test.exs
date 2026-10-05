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
    test "a tweak or quick fix skips it, and so does a brief that needed no grilling" do
      body = prose("whiska-spec")

      assert body =~ ~r/a tweak or quick fix skips it/i
      assert body =~ ~r/needed no grilling/i
    end

    test "it asks nothing new: the grilling already did" do
      assert prose("whiska-spec") =~ ~r/do not interview the person/i
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
      assert prose("whiska-spec") =~ ~r/the decision marker the block describes, in a worktree/i
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

  describe "the template is the person's to-spec template" do
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

    test "user stories keep their shape and their length" do
      body = prose("whiska-spec")

      assert body =~ "As an <actor>, I want a <feature>, so that <benefit>"
      assert body =~ "A LONG, numbered list of user stories"
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
