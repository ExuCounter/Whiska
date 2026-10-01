defmodule Whiska.ClaudeMdGlobalTest do
  @moduledoc """
  The block as `whiska init --global` writes it into `~/.claude/CLAUDE.md`
  (ADR-0056). Same markers, same parts, same `keep` semantics — Claude Code
  loads both files, so the only thing that differs is which copy is in force
  where a repo has one too.
  """
  use ExUnit.Case, async: true

  alias Whiska.ClaudeMd

  describe "render/1" do
    test "uses the same outer and part markers as the per-repo block" do
      global = ClaudeMd.render(:global)

      assert global =~ "<!-- whiska:start -->"
      assert global =~ "<!-- whiska:end -->"

      for %{name: name} <- ClaudeMd.parts(:global) do
        assert global =~ "<!-- whiska:#{name}:start -->"
        assert global =~ "<!-- whiska:#{name}:end -->"
      end
    end

    test "says a project's own copy is the one in force where both are present" do
      global = ClaudeMd.render(:global)

      assert global =~ "whiska init --global"
      assert global =~ ~r/project'?s own/i
      refute ClaudeMd.render(:repo) =~ ~r/project'?s own CLAUDE.md.*in force/s
    end

    test "still says how to claim a part" do
      assert ClaudeMd.render(:global) =~ "keep"
    end

    test "the finish part points at the home copy of the skill file" do
      global = ClaudeMd.render(:global)

      assert global =~ "~/.claude/skills/whiska-finish/SKILL.md"
      assert ClaudeMd.render(:repo) =~ ".claude/skills/whiska-finish/SKILL.md"
    end

    test "the finish part sends the person to the project's own CLAUDE.md for `## Finish`" do
      # What green means is the repo's to say, and `~/.claude/CLAUDE.md` is not
      # the repo's file.
      assert ClaudeMd.render(:global) =~ "project's own `CLAUDE.md`"
      assert ClaudeMd.render(:repo) =~ "in this file"
    end

    test "every other part is word for word the per-repo one" do
      for name <- ~w(worktrees marker delivery report) do
        repo = Enum.find(ClaudeMd.parts(:repo), &(&1.name == name))
        global = Enum.find(ClaudeMd.parts(:global), &(&1.name == name))
        assert repo.body == global.body, "the #{name} part differs between scopes"
      end
    end
  end

  describe "the scope part — the rule that settles a duplicate block" do
    test "the global block carries it and the per-repo block does not" do
      assert Enum.any?(ClaudeMd.parts(:global), &(&1.name == "scope"))
      refute Enum.any?(ClaudeMd.parts(:repo), &(&1.name == "scope"))
    end

    test "it says the project's own copy is the one in force" do
      scope = Enum.find(ClaudeMd.parts(:global), &(&1.name == "scope"))

      assert scope.body =~ ~r/in force/
      assert scope.body =~ "CLAUDE.md"
    end

    test "it comes back after an uninstall that a kept part survived" do
      # The header is not a part, so it is not re-added to a block that already
      # exists — which is why this rule cannot live there.
      kept =
        ClaudeMd.merge("# Mine\n", :global)
        |> String.replace(
          "<!-- whiska:report:start -->",
          "<!-- whiska:report:start keep -->"
        )

      round_trip = kept |> ClaudeMd.remove() |> ClaudeMd.merge(:global)

      assert round_trip =~ "in force"
      assert round_trip =~ "<!-- whiska:scope:start -->"
    end

    test "a per-repo block never gains it" do
      refute ClaudeMd.merge("", :repo) =~ "<!-- whiska:scope:start -->"
    end
  end

  describe "merge/2" do
    test "is idempotent" do
      once = ClaudeMd.merge("", :global)
      assert ClaudeMd.merge(once, :global) == once
    end

    test "keeps what the person's own global CLAUDE.md already says" do
      mine = "# Mine\n\nPlain language, always.\n"
      merged = ClaudeMd.merge(mine, :global)

      assert merged =~ "Plain language, always."
      assert merged =~ "<!-- whiska:start -->"
    end

    test "a part marked keep survives" do
      kept =
        ClaudeMd.merge("", :global)
        |> String.replace(
          "<!-- whiska:marker:start -->",
          "<!-- whiska:marker:start keep -->\nMine now."
        )

      assert ClaudeMd.merge(kept, :global) =~ "Mine now."
    end

    test "rewrites a block an older global init wrote, in place" do
      stale = ClaudeMd.merge("", :global) |> String.replace("## Worktrees", "## Stale heading")
      assert ClaudeMd.merge(stale, :global) =~ "## Worktrees"
      refute ClaudeMd.merge(stale, :global) =~ "## Stale heading"
    end
  end

  describe "remove/1 — what uninstall takes back out" do
    test "leaves a file with no block byte for byte alone" do
      mine = "# Mine\n\nNothing of Whiska's here.\n"
      assert ClaudeMd.remove(mine) == mine
    end

    test "takes the whole block out and leaves the person's text" do
      body = ClaudeMd.merge("# Mine\n\nKeep me.\n", :global) |> ClaudeMd.remove()

      assert body =~ "Keep me."
      refute body =~ "<!-- whiska:start -->"
      refute body =~ "## Worktrees"
    end

    test "a part the person claimed with keep is theirs and stays" do
      kept =
        ClaudeMd.merge("# Mine\n", :global)
        |> String.replace(
          "<!-- whiska:marker:start -->",
          "<!-- whiska:marker:start keep -->\nMine now."
        )

      body = ClaudeMd.remove(kept)

      assert body =~ "Mine now."
      assert body =~ "<!-- whiska:marker:start keep -->"
      refute body =~ "## Worktrees"
      # The outer markers stay, because something of Whiska's shape is still in them.
      assert body =~ "<!-- whiska:start -->"
    end
  end
end
