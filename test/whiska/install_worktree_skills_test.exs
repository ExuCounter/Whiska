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

  defp section(title) do
    heading = ~r/^## (\d+\. )?#{Regex.escape(title)}\n.*?(?=\n## )/ms
    assert [section | _] = Regex.run(heading, skill("spawn-worktree")), "no section #{title}"
    section
  end

  defp hand_off_section, do: section("Building what an investigation proposed")

  defp prose(text), do: String.replace(text, ~r/\s+/, " ")

  defp heading_at(title) do
    heading = ~r/^## \d+\. #{Regex.escape(title)}$/m
    assert [{at, _}] = Regex.run(heading, skill("spawn-worktree"), return: :index), title
    at
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

  describe "the three worktree skills ship with Whiska (ADR-0056)" do
    test "init installs all three, beside the reading skills" do
      installed =
        Enum.map(Install.skills(), fn {path, _} -> Path.basename(Path.dirname(path)) end)

      for name <- @worktree_skills, do: assert(name in installed, name)
      # The ones that were already there are untouched by this.
      for name <- ~w(show whiska-delivered), do: assert(name in installed, name)
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
      assert body =~ "Whiska.Layout"
      assert String.replace(body, ~r/\s+/, " ") =~ "Changing it means changing Whiska"
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

    # The person said yes to the proposal; the branch name, the model and the
    # effort are derived and shown, never asked (ADR-0074).
    test "builds what an investigation proposed without asking anything more" do
      body = skill("spawn-worktree")
      prose = String.replace(body, ~r/\s+/, " ")

      assert body =~ "## Building what an investigation proposed"
      assert prose =~ ~r/ask the person nothing/i
      # Shaped against the proposal, not the request the investigation began from.
      assert prose =~ ~r/judged against the Build and Touches lines/i
      # The report travels by its id: it is already in Whiska, whole.
      assert body =~ "whiska show <id>"
      refute body =~ "whiska questions"
      # Shown in one line.
      assert prose =~ ~r/one line/i
    end

    # A mouse wrote the proposal, and the main session's shell runs both the
    # branch name and the prompt line: no character of the proposal goes in.
    test "puts nothing a mouse wrote on the main session's command line" do
      section = hand_off_section()

      [prompt] = Regex.run(~r/^\s*herdr agent prompt .*$/m, section)
      filled_in = ~r/<[^>]+>/ |> Regex.scan(prompt) |> List.flatten() |> Enum.uniq()
      assert filled_in == ["<root-pane-id>", "<id>"]

      assert section =~ "a-z0-9"
      assert prose(section) =~ ~r/never copied from the proposal/i
    end

    test "chooses the shape before naming the branch" do
      assert heading_at("Choose the mouse's shape") < heading_at("The branch name")
    end

    # A sniff branch never leaves this machine; a build branch is pushed beside
    # other people's, so it reads like theirs.
    test "names a sniff branch research/ and a build branch by its commit type" do
      branch = prose(section("The branch name"))

      assert branch =~ ~r/\*\*sniff\*\* → `research\/<slug>`/

      assert branch =~
               ~r/\*\*build\*\* → `<type>\/<slug>`, with the type its commit message would carry/

      assert branch =~ ~r/a branch rule the repo writes down .* wins over the build default/i
      assert branch =~ "A sniff branch is `research/` whatever that rule says"
      refute prose(skill("spawn-worktree")) =~ ~r/recent branches/i
    end

    test "uses a branch name the person gives whole, as given" do
      assert prose(section("The branch name")) =~ ~r/a name the person gives whole is used as/i
    end

    # The name goes onto shell command lines unquoted, and a repo's written
    # rule is text from outside this session.
    test "keeps a branch name to characters the shell does not act on, whatever the repo's rule" do
      branch = prose(section("The branch name"))

      assert branch =~ "`a-z`, `A-Z`, `0-9`, `-`, `_` and `/` only"
      assert branch =~ ~r/never a character outside that set/i
      assert prose(skill("spawn-worktree")) =~ ~r/agent-name.*lowercased/
    end

    # The rules may judge a proposal's work as sniff, and the branch follows
    # the mode.
    test "shapes a build from a proposal before naming its branch" do
      hand_off = prose(hand_off_section())
      {shape_at, _} = :binary.match(hand_off, "**Shape**")
      {branch_at, _} = :binary.match(hand_off, "**Branch**")

      assert shape_at < branch_at
      assert hand_off =~ "`<type>/<slug>`, or the rule the repo writes down"
      assert hand_off =~ ~r/whatever the repo's rule says/i
    end

    test "the proposal hand-off cites the steps it means" do
      hand_off = hand_off_section()
      cited = fn pattern -> Regex.run(pattern, hand_off, capture: :all_but_first) end

      [shape_step] = cited.(~r/chosen as in step (\d+)/)
      [branch_step] = cited.(~r/named by step (\d+)'s/)
      [report_step] = cited.(~r/in place of step (\d+)'s/)

      assert skill("spawn-worktree") =~ "## #{shape_step}. Choose the mouse's shape"
      assert skill("spawn-worktree") =~ "## #{branch_step}. The branch name"
      assert skill("spawn-worktree") =~ "## #{report_step}. Report"
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
      {create_at, _} = :binary.match(body, "herdr worktree create \\")
      {shape_at, _} = :binary.match(body, "whiska shape <build|sniff>")
      {start_at, _} = :binary.match(body, "herdr agent start <agent-name>")
      assert create_at < shape_at
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

      assert body =~ "whiska worktrees"
      assert body =~ "herdr agent prompt"
      assert body =~ "spawn-worktree"
      # Never blocks the person's own session.
      assert body =~ "--wait"
      assert body =~ ~r/must return immediately/
    end
  end

  describe "the skills need no jq" do
    test "none of them pipes through it" do
      for name <- @worktree_skills, do: refute(skill(name) =~ "jq")
    end
  end

  describe "drop-worktree" do
    test "takes down the worktree and its workspace together, and checks first" do
      body = skill("drop-worktree")

      assert body =~ "whiska worktrees"
      assert body =~ "herdr worktree remove"
      assert body =~ "status --porcelain"
      assert body =~ "git branch -D"
    end
  end

  describe "all three point the person back at Whiska, not at the pane" do
    test "spawn and send say the question arrives through Whiska" do
      for name <- ~w(spawn-worktree send-to-worktree) do
        body = skill(name)
        assert body =~ "whiska show <id>", name
        refute body =~ "whiska questions", name
        assert body =~ "herdr pane read", name
        assert body =~ "alternate screen", name
      end
    end
  end

  describe "the long skills are build inputs under priv/ (ADR-0056)" do
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

    # What ADR-0056 forbids is a second *committed* copy, which is the one that
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
