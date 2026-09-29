defmodule Whiska.InstallStatuslineTest do
  @moduledoc """
  What `whiska init` adds for questions: the project statusline (ADR-0027) and
  the `/whiska-questions` slash-command skill (ADR-0022).
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Whiska.CLI
  alias Whiska.Install

  setup do
    root = Path.join(System.tmp_dir!(), "whiska-inst-#{System.unique_integer([:positive])}")
    main = Path.join(root, "myrepo")
    File.mkdir_p!(Path.join(main, ".git"))
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, main: main}
  end

  describe "merge/1 — the statusLine entry" do
    test "adds a project statusLine that runs the checked-in script" do
      merged = Install.merge(%{})

      assert %{"type" => "command", "command" => command} = merged["statusLine"]
      assert command =~ Install.statusline_path()
      refute command =~ System.user_home!()
    end

    test "leaves a statusLine that is not ours alone" do
      mine = %{"type" => "command", "command" => "bash mine.sh"}
      assert Install.merge(%{"statusLine" => mine})["statusLine"] == mine
    end

    test "replaces an older one of ours" do
      old = %{
        "type" => "command",
        "command" => "bash \"$CLAUDE_PROJECT_DIR/#{Install.statusline_path()}\" old"
      }

      assert Install.merge(%{"statusLine" => old})["statusLine"] ==
               Install.merge(%{})["statusLine"]
    end

    test "sets refreshInterval, so the line redraws while the session sits idle (ADR-0044)" do
      assert Install.merge(%{})["statusLine"]["refreshInterval"] ==
               Install.statusline_refresh_interval()
    end

    test "an interval Claude Code accepts, and long enough not to burn a core" do
      interval = Install.statusline_refresh_interval()
      assert is_integer(interval) and interval >= 1
      assert interval >= 10
    end

    test "an earlier init of ours, written before the interval existed, gains it" do
      without = %{"type" => "command", "command" => Install.statusline_command()}

      assert Install.merge(%{"statusLine" => without})["statusLine"]["refreshInterval"] ==
               Install.statusline_refresh_interval()
    end

    test "somebody else's statusLine keeps its own interval, or its absence" do
      mine = %{"type" => "command", "command" => "bash mine.sh"}
      refute Map.has_key?(Install.merge(%{"statusLine" => mine})["statusLine"], "refreshInterval")
    end
  end

  describe "statusline_script/0" do
    test "runs the global statusline first and appends to it (ADR-0027)" do
      script = Install.statusline_script()

      assert script =~ ~r/\A#!/
      assert script =~ "statusLine.command"
      assert script =~ "whiska"
      assert script =~ "statusline"
    end

    test "resolves the binary and runtime exactly as the hook shim does" do
      # Written once: the shim's resolution block is the statusline's too.
      assert Install.statusline_script() =~ "WHISKA_BIN"
      assert Install.statusline_script() =~ "command -v escript"
    end

    test "never recurses into itself if the global statusline is this script" do
      assert Install.statusline_script() =~ Path.basename(Install.statusline_path())
    end

    test "its header says the owl's state is always shown (ADR-0027 addendum)" do
      script = Install.statusline_script()
      assert script =~ "watching"
      assert script =~ "how many whiskas"
      refute script =~ "Nothing is appended when nothing waits"
    end

    test "the committed script in this repo is what init writes today" do
      assert File.read!(Install.statusline_path()) == Install.statusline_script()
    end
  end

  describe "skills/0 — one slash command per command (ADR-0022)" do
    test "installs /whiska-questions as a thin wrapper around the fixed command" do
      assert {path, body} =
               List.keyfind(Install.skills(), ".claude/skills/whiska-questions/SKILL.md", 0)

      assert path =~ "whiska-questions"
      assert body =~ "name: whiska-questions"
      assert body =~ "whiska questions"
    end

    test "/whiska-questions reads everything in full with no argument, one by id with one" do
      assert {_path, body} =
               List.keyfind(Install.skills(), ".claude/skills/whiska-questions/SKILL.md", 0)

      assert body =~ "whiska questions --full"
      assert body =~ "$ARGUMENTS"
      assert body =~ "whiska questions $ARGUMENTS"
      # Still a thin wrapper of fixed commands (ADR-0022), still never answering
      # on the person's behalf (ADR-0017).
      assert body =~ ~r/never reply/
      refute body =~ "summarise"
    end

    test "both reading skills say the person cannot see the command's output, so it goes verbatim in the reply" do
      # Claude Code folds a Bash tool's result away from the person; "show its
      # output" alone got read as "it is already visible" and the model summarised.
      for path <- [
            ".claude/skills/whiska-questions/SKILL.md",
            ".claude/skills/whiska-delivered/SKILL.md"
          ] do
        assert {_path, body} = List.keyfind(Install.skills(), path, 0)
        assert body =~ "cannot see", path
        assert body =~ "verbatim", path
        # A fenced block is what turns rendering off: the person saw `**sent**`
        # and backticks instead of bold and code. The reply is the message as
        # markdown, so it renders the way the mouse wrote it.
        assert body =~ "as markdown", path
        assert body =~ "no fence", path
        refute body =~ "fenced code block", path
      end
    end

    test "whiska-delivered points at --full for the ones behind the delivered line" do
      assert {_path, body} =
               List.keyfind(Install.skills(), ".claude/skills/whiska-delivered/SKILL.md", 0)

      assert body =~ "more open"
      assert body =~ "whiska questions --full"
    end

    test "installs whiska-delivered, which reads a delivered line's question by its id" do
      assert {path, body} =
               List.keyfind(Install.skills(), ".claude/skills/whiska-delivered/SKILL.md", 0)

      assert path =~ "whiska-delivered"
      assert body =~ "name: whiska-delivered"
      # Chosen by description, never by a slash command: nobody types one for a
      # line the owl typed. So the description names the line's shape. It must
      # be a quoted YAML string: unquoted, " #" starts a comment and the
      # listing shown to the model ends there, before every example.
      assert [description] = Regex.run(~r/^description: "(.*)"$/m, body, capture: :all_but_first)
      assert description =~ "🐱"
      assert description =~ ~s(#12)
      assert body =~ "whiska questions <id>"
      assert body =~ ~r/never reply\s+to a question/
    end

    test "a delivered message that ends in lettered options is offered as a picker" do
      assert {_path, body} =
               List.keyfind(Install.skills(), ".claude/skills/whiska-delivered/SKILL.md", 0)

      # The person asked for the pick to look like Claude Code's own picker
      # rather than a letter they have to type back.
      assert body =~ "AskUserQuestion"
      assert body =~ "(Recommended)"
      # Still the fixed command (ADR-0022), still the person's answer (ADR-0017):
      # the pick is theirs, the model only writes it into the reply.
      assert body =~ ~r/whiska reply <id>/
      assert body =~ "Other"
    end

    test "the picker is skipped when there is nothing to pick, or too much" do
      assert {_path, body} =
               List.keyfind(Install.skills(), ".claude/skills/whiska-delivered/SKILL.md", 0)

      # AskUserQuestion takes at most four options; beyond that the skill asks
      # in prose instead of silently dropping some.
      assert body =~ ~r/4 or fewer/
      assert body =~ ~r/More than 4/
      # No options and a "finished" line both behave exactly as before.
      assert body =~ ~r/No options/
      assert body =~ "finished"
    end

    test "/whiska-questions offers the same picker when it read one question by id" do
      assert {_path, body} =
               List.keyfind(Install.skills(), ".claude/skills/whiska-questions/SKILL.md", 0)

      assert body =~ "AskUserQuestion"
      assert body =~ ~r/whiska reply/
      # --full is a list of several; a single picker cannot stand for all of them.
      assert body =~ "--full"
    end

    test "the committed skills in this repo are what init writes today" do
      for {path, body} <- Install.skills() do
        assert File.read!(path) == body, "#{path} is stale: run whiska init and commit"
      end
    end
  end

  describe "whiska init writes them" do
    test "the statusline script, executable, and the skill", %{main: main} do
      capture_io(fn -> assert CLI.run(["init"], main) == 0 end)

      script = Path.join(main, Install.statusline_path())
      assert File.read!(script) == Install.statusline_script()
      assert Bitwise.band(File.stat!(script).mode, 0o100) != 0

      for {path, body} <- Install.skills() do
        assert File.read!(Path.join(main, path)) == body
      end

      settings = JSON.decode!(File.read!(Path.join(main, ".claude/settings.json")))
      assert settings["statusLine"]["command"] =~ Install.statusline_path()
    end

    test "the shim itself is unchanged by this", %{main: main} do
      capture_io(fn -> assert CLI.run(["init"], main) == 0 end)
      assert File.read!(Path.join(main, Install.shim_path())) == Install.shim()
      assert Install.shim() =~ ~s(hook "$@")
    end
  end
end
