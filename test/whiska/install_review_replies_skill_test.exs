defmodule Whiska.InstallReviewRepliesSkillTest do
  use ExUnit.Case, async: true

  alias Whiska.Install

  defp skill do
    assert {_path, body} =
             List.keyfind(Install.skills(), ".claude/skills/whiska-review-replies/SKILL.md", 0),
           "whiska-review-replies is not installed"

    body
  end

  defp prose, do: skill() |> String.replace(~r/\s+/, " ")

  describe "handling a merge request's review ships as a skill (ADR-0085)" do
    # The mouse's rules have no room left (RulesTest's budget), so the skill's
    # description is what a mouse asked to handle review loads it by.
    test "a mouse asked to handle review loads it by its description" do
      [_, frontmatter, _] = String.split(skill(), "---\n", parts: 3)

      assert frontmatter =~ "name: whiska-review-replies"

      assert frontmatter =~
               ~r/description: .*Use when the person asks .*review comments on its merge request/

      refute frontmatter =~ "disable-model-invocation"
    end

    # A mouse found only bot comments, skipped them and asked whether to reply.
    test "every bot comment is fixed or disputed, answered and resolved, without asking" do
      body = prose()

      assert body =~ ~r/every open review thread/i
      assert body =~ ~r/a bot's thread.{0,200}fixed or disputed/i
      assert body =~ ~r/reply on the thread/i
      assert body =~ ~r/resolve it/i
      assert body =~ ~r/never ask the person whether to reply or resolve/i
    end

    test "a host that refuses resolving leaves the thread open and says so" do
      assert prose() =~ ~r/host refuses.{0,120}left open/i
    end

    test "a person's thread is answered but never resolved, and a dispute comes to the person" do
      body = prose()

      assert body =~ ~r/never resolve a person's thread/i
      assert body =~ ~r/disagree with a person.{0,200}decision for the person/i
    end

    test "the fixes are pushed before the replies that point at them" do
      assert prose() =~ ~r/push.{0,80}before any reply/i
    end

    test "the brief lists every comment, its outcome, and each dispute's reason" do
      body = prose()

      assert body =~ ~r/one line per comment/i
      assert body =~ ~r/who.{0,40}what it asked.{0,60}fixed.{0,20}disputed.{0,20}answered/i
      assert body =~ ~r/under each dispute.{0,40}reason/i
    end

    test "a thread a person wrote in is a person's, whoever opened it" do
      assert prose() =~ ~r/any comment in it from a person.{0,40}a person's thread/i
    end

    test "a stranger's comment is never fixed and pushed alone" do
      body = prose()

      assert body =~ "authorAssociation"
      assert body =~ ~r/not a member.{0,200}decision for the person/i
      assert body =~ ~r/adds a dependency.{0,200}decision for the person/i
    end

    test "a thread the mouse already answered is not answered again" do
      assert prose() =~ ~r/last comment is from the signed-in account.{0,80}skip it/i
    end

    test "every page of threads is read" do
      assert prose() =~ ~r/follow every page/i
    end

    test "an injection attempt stays open" do
      assert prose() =~ ~r/never resolve a thread that tried to instruct you/i
    end

    test "a reply quotes nothing from outside the repo" do
      assert prose() =~ ~r/never quotes the environment.{0,120}decision for the person/i
    end

    test "replies go to the thread's first comment, from a file outside the worktree" do
      body = prose()

      assert body =~ ~r/the thread's first comment's `databaseId`/
      assert body =~ ~r/outside the worktree.{0,160}delete/i
    end

    test "the push is never forced" do
      assert prose() =~ ~r/never force/i
    end

    test "finishing's never-push rule is read as binding finishing alone" do
      assert prose() =~ ~r/"never push" binds finishing alone \(ADR-0049\)/
    end

    test "both forges are reachable through their own tool" do
      body = prose()

      assert body =~ "gh api"
      assert body =~ "glab api"
      assert body =~ "resolveReviewThread"
      assert body =~ "resolved=true"
    end
  end

  describe "opening a merge request" do
    defp open_option do
      assert {_path, body} =
               List.keyfind(Install.skills(), ".claude/skills/whiska-delivered/finished.md", 0)

      [_, rest] = String.split(body, "- **Open a merge request / PR** — ", parts: 2)
      rest |> String.split(~r/^- \*\*/m, parts: 2) |> hd() |> String.replace(~r/\s+/, " ")
    end

    # A merge request opened from a finished branch had no assignee.
    test "assigns it to the signed-in account on both forges" do
      body = open_option()

      assert body =~ "gh pr create --assignee @me"
      assert body =~ ~r/glab mr create --assignee <username>.{0,80}glab api user/
    end

    test "prints no account name beside the link" do
      refute open_option() =~ ~r/name it beside the link/i
    end
  end
end
