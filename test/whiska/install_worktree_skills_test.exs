defmodule Whiska.InstallWorktreeSkillsTest do
  use ExUnit.Case, async: true

  alias Whiska.Install

  @worktree_skills ~w(spawn-worktree send-to-worktree drop-worktree)

  defp skill(name) do
    assert {_path, body} =
             List.keyfind(Install.skills(), ".claude/skills/#{name}/SKILL.md", 0),
           "#{name} is not installed"

    body
  end

  describe "the three worktree skills ship with Whiska (ADR-0046)" do
    test "init installs all three, beside the reading skills" do
      installed =
        Enum.map(Install.skills(), fn {path, _} -> Path.basename(Path.dirname(path)) end)

      for name <- @worktree_skills, do: assert(name in installed, name)
      # The ones that were already there are untouched by this.
      for name <- ~w(whiska-questions whiska-delivered), do: assert(name in installed, name)
    end

    test "each has frontmatter naming itself, with a quoted description" do
      for name <- @worktree_skills do
        body = skill(name)
        assert body =~ "name: #{name}"
        # Quoted on purpose: an unquoted " #" starts a YAML comment and the
        # listing the model sees is cut off there.
        assert [_] = Regex.run(~r/^description: ".*"$/m, body), name
      end
    end

    test "each refuses outside a herdr session rather than falling back" do
      for name <- @worktree_skills do
        assert skill(name) =~ "HERDR_ENV", name
      end
    end
  end

  describe "spawn-worktree" do
    test "lays the worktree out where Whiska expects to find it (ADR-0030)" do
      body = skill("spawn-worktree")

      assert body =~ "--path worktrees/"
      assert body =~ "ADR-0030"
      assert body =~ "Whiska.Layout"
    end

    test "runs herdr worktree create from the repo root" do
      body = skill("spawn-worktree")

      # `herdr worktree create` picks the repo from the calling directory, not
      # from --workspace, so a skill run from anywhere else makes the worktree
      # in the wrong repo.
      assert body =~ ~r/repo root/i
      assert body =~ "git rev-parse --show-toplevel"
      assert body =~ "herdr worktree create"
    end

    test "starts the mouse and hands it the task, without stealing focus" do
      body = skill("spawn-worktree")

      assert body =~ "--no-focus"
      assert body =~ "herdr agent start"
      assert body =~ "herdr agent prompt"
    end

    test "carries the hooks in before Claude starts, so the Stop hook exists" do
      body = skill("spawn-worktree")

      assert body =~ ".claude/hooks/whiska.sh"
      assert body =~ "doorstep"
      refute body =~ "settings.local.json cp"
    end

    test "shapes the mouse before Claude starts, and stops if it cannot (ADR-0069)" do
      body = skill("spawn-worktree")

      # The order is the whole point: a shape recorded after Claude starts
      # gives a sniff mouse its first tool calls as a build mouse.
      {shape_at, _} = :binary.match(body, "whiska shape <build|sniff>")
      {start_at, _} = :binary.match(body, "herdr agent start <agent-name>")
      assert shape_at < start_at

      assert body =~ ~s(-- --model "$model")

      # One fenced block: a shell variable does not survive between two Bash
      # calls, so a shape in one block and a start in the next starts every
      # mouse on the default model.
      [block] =
        Regex.scan(~r/```bash\n(.*?)```/s, body, capture: :all_but_first)
        |> List.flatten()
        |> Enum.filter(&(&1 =~ "whiska shape"))

      assert block =~ "herdr agent start"
      assert body =~ "do not start Claude by hand"
      # The report carries Whiska's own line, not the skill's intent.
      assert body =~ "word for word"
    end

    test "carries the hooks and settings only, never the skills" do
      # A mouse speaks through its Stop hook; the skills are main-session
      # tools, and the person's own skills are read from ~/.claude/skills in
      # every directory. Copying 30 folders per worktree bought nothing.
      body = skill("spawn-worktree")

      refute body =~ "cp -R .claude/skills"
      assert body =~ "never `.claude/skills`"
      assert body =~ "~/.claude/skills"
    end
  end

  describe "send-to-worktree" do
    test "routes into a running mouse instead of spawning a second one" do
      body = skill("send-to-worktree")

      assert body =~ "herdr worktree list"
      assert body =~ "herdr agent prompt"
      assert body =~ "spawn-worktree"
      # Never blocks the person's own session.
      assert body =~ "--wait"
      assert body =~ ~r/must return immediately/
    end
  end

  describe "drop-worktree" do
    test "takes down the worktree and its workspace together, and checks first" do
      body = skill("drop-worktree")

      assert body =~ "herdr worktree remove"
      assert body =~ "status --porcelain"
      assert body =~ "git branch -D"
    end
  end

  describe "all three point the person back at Whiska, not at the pane" do
    test "spawn and send say the question arrives through Whiska" do
      for name <- ~w(spawn-worktree send-to-worktree) do
        body = skill(name)
        assert body =~ "whiska questions <id>", name
        assert body =~ "herdr pane read", name
        assert body =~ "alternate screen", name
      end
    end
  end

  describe "the long skills are build inputs under priv/ (ADR-0046)" do
    @committed_skills @worktree_skills ++ ~w(whiska-finish)

    test "each is read from priv/skills/, not from this repo's own .claude/" do
      for name <- @committed_skills do
        source = "priv/skills/#{name}/SKILL.md"
        assert File.exists?(source), "#{name} is not under priv/skills/"
        assert skill(name) == File.read!(source), name
      end

      refute File.exists?(".claude/skills"),
             "the shipped skills no longer live in this repo's own .claude/"
    end
  end
end
