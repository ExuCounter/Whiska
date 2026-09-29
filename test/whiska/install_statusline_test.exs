defmodule Whiska.InstallStatuslineTest do
  @moduledoc """
  What `whiska init` adds for questions — the `/whiska-questions`
  slash-command skill (ADR-0022) — and what it no longer adds: the project
  statusline, which moved to herdr's tab bar (ADR-0048).
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

  describe "merge/1 — the statusLine entry is gone (ADR-0048)" do
    test "adds no statusLine: the line lives on herdr's tab bar now" do
      refute Map.has_key?(Install.merge(%{}), "statusLine")
    end

    test "removes one of ours left by an earlier init" do
      old = %{
        "type" => "command",
        "command" => "bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/whiska-statusline.sh\"",
        "refreshInterval" => 15
      }

      refute Map.has_key?(Install.merge(%{"statusLine" => old}), "statusLine")
    end

    test "leaves a statusLine that is not ours exactly alone" do
      mine = %{"type" => "command", "command" => "bash mine.sh"}
      assert Install.merge(%{"statusLine" => mine})["statusLine"] == mine
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
    test "the skills, and no statusLine at all (ADR-0048)", %{main: main} do
      capture_io(fn -> assert CLI.run(["init"], main) == 0 end)

      for {path, body} <- Install.skills() do
        assert File.read!(Path.join(main, path)) == body
      end

      settings = JSON.decode!(File.read!(Path.join(main, ".claude/settings.json")))
      refute Map.has_key?(settings, "statusLine")
      refute File.exists?(Path.join(main, ".claude/hooks/whiska-statusline.sh"))
    end

    test "clears away the statusline an earlier init left behind", %{main: main} do
      stale = Path.join(main, ".claude/hooks/whiska-statusline.sh")
      File.mkdir_p!(Path.dirname(stale))
      File.write!(stale, "#!/usr/bin/env bash\n# Whiska's project statusline (ADR-0027).\n")

      File.write!(
        Path.join(main, ".claude/settings.json"),
        JSON.encode!(%{
          "statusLine" => %{
            "type" => "command",
            "command" => "bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/whiska-statusline.sh\"",
            "refreshInterval" => 15
          }
        })
      )

      capture_io(fn -> assert CLI.run(["init"], main) == 0 end)

      refute File.exists?(stale)
      settings = JSON.decode!(File.read!(Path.join(main, ".claude/settings.json")))
      refute Map.has_key?(settings, "statusLine")
    end

    test "a statusline script that is not ours is left where it is", %{main: main} do
      theirs = Path.join(main, ".claude/hooks/whiska-statusline.sh")
      File.mkdir_p!(Path.dirname(theirs))
      File.write!(theirs, "#!/usr/bin/env bash\necho mine\n")

      capture_io(fn -> assert CLI.run(["init"], main) == 0 end)

      assert File.read!(theirs) == "#!/usr/bin/env bash\necho mine\n"
    end

    test "the shim itself is unchanged by this", %{main: main} do
      capture_io(fn -> assert CLI.run(["init"], main) == 0 end)
      assert File.read!(Path.join(main, Install.shim_path())) == Install.shim()
      assert Install.shim() =~ ~s(hook "$@")
    end
  end
end
