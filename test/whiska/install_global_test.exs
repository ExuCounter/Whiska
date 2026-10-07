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
  alias Whiska.ServiceManager

  describe "root/1 — where each scope is rooted" do
    test "the global scope is rooted at the person's home, not at a repo" do
      assert Install.root(:global) == ServiceManager.user_home()
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

    test "it stands down only for a repo whose shim is actually there" do
      # The settings file is text a repo ships, so a repo that merely mentions
      # the path must not be able to switch Whiska's enforcement off in itself.
      assert Install.shim(:global) =~ ~s([ -f "$whiska_project_shim" ])
    end

    test "it never reads a path that is not a regular file" do
      # `[ -r ]` is true of a FIFO, and grep on one with no writer blocks for
      # ever — on a hook that fires on every tool call.
      refute Install.shim(:global) =~ ~s([ -r "$whiska_settings" ])
      assert Install.shim(:global) =~ ~s([ -f "$whiska_settings" ])
    end

    test "it skips the whole hook for a pre-tool-use call outside any worktree" do
      # Outside a worktree PreToolUse has no mouse to apply a rule to and
      # always allows, so the ~140 ms escript buys nothing — and the global
      # shim now pays it in every repo on the machine.
      shim = Install.shim(:global)

      assert shim =~ ~s([ "$1" = "pre-tool-use" ])
      assert shim =~ "*/worktrees/*"
    end

    test "it never skips a stop — a lost question is worse than a slow turn" do
      early_exits =
        ~r/^if \[ "\$\{?1(?::-)?\}?" = "([a-z-]+)" \] && \[ -n "\$\{CLAUDE_PROJECT_DIR:-\}" \]/m
        |> Regex.scan(Install.shim(:global), capture: :all_but_first)
        |> List.flatten()
        |> Enum.sort()

      assert early_exits == ["pre-tool-use", "user-prompt-submit"]
    end

    test "it skips only when Claude Code said where the session started" do
      # The working directory follows every `cd` the session runs (ADR-0053),
      # so it is not safe to decide on, and an unset variable means do the work.
      assert Install.shim(:global) =~ ~s([ -n "${CLAUDE_PROJECT_DIR:-}" ])
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

  describe "skills/1" do
    test "the global install ships every skill, the worktree ones and the eight words included" do
      assert Install.skills(:global) == Install.skills()
      paths = Install.skills(:global) |> Enum.map(&elem(&1, 0))

      for name <- ~w(whiska-delivered whiska-finish cold-review whiska-spec grilling
                     spawn-worktree send-to-worktree drop-worktree
                     inbox show reply dismiss focus away hold resume) do
        assert ".claude/skills/#{name}/SKILL.md" in paths
      end
    end

    test "the per-repo install is unchanged and ships all sixteen, with the files beside them" do
      assert Install.skills(:repo) == Install.skills()

      {skill_files, beside} =
        Install.skills()
        |> Enum.map(&elem(&1, 0))
        |> Enum.split_with(&(Path.basename(&1) == "SKILL.md"))

      assert length(skill_files) == 16

      assert Enum.sort(beside) == [
               ".claude/skills/whiska-delivered/finished.md",
               ".claude/skills/whiska-delivered/sniff.md",
               ".claude/skills/whiska-finish/proposed-build.md"
             ]
    end
  end

  describe "merge/2 — ~/.claude/settings.json" do
    test "wires both hooks, global-flavoured, and no statusline" do
      merged = Install.merge(%{}, :global)

      assert [%{"hooks" => [%{"command" => pre}]}] = merged["hooks"]["PreToolUse"]
      assert pre == Install.command(:global)

      assert [%{"hooks" => [%{"command" => stop}]}] = merged["hooks"]["Stop"]
      assert stop == Install.stop_command(:global)

      refute Map.has_key?(merged, "statusLine")
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
      assert hd(merged["hooks"]["SessionStart"]) == hd(settings["hooks"]["SessionStart"])

      assert [_theirs, %{"hooks" => [%{"command" => ours}]}] = merged["hooks"]["SessionStart"]
      assert ours == Install.session_start_command(:global)

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

  describe "a settings.json Whiska did not write" do
    # ~/.claude/settings.json is the person's file and can hold anything. Before
    # the global install nothing read it, and a shape that is merely odd must
    # not take a command down.
    @malformed [
      %{"statusLine" => "my-line.sh"},
      %{"statusLine" => []},
      %{"hooks" => nil},
      %{"hooks" => []},
      %{"hooks" => "none"},
      %{"hooks" => %{"PreToolUse" => %{"a" => 1}}},
      %{"hooks" => %{"PreToolUse" => "mine.sh"}}
    ]

    test "merge/2 writes Whiska's own entries over it rather than raising" do
      for settings <- @malformed do
        merged = Install.merge(settings, :global)

        assert [%{"hooks" => [%{"command" => command}]}] = merged["hooks"]["PreToolUse"]
        assert command == Install.command(:global)
        assert merged["statusLine"] == settings["statusLine"]
        assert JSON.encode!(merged)
      end
    end

    test "unmerge/2 leaves it rather than raising" do
      for settings <- @malformed do
        assert JSON.encode!(Install.unmerge(settings, nil))
      end
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
      ours = ~s|bash "$HOME/.claude/hooks/whiska-statusline.sh"|
      settings = %{"statusLine" => %{"command" => ours}}

      assert Install.unmerge(settings, "mine.sh")["statusLine"] == %{
               "type" => "command",
               "command" => "mine.sh"
             }
    end

    test "drops the statusLine entirely when nothing was displaced" do
      ours = ~s|bash "$HOME/.claude/hooks/whiska-statusline.sh"|
      settings = %{"statusLine" => %{"command" => ours}}
      refute Map.has_key?(Install.unmerge(settings, nil), "statusLine")
    end

    test "leaves somebody else's statusLine exactly alone" do
      settings = %{"statusLine" => %{"command" => "theirs.sh"}}
      assert Install.unmerge(settings, nil)["statusLine"] == %{"command" => "theirs.sh"}
    end
  end
end
