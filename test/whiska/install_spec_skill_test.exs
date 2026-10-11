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
    test "every brief gets one, nothing to grill included; only the rules' four skip it" do
      body = prose("whiska-spec")

      refute body =~ ~r/tweak or quick fix/i
      refute body =~ ~r/needed no grilling skips it/i
      assert body =~ ~r/straight away when there was nothing to ask/i

      assert body =~
               ~r/a typo, or a comment or doc no program reads; a formatting or lint fix; a test-only change; a brief that spells out the exact change\. Size never skips it/i

      assert body =~
               ~r/hides, drops or skips anything, or touches secrets, access or a security check, is never one of the four/i
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
    test "a link to the spec goes to them as the question, never its text, and the session waits" do
      body = prose("whiska-spec")

      assert body =~ ~r/send a link to the spec to the person as the question/i
      assert body =~ ~r/never paste the spec/i
      refute body =~ ~r/send the whole spec/i
      assert body =~ ~r/build only after they say ok/i
    end

    test "the question is the line `whiska spec-link` prints, then ok to build" do
      body = prose("whiska-spec")

      assert body =~ "`whiska spec-link '<spec title>'`"
      assert body =~ ~S(each `'` in it written `'\''`)
      assert body =~ "`Review spec here: [<spec title>](<link>)`"
      assert body =~ Whiska.Spec.filename()

      assert body =~ ~s("ok to build?")
      refute body =~ "Spec for the review"
    end

    test "only a worktree session ends the question on a marker" do
      assert prose("whiska-spec") =~ ~r/the decision marker a mouse's rules describe/i
    end

    test "any other answer revises the file and sends the link again" do
      assert prose("whiska-spec") =~
               ~r/anything else → change the file to match.{0,80}send the link again/is
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
        "What Changes for Users",
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

    test "what changes for users is required, what disappears included" do
      body = prose("whiska-spec")

      assert body =~ ~r/every behaviour a user or a calling program sees differently/i
      assert body =~ ~r/hidden, dropped, skipped, or turned from an error into silence/i
      assert body =~ ~r/never left out/i
    end

    test "implementation decisions name the alternative passed over, citing the ADR" do
      body = prose("whiska-spec")

      assert body =~ ~r/the alternative passed over/i
      assert body =~ ~r/the adr that governs it/i

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

    # Moved out of a session's rules, since they matter only while grilling
    # (ADR-0081).
    test "a build from a research hand-off takes its findings as fact and still grills the design" do
      assert prose("grilling") =~
               ~r/\*\*proposed build\*\*.{0,40}found as fact.{0,120}still grills? the design/is
    end

    test "a research-only mouse grills the research question only, never design" do
      body = prose("grilling")

      assert body =~
               ~r/only investigates.{0,40}research question only: goal, the decision it feeds, scope, depth, what to deliver/is

      assert body =~ ~r/skip it when the brief already answers those.{0,60}never grill design/is
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
