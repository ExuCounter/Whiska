defmodule Whiska.InstallStatuslineTest do
  @moduledoc """
  What `whiska init` writes for questions: the project statusline (ADR-0027,
  ADR-0044) and the `/whiska-questions` slash-command skill (ADR-0022).

  The statusline is repo-scoped — this house's questions, this repo's mice. The
  owl's state and the cross-repo view are herdr's tab bar's, and the script and
  config entry for that are here too (ADR-0048).
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Whiska.CLI
  alias Whiska.Install

  setup do
    root = Path.join(System.tmp_dir!(), "whiska-inst-#{System.unique_integer([:positive])}")
    main = Path.join(root, "myrepo")
    home = Path.join(root, "dot-whiska")
    File.mkdir_p!(Path.join(main, ".git"))
    previous = Application.get_env(:whiska, :home)
    Application.put_env(:whiska, :home, home)

    on_exit(fn ->
      Application.put_env(:whiska, :home, previous)
      File.rm_rf!(root)
    end)

    {:ok, main: main, home: home}
  end

  describe "merge/1 — the statusLine entry (ADR-0027)" do
    test "sets ours, with the refresh interval beside it (ADR-0044)" do
      entry = Install.merge(%{})["statusLine"]

      assert entry["type"] == "command"
      assert entry["command"] == Install.statusline_command()
      assert entry["command"] =~ Install.statusline_path()
      assert entry["refreshInterval"] == Install.statusline_refresh_interval()
    end

    test "replaces one of ours wholesale, interval included" do
      old = %{
        "type" => "command",
        "command" => "bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/whiska-statusline.sh\""
      }

      assert Install.merge(%{"statusLine" => old})["statusLine"] ==
               Install.merge(%{})["statusLine"]
    end

    test "leaves a statusLine that is not ours exactly alone" do
      mine = %{"type" => "command", "command" => "bash mine.sh"}
      assert Install.merge(%{"statusLine" => mine})["statusLine"] == mine
    end

    test "a statusLine of a shape we do not recognise is left alone too" do
      for theirs <- ["bash mine.sh", %{"type" => "command"}, %{"command" => nil}] do
        assert Install.merge(%{"statusLine" => theirs})["statusLine"] == theirs
      end
    end

    test "an interval the person changed is theirs no longer, init restores its own" do
      ours = %{
        "type" => "command",
        "command" => Install.statusline_command(),
        "refreshInterval" => 90
      }

      assert Install.merge(%{"statusLine" => ours})["statusLine"]["refreshInterval"] ==
               Install.statusline_refresh_interval()
    end
  end

  describe "statusline_script/0 — what the Claude statusline runs (ADR-0027)" do
    test "runs the person's global statusline first and appends to its output" do
      script = Install.statusline_script()

      assert script =~ ~r/\A#!/
      assert script =~ "statusLine.command"
    end

    test "prints the board the owl left rather than asking for one (ADR-0051)" do
      script = Install.statusline_script()

      assert script =~ "board"
      refute script =~ "statusline --here"
    end

    test "looks up the board for the directory the session is in" do
      script = Install.statusline_script()

      assert script =~ "workspace.current_dir"
      assert script =~ ~s(probe="$dir")
    end

    test "the settings.json command names only the script, under the project dir" do
      assert Install.statusline_command() =~ "CLAUDE_PROJECT_DIR"
      assert Install.statusline_command() =~ Install.statusline_path()
    end

    test "starts nothing, which is what a two-second refresh costs nothing" do
      script = Install.statusline_script()

      refute script =~ "WHISKA_BIN"
      refute script =~ "escript"
    end

    test "an interval Claude Code accepts" do
      assert Install.statusline_refresh_interval() >= 1
    end
  end

  describe "herdr_status_script/0 — what herdr's tab bar runs (ADR-0048)" do
    test "prints the machine-wide line and nothing else" do
      script = Install.herdr_status_script()

      assert script =~ ~r/\A#!/
      assert script =~ "whiska"
      assert script =~ "statusline"
      # No repo to be in: herdr draws one line for the whole session.
      refute script =~ "CLAUDE_PROJECT_DIR"
      refute script =~ "statusLine.command"
      refute script =~ "--here"
    end

    test "resolves the binary and runtime exactly as the hook shim does" do
      assert Install.herdr_status_script() =~ "WHISKA_BIN"
      assert Install.herdr_status_script() =~ "command -v escript"
    end

    test "tells a crashed Whiska apart from a missing one" do
      script = Install.herdr_status_script()

      assert script =~ "whiska missing"
      assert script =~ "whiska error"
    end

    test "says so when it cannot find Whiska, rather than going blank" do
      # herdr clears the entry on empty output or failure, which is
      # indistinguishable from nothing being configured — and the owl's state
      # is the one thing that must always be shown (ADR-0027 addendum).
      assert Install.herdr_status_script() =~ "whiska missing"
    end

    test "lives in the whiska home, not in any repo" do
      assert Install.herdr_status_path() == Path.join(Whiska.OpenHouses.home(), "herdr-status.sh")
    end
  end

  describe "tab_bar_right_snippet/0 — what the person commits in dotfiles" do
    test "is the herdr config entry that draws the line, naming the shipped script" do
      snippet = Install.tab_bar_right_snippet()

      assert snippet =~ "[ui]"
      assert snippet =~ "tab_bar_right"
      assert snippet =~ ~s(type = "command")
      assert snippet =~ Install.herdr_status_path()
      assert snippet =~ "interval_seconds = #{Install.herdr_status_interval()}"
      assert snippet =~ "timeout_seconds = #{Install.herdr_status_timeout()}"
    end

    test "an interval and timeout herdr accepts" do
      assert Install.herdr_status_interval() in 1..31_536_000
      assert Install.herdr_status_timeout() in 1..3_600
    end
  end

  describe "whiska owl install writes the script" do
    test "executable, in the whiska home", %{home: home} do
      script = Install.herdr_status_path()
      assert String.starts_with?(script, home)

      assert :ok = Install.write_herdr_status()
      assert File.read!(script) == Install.herdr_status_script()
      assert Bitwise.band(File.stat!(script).mode, 0o100) != 0
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

    test "a finished line offers what to do with the branch" do
      assert {_path, body} =
               List.keyfind(Install.skills(), ".claude/skills/whiska-delivered/SKILL.md", 0)

      # Nothing to reply to on a finished line, but plenty to do with the
      # branch. All four choices, in the order the person reads them.
      assert body =~ "Merge here"
      assert body =~ "Open a merge request"
      assert body =~ "Chat further"
      assert body =~ "Drop it"
      assert body =~ "--no-ff"
      assert body =~ "gh"
      assert body =~ "glab"
      # Merging is the usual one, so it is the one carrying the label.
      assert body =~ ~r/\*\*Merge here[^\n]*Recommended/
    end

    test "the finish picker never appears for a branch that is still working" do
      assert {_path, body} =
               List.keyfind(Install.skills(), ".claude/skills/whiska-delivered/SKILL.md", 0)

      # The main session acting on a finished branch is the person's call
      # (ADR-0017); acting on an unfinished one is nobody's.
      assert body =~ ~r/only.*finished|finished.*only/s
      assert body =~ "ADR-0017"
      assert body =~ ~r/still working|unfinished/
    end

    test "the finish picker points at the skills that already do the work" do
      assert {_path, body} =
               List.keyfind(Install.skills(), ".claude/skills/whiska-delivered/SKILL.md", 0)

      # drop-worktree and the repo's own merge steps exist; the skill names
      # them rather than restating them.
      assert body =~ "drop-worktree"
      refute body =~ "git worktree remove"
    end

    test "dropping the work is confirmed before anything is thrown away" do
      assert {_path, body} =
               List.keyfind(Install.skills(), ".claude/skills/whiska-delivered/SKILL.md", 0)

      assert body =~ ~r/[Cc]onfirm/
      assert body =~ ~r/discards/
    end

    test "a repo can name its usual finish choice, and the picker follows it" do
      assert {_path, body} =
               List.keyfind(Install.skills(), ".claude/skills/whiska-delivered/SKILL.md", 0)

      # Read from an optional heading the person writes by hand — no fifth
      # part in the block whiska init writes (ADR-0045 nest untouched).
      assert body =~ "## Finish"
      assert body =~ "finish: merge here"
      refute body =~ "whiska:finish"
    end

    test "/whiska-questions offers the same picker when it read one question by id" do
      assert {_path, body} =
               List.keyfind(Install.skills(), ".claude/skills/whiska-questions/SKILL.md", 0)

      assert body =~ "AskUserQuestion"
      assert body =~ ~r/whiska reply/
      # --full is a list of several; a single picker cannot stand for all of them.
      assert body =~ "--full"
    end

    test "installs /whiska-reply as a thin wrapper around the fixed command" do
      assert {path, body} =
               List.keyfind(Install.skills(), ".claude/skills/whiska-reply/SKILL.md", 0)

      assert path =~ "whiska-reply"
      assert body =~ "name: whiska-reply"
      assert body =~ "whiska reply $ARGUMENTS"
      # The text is the person's, never the model's composition (ADR-0017).
      assert body =~ "own words"
    end

    test "every reading skill says an answer goes through whiska reply and nothing else" do
      for path <- [
            ".claude/skills/whiska-delivered/SKILL.md",
            ".claude/skills/whiska-reply/SKILL.md"
          ] do
        assert {_path, body} = List.keyfind(Install.skills(), path, 0)

        # Anything that answers outside Whiska leaves the question `sent`, so it
        # keeps holding ADR-0008's one delivery slot.
        assert body =~ "herdr agent prompt", path
        assert body =~ "frees the slot", path
      end
    end

    test "the committed skills in this repo are what init writes today" do
      for {path, body} <- Install.skills() do
        assert File.read!(path) == body, "#{path} is stale: run whiska init and commit"
      end
    end
  end

  describe "whiska init writes them" do
    test "the skills, the statusline script and the statusLine entry", %{main: main} do
      capture_io(fn -> assert CLI.run(["init"], main) == 0 end)

      for {path, body} <- Install.skills() do
        assert File.read!(Path.join(main, path)) == body
      end

      script = Path.join(main, Install.statusline_path())
      assert File.read!(script) == Install.statusline_script()
      assert Bitwise.band(File.stat!(script).mode, 0o100) != 0

      settings = JSON.decode!(File.read!(Path.join(main, ".claude/settings.json")))
      assert settings["statusLine"]["command"] == Install.statusline_command()
      assert settings["statusLine"]["refreshInterval"] == Install.statusline_refresh_interval()
    end

    test "a repo init-ed while the line lived only on the tab bar gets it back", %{main: main} do
      File.mkdir_p!(Path.join(main, ".claude"))
      File.write!(Path.join(main, ".claude/settings.json"), JSON.encode!(%{}))

      capture_io(fn -> assert CLI.run(["init"], main) == 0 end)

      settings = JSON.decode!(File.read!(Path.join(main, ".claude/settings.json")))
      assert settings["statusLine"]["command"] == Install.statusline_command()
      assert File.exists?(Path.join(main, Install.statusline_path()))
    end

    test "the script an earlier init wrote is overwritten, not left stale", %{main: main} do
      stale = Path.join(main, Install.statusline_path())
      File.mkdir_p!(Path.dirname(stale))
      File.write!(stale, "#!/usr/bin/env bash\n# Whiska's project statusline (ADR-0027).\n")

      capture_io(fn -> assert CLI.run(["init"], main) == 0 end)

      assert File.read!(stale) == Install.statusline_script()
    end

    test "the shim itself is unchanged by this", %{main: main} do
      capture_io(fn -> assert CLI.run(["init"], main) == 0 end)
      assert File.read!(Path.join(main, Install.shim_path())) == Install.shim()
      assert Install.shim() =~ ~s(hook "$@")
    end
  end
end
