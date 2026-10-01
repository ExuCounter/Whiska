defmodule Whiska.InstallGlobalTest do
  @moduledoc """
  The values `whiska init --global` writes (ADR-0056).

  The global install is the per-repo install rooted at the person's home rather
  than at a repo: the same relative paths, the same shim, the same statusline
  script, the same block. What differs is where the commands point, and the one
  rule that keeps a repo carrying both from running everything twice — the
  per-repo install wins and the global one stands down.
  """
  use ExUnit.Case, async: true

  alias Whiska.Install
  alias Whiska.LaunchAgent

  describe "root/1 — where each scope is rooted" do
    test "the global scope is rooted at the person's home, not at a repo" do
      assert Install.root(:global) == LaunchAgent.user_home()
    end

    test "the relative paths are the same for both scopes" do
      # The whole point: `~/.claude/hooks/whiska.sh` and
      # `<repo>/.claude/hooks/whiska.sh` are the same file in two places.
      assert Install.shim_path() == ".claude/hooks/whiska.sh"
      assert Install.statusline_path() == ".claude/hooks/whiska-statusline.sh"
    end
  end

  describe "command/1 — what goes into ~/.claude/settings.json" do
    test "the global hook names the home copy of the shim" do
      for command <- [Install.command(:global), Install.stop_command(:global)] do
        assert command =~ "$HOME/.claude/hooks/whiska.sh"
        refute command =~ "CLAUDE_PROJECT_DIR"
      end
    end

    test "the global hook still takes the hook's name as its argument" do
      assert Install.command(:global) =~ "pre-tool-use"
      assert Install.stop_command(:global) =~ "stop"
    end

    test "the per-repo commands are unchanged" do
      assert Install.command(:repo) == Install.command()
      assert Install.stop_command(:repo) == Install.stop_command()
    end
  end

  describe "shim/1 — the global shim stands down for a repo that has its own" do
    test "the global shim exits before doing anything when the repo wires Whiska" do
      shim = Install.shim(:global)

      # Claude Code merges the hook arrays from ~/.claude and the project, so
      # both would fire on one turn and leave two entries on the doorstep.
      assert shim =~ "CLAUDE_PROJECT_DIR"
      assert shim =~ ".claude/settings.json"
      assert shim =~ "settings.local.json"
      assert shim =~ "exit 0"

      # The stand-down comes before the binary is even resolved.
      [stand_down, resolve] =
        for needle <- ["settings.local.json", "whiska_bin="],
            do: :binary.match(shim, needle) |> elem(0)

      assert stand_down < resolve
    end

    test "the per-repo shim has no stand-down — nothing outranks it" do
      refute Install.shim(:repo) =~ "settings.local.json"
      assert Install.shim(:repo) == Install.shim()
    end

    test "both shims resolve the binary and the runtime at run time" do
      for shim <- [Install.shim(:repo), Install.shim(:global)] do
        assert shim =~ "command -v escript"
        assert shim =~ ~s(hook "$@")
      end
    end
  end

  describe "statusline_command/1" do
    test "the global one names the home copy of the script" do
      assert Install.statusline_command(:global) =~ "$HOME/.claude/hooks/whiska-statusline.sh"
    end
  end

  describe "statusline_script/0 — keeping the person's own global line" do
    test "falls back to the displaced line when the global statusLine is Whiska's" do
      script = Install.statusline_script()

      assert script =~ Install.base_statusline_path()
      assert script =~ "whiska-statusline.sh"
    end

    test "the board is still found by walking up from the session's directory" do
      # Nothing about the global install changes this: the board file is named
      # after the main checkout, and the script walks up to find it.
      script = Install.statusline_script()

      assert script =~ "board/"
      assert script =~ "dirname"
      assert script =~ "workspace.current_dir"
    end

    test "a mouse's own pane still draws no board" do
      assert Install.statusline_script() =~ "*/worktrees/*"
    end
  end

  describe "skills/1" do
    test "the global install ships the reading skills and the finish pipeline" do
      paths = Install.skills(:global) |> Enum.map(&elem(&1, 0))

      for name <- ~w(whiska-questions whiska-delivered whiska-reply whiska-finish) do
        assert ".claude/skills/#{name}/SKILL.md" in paths
      end
    end

    test "the global install leaves the worktree skills to the person's own dotfiles" do
      paths = Install.skills(:global) |> Enum.map(&elem(&1, 0))

      for name <- ~w(spawn-worktree send-to-worktree drop-worktree) do
        refute ".claude/skills/#{name}/SKILL.md" in paths
      end
    end

    test "the per-repo install is unchanged and ships all seven" do
      assert Install.skills(:repo) == Install.skills()
      assert length(Install.skills()) == 7
    end
  end

  describe "merge/2 — ~/.claude/settings.json" do
    test "wires both hooks and the statusline, global-flavoured" do
      merged = Install.merge(%{}, :global)

      assert [%{"hooks" => [%{"command" => pre}]}] = merged["hooks"]["PreToolUse"]
      assert pre == Install.command(:global)

      assert [%{"hooks" => [%{"command" => stop}]}] = merged["hooks"]["Stop"]
      assert stop == Install.stop_command(:global)

      assert merged["statusLine"]["command"] == Install.statusline_command(:global)
    end

    test "never clobbers the person's other settings" do
      settings = %{
        "model" => "opus",
        "permissions" => %{"allow" => ["Bash(ls:*)"]},
        "hooks" => %{
          "PreToolUse" => [%{"matcher" => "Bash", "hooks" => [%{"command" => "mine.sh"}]}],
          "SessionStart" => [%{"hooks" => [%{"command" => "theirs.sh"}]}]
        }
      }

      merged = Install.merge(settings, :global)

      assert merged["model"] == "opus"
      assert merged["permissions"] == settings["permissions"]
      assert merged["hooks"]["SessionStart"] == settings["hooks"]["SessionStart"]

      assert Enum.any?(
               merged["hooks"]["PreToolUse"],
               &(&1["hooks"] == [%{"command" => "mine.sh"}])
             )
    end

    test "is idempotent" do
      once = Install.merge(%{}, :global)
      assert Install.merge(once, :global) == once
    end

    test "replaces a per-repo-flavoured entry rather than stacking beside it" do
      # Someone who copied their project settings into ~/.claude gets one entry,
      # pointing at the home shim.
      merged = %{} |> Install.merge(:repo) |> Install.merge(:global)

      assert [%{"hooks" => [%{"command" => command}]}] = merged["hooks"]["PreToolUse"]
      assert command == Install.command(:global)
    end
  end

  describe "displaced/1 — the global statusLine the install pushes aside" do
    test "names the person's own line" do
      assert Install.displaced(%{"statusLine" => %{"command" => "mine.sh"}}) == "mine.sh"
    end

    test "is nothing when there is no line, or when the line is already ours" do
      assert Install.displaced(%{}) == nil

      assert Install.displaced(%{"statusLine" => %{"command" => Install.statusline_command()}}) ==
               nil
    end
  end

  describe "unmerge/2 — what uninstall takes back out" do
    test "removes our hooks and leaves everyone else's" do
      settings =
        %{
          "hooks" => %{
            "PreToolUse" => [%{"matcher" => "Bash", "hooks" => [%{"command" => "mine.sh"}]}]
          }
        }
        |> Install.merge(:global)

      back = Install.unmerge(settings, nil)

      assert back["hooks"]["PreToolUse"] == [
               %{"matcher" => "Bash", "hooks" => [%{"command" => "mine.sh"}]}
             ]

      assert back["hooks"]["Stop"] == []
    end

    test "restores the statusLine that was displaced" do
      settings = Install.merge(%{}, :global)

      assert Install.unmerge(settings, "mine.sh")["statusLine"] == %{
               "type" => "command",
               "command" => "mine.sh"
             }
    end

    test "drops the statusLine entirely when nothing was displaced" do
      settings = Install.merge(%{}, :global)
      refute Map.has_key?(Install.unmerge(settings, nil), "statusLine")
    end

    test "leaves somebody else's statusLine exactly alone" do
      settings = %{"statusLine" => %{"command" => "theirs.sh"}}
      assert Install.unmerge(settings, nil)["statusLine"] == %{"command" => "theirs.sh"}
    end
  end
end
