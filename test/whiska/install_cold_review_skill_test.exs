defmodule Whiska.InstallColdReviewSkillTest do
  use ExUnit.Case, async: true

  alias Whiska.Install

  defp skill do
    assert {_path, body} =
             List.keyfind(Install.skills(), ".claude/skills/cold-review/SKILL.md", 0),
           "cold-review is not installed"

    body
  end

  defp prose, do: skill() |> String.replace(~r/\s+/, " ")

  defp frontmatter do
    assert [_, front] = Regex.run(~r/\A---\n(.*?)\n---\n/s, skill())
    front
  end

  describe "it ships as a skill that runs as its own read-only subagent (ADR-0049)" do
    test "its frontmatter names it, with a quoted description" do
      assert frontmatter() =~ ~r/^name: cold-review$/m
      assert [_] = Regex.run(~r/^description: ".*"$/m, frontmatter())
    end

    test "it forks into the read-only Explore agent, in the foreground" do
      front = frontmatter()

      assert front =~ ~r/^context: fork$/m
      assert front =~ ~r/^agent: Explore$/m
      # ADR-0052 counts only Agent launches, so a background skill is invisible.
      assert front =~ ~r/^background: false$/m
    end

    test "the caller can pass a base and a spec, and nothing else" do
      front = frontmatter()

      assert front =~ ~r/^arguments: \[base, spec\]$/m
      assert front =~ ~r/^argument-hint: "\[base-ref\] \[spec-file\]"$/m
    end

    test "it names no model (ADR-0069)" do
      refute skill() =~ ~r/\b(opus|sonnet|haiku|fable)\b/i
    end
  end

  describe "what the reviewer does" do
    test "it reads the decisions as they stood at the base, never from the branch" do
      body = prose()

      assert body =~ "git show <base>:<path>"
      assert body =~ ~r/anything the builder wrote.{0,200}is a \*\*claim\*\*/i
    end

    test "it finds its own base and the whole change, uncommitted and untracked included" do
      body = prose()

      assert body =~ ~s(git merge-base --is-ancestor "$base" HEAD)
      assert body =~ ~r/does not start with `-`/
      assert body =~ "git ls-files --others --exclude-standard"
      assert body =~ "`.whiska-mouse`"
      assert body =~ "`#{Whiska.Spec.filename()}`"
      assert body =~ "`#{Whiska.Research.filename()}`"
    end

    test "it holds every behaviour change against the spec, and with none every one is a finding" do
      body = prose()

      assert body =~ ~r/what does it change that a user or a calling program sees/i

      assert body =~
               ~r/or for a bug the research document's after and the option picked\. One neither approves is a finding; with neither, every one is/i
    end

    # The person approves a build plan before the build, but the review holds
    # the diff against what they wanted, never against how the builder chose to
    # build it (ADR-0049).
    test "it never reads the build plan, here or kept" do
      body = prose()

      assert body =~ "`#{Whiska.BuildPlan.filename()}`"
      assert body =~ ~r/never read it, nor any `\.plan\.md` kept beside a spec/i
    end

    test "a bug fix is held against its research document's before and after and the option picked" do
      body = prose()

      assert body =~
               ~r/`#{Regex.escape(Whiska.Research.filename())}` at the repo root.{0,80}a bug/is

      assert body =~ ~r/before and after.{0,40}picked/is
    end

    test "no base found ends the review at its header" do
      assert prose() =~ ~r/no base found.{0,80}header/i
    end

    test "its report opens on a fixed first line a later reader can find" do
      assert skill() =~ "Cold review · base <short sha>"
    end
  end
end
