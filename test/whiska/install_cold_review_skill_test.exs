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
    end

    test "no base found ends the review at its header" do
      assert prose() =~ ~r/no base found.{0,80}header/i
    end

    test "its report opens on a fixed first line a later reader can find" do
      assert skill() =~ "Cold review · base <short sha>"
    end
  end
end
