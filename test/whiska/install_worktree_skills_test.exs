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

  defp start_block do
    [block] =
      Regex.scan(~r/```bash\n(.*?)```/s, skill("spawn-worktree"), capture: :all_but_first)
      |> List.flatten()
      |> Enum.filter(&(&1 =~ "whiska shape <build|sniff>"))

    block
  end

  defp base_argv, do: ~w(agent start feat-x --kind claude --pane w1:p1 --timeout 15000)

  # The skill's own block, with its placeholders filled in, run against a
  # `whiska` that prints `printed` and exits `status`, and a `herdr` that writes
  # down the arguments it was started with. nil when herdr never ran.
  defp run_start_block(shell, {status, printed}) do
    dir = Path.join(System.tmp_dir!(), "whiska-spawn-#{System.unique_integer([:positive])}")
    bin = Path.join(dir, "bin")
    argv_file = Path.join(dir, "argv")
    File.mkdir_p!(bin)
    File.mkdir_p!(Path.join(dir, "worktrees/feat-x"))
    on_exit(fn -> File.rm_rf!(dir) end)

    stand_in(bin, "whiska", ~s(printf '%s\\n' "$WHISKA_OUT"\nexit "$WHISKA_STATUS"))
    stand_in(bin, "herdr", ~s(printf '%s\\n' "$@" > "$ARGV_FILE"))

    script =
      start_block()
      |> String.replace("<branch-name>", "feat-x")
      |> String.replace("<agent-name>", "feat-x")
      |> String.replace("<root-pane-id>", "w1:p1")
      |> String.replace("<build|sniff>", "sniff")
      |> String.replace(~r/<[^>\n]+>/, "")

    {_out, code} =
      System.cmd(shell, ["-c", script],
        cd: dir,
        stderr_to_stdout: true,
        env: [
          {"PATH", bin <> ":" <> System.get_env("PATH")},
          {"WHISKA_OUT", printed},
          {"WHISKA_STATUS", Integer.to_string(status)},
          {"ARGV_FILE", argv_file}
        ]
      )

    argv =
      if File.exists?(argv_file), do: argv_file |> File.read!() |> String.split("\n", trim: true)

    {argv, code}
  end

  defp stand_in(bin, name, body) do
    path = Path.join(bin, name)
    File.write!(path, "#!/bin/sh\n#{body}\n")
    File.chmod!(path, 0o755)
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

      # One fenced block: a shell variable does not survive between two Bash
      # calls, so a shape in one block and a start in the next starts every
      # mouse on the default model.
      assert start_block() =~ "herdr agent start"
      assert body =~ "do not start Claude by hand"
      # The report carries what Whiska's own line says, not the skill's intent,
      # and in plain words: "sniff mouse" is not the person's phrase.
      assert body =~ "Restate that line, not what this skill meant to set"
      refute body =~ "a mouse is working on it"
    end

    test "reads the modes and the rules out of priv/models.json, never restating them" do
      body = skill("spawn-worktree")
      rules = "priv/models.json" |> File.read!() |> JSON.decode!()

      assert body =~ "whiska shape --rules"
      assert body =~ "--effort"

      written_once =
        Map.values(rules["modes"]) ++
          Enum.map(rules["model"]["choose"] ++ rules["effort"]["choose"], & &1["when"])

      for text <- written_once, text != "anything else" do
        refute body =~ text, "the skill restates #{inspect(text)}; it belongs in priv/models.json"
      end
    end

    for shell <- ~w(bash zsh), System.find_executable(shell) do
      @tag shell: shell
      test "#{shell} starts Claude on exactly the words whiska shape printed", %{shell: shell} do
        line = "--model m1 --effort xhigh --fallback-model m2,m3"
        {argv, status} = run_start_block(shell, {0, line})

        assert status == 0
        assert argv == base_argv() ++ ["--"] ++ String.split(line)
      end

      @tag shell: shell
      test "#{shell} starts Claude with no flags at all when it printed nothing", %{
        shell: shell
      } do
        {argv, 0} = run_start_block(shell, {0, ""})
        assert argv == base_argv()
      end

      @tag shell: shell
      test "#{shell} does not start Claude on anything but plain words", %{shell: shell} do
        for printed <- ["/a/path/from/cd --model m1", "$(touch pwned)", "m1;reboot", "`id`"] do
          {argv, status} = run_start_block(shell, {0, printed})

          assert status != 0, printed
          assert argv == nil, printed
        end
      end

      @tag shell: shell
      test "#{shell} does not start Claude when whiska shape fails", %{shell: shell} do
        {argv, status} = run_start_block(shell, {1, ""})

        assert status != 0
        assert argv == nil
      end
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

      assert tracked_skill_files() == [],
             "the shipped skills no longer live in this repo's own .claude/"
    end

    # What ADR-0046 forbids is a second *committed* copy, which is the one that
    # can drift from `priv/` and the one a build would read. `whiska init` in
    # this checkout writes an untracked `.claude/skills/` as its output — this
    # repo runs on the block it ships — and that copy is nobody's source.
    defp tracked_skill_files do
      case System.cmd("git", ["ls-files", "--", ".claude/skills"], stderr_to_stdout: true) do
        {out, 0} -> String.split(out, "\n", trim: true)
        {_out, _code} -> []
      end
    end
  end
end
