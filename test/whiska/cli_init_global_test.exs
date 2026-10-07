defmodule Whiska.CLIInitGlobalTest do
  @moduledoc """
  `whiska init --global` and `whiska uninstall` end to end (ADR-0056).

  Everything here runs against a pinned `:user_home` in a temp folder. Nothing
  may touch the person's own `~/.claude`.
  """
  # Serial: each test points the global `:user_home` at a home of its own.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Whiska.CLI
  alias Whiska.Install

  setup do
    previous = Application.get_env(:whiska, :user_home)
    root = Path.join(System.tmp_dir!(), "whiska-global-#{System.unique_integer([:positive])}")
    home = Path.join(root, "home")
    repo = Path.join(root, "myrepo")
    File.mkdir_p!(Path.join(repo, ".git"))
    File.mkdir_p!(home)
    Application.put_env(:whiska, :user_home, home)
    # The commands live under the whiska home, which every test in this run
    # shares: a wrapper one test wrote must not read as this test's. And the
    # clash check walks the real PATH, where the person's own installed words
    # would read as clashes, so PATH is stripped to the system's.
    File.rm_rf!(Install.commands_dir())
    path_was = System.get_env("PATH")
    System.put_env("PATH", "/usr/bin:/bin")

    on_exit(fn ->
      Application.put_env(:whiska, :user_home, previous)
      System.put_env("PATH", path_was)
      File.rm_rf!(Install.commands_dir())
      File.rm_rf!(root)
    end)

    {:ok, home: home, repo: repo, settings: Path.join(home, ".claude/settings.json")}
  end

  defp init_global, do: capture_io(fn -> assert CLI.run(["init", "--global"], nil) == 0 end)
  defp init(repo), do: capture_io(fn -> assert CLI.run(["init"], repo) == 0 end)

  defp uninstall_global,
    do: capture_io(fn -> assert CLI.run(["uninstall", "--global"], nil) == 0 end)

  defp uninstall(repo), do: capture_io(fn -> assert CLI.run(["uninstall"], repo) == 0 end)

  defp settings(path), do: path |> File.read!() |> JSON.decode!()

  # What an older `whiska init --global` left in ~/.claude/CLAUDE.md, below the
  # person's own text.
  @old_block """
  # Mine

  Plain language, always.

  <!-- whiska:start -->
  <!-- whiska:scope:start -->
  ## Which copy of these rules counts
  <!-- whiska:scope:end -->

  <!-- whiska:worktrees:start -->
  ## Worktrees
  <!-- whiska:worktrees:end -->
  <!-- whiska:end -->
  """

  describe "whiska init --global" do
    test "takes an older install's block out of ~/.claude/CLAUDE.md, and keeps the person's text",
         %{home: home} do
      path = Path.join(home, ".claude/CLAUDE.md")
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, @old_block)

      output = init_global()

      assert File.read!(path) == "# Mine\n\nPlain language, always.\n"
      assert output =~ "Took the old block out of ~/.claude/CLAUDE.md"
    end

    test "writes nothing into the person's own global CLAUDE.md", %{home: home} do
      path = Path.join(home, ".claude/CLAUDE.md")
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "# Mine\n\nPlain language, always.\n")

      init_global()

      assert File.read!(path) == "# Mine\n\nPlain language, always.\n"
    end

    test "creates no ~/.claude/CLAUDE.md where there was none", %{home: home} do
      init_global()
      refute File.exists?(Path.join(home, ".claude/CLAUDE.md"))
    end

    test "writes the shim, executable, and no statusline script", %{home: home} do
      init_global()

      path = Path.join(home, Install.shim_path())
      assert File.stat!(path).mode |> rem(0o1000) == 0o755
      refute File.exists?(Path.join(home, Install.statusline_path()))
    end

    test "wires the hooks into ~/.claude/settings.json", %{
      settings: path
    } do
      init_global()

      assert settings(path) == Install.merge(%{}, :global)
    end

    test "merges into settings the person already had", %{settings: path} do
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, JSON.encode!(%{"model" => "opus", "env" => %{"FOO" => "bar"}}))

      init_global()

      assert settings(path)["model"] == "opus"
      assert settings(path)["env"] == %{"FOO" => "bar"}
      assert settings(path)["hooks"]["Stop"] != nil
    end

    test "leaves the person's own global statusline exactly where it is", %{
      home: home,
      settings: path
    } do
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, JSON.encode!(%{"statusLine" => %{"command" => "my-line.sh"}}))

      init_global()

      assert settings(path)["statusLine"] == %{"command" => "my-line.sh"}
      refute File.exists?(Path.join(home, Install.base_statusline_path()))
    end

    test "puts back the line an older install displaced, before removing what it kept", %{
      home: home,
      settings: path
    } do
      ours = ~s|bash "$HOME/.claude/hooks/whiska-statusline.sh"|
      script = Path.join(home, Install.statusline_path())
      base = Path.join(home, Install.base_statusline_path())
      File.mkdir_p!(Path.dirname(script))
      File.write!(script, "#!/usr/bin/env bash\n")
      File.write!(base, "my-line.sh\n")

      File.write!(
        path,
        JSON.encode!(%{
          "statusLine" => %{"type" => "command", "command" => ours, "refreshInterval" => 1}
        })
      )

      output = init_global()

      assert settings(path)["statusLine"] == %{"type" => "command", "command" => "my-line.sh"}
      refute File.exists?(script)
      refute File.exists?(base)
      assert output =~ "herdr's sidebar"
    end

    test "keeps what an older install kept when it cannot write the line back", %{
      home: home,
      settings: path
    } do
      base = Path.join(home, Install.base_statusline_path())
      File.mkdir_p!(Path.dirname(base))
      File.write!(base, "my-line.sh")
      File.write!(path, "{not json")

      capture_io(:stderr, fn -> assert CLI.run(["init", "--global"], nil) == 1 end)

      assert File.read!(base) == "my-line.sh"
    end

    test "writes every skill, the worktree ones and the eight words included", %{home: home} do
      init_global()

      for name <- ~w(whiska-delivered whiska-finish whiska-spec grilling
                     spawn-worktree send-to-worktree drop-worktree
                     inbox show reply dismiss focus away hold resume) do
        assert File.exists?(Path.join(home, ".claude/skills/#{name}/SKILL.md"))
      end
    end

    test "removes the two retired skills where they are plain files of Whiska's", %{home: home} do
      for name <- ~w(whiska-questions whiska-reply) do
        File.mkdir_p!(Path.join(home, ".claude/skills/#{name}"))
        File.write!(Path.join(home, ".claude/skills/#{name}/SKILL.md"), "name: #{name}\n")
      end

      output = init_global()

      for name <- ~w(whiska-questions whiska-reply) do
        refute File.exists?(Path.join(home, ".claude/skills/#{name}/SKILL.md")), name
        assert output =~ name
      end
    end

    test "writes the eight commands under the whiska home, executable, and prints the PATH line",
         %{home: _home} do
      output = init_global()
      dir = Install.commands_dir()

      for word <- Install.commands() do
        script = Path.join(dir, word)
        assert File.exists?(script), word
        assert Bitwise.band(File.stat!(script).mode, 0o100) != 0, word
        assert File.read!(script) == Install.command_script(word)
      end

      assert output =~ ~s|export PATH="#{dir}:$PATH"|
    end

    test "a word that already names another program is skipped and named, never shadowed",
         %{home: _home} do
      taken = Path.join(System.tmp_dir!(), "whiska-taken-#{System.unique_integer([:positive])}")
      File.mkdir_p!(taken)
      other = Path.join(taken, "focus")
      File.write!(other, "#!/bin/sh\necho mine\n")
      File.chmod!(other, 0o755)
      path_was = System.get_env("PATH")
      System.put_env("PATH", taken <> ":" <> path_was)

      on_exit(fn ->
        System.put_env("PATH", path_was)
        File.rm_rf!(taken)
      end)

      output = init_global()

      refute File.exists?(Path.join(Install.commands_dir(), "focus"))
      assert File.exists?(Path.join(Install.commands_dir(), "inbox"))
      assert output =~ "focus"
      assert output =~ other
    end

    test "a word already resolving to Whiska's own wrapper is not a clash", %{home: _home} do
      init_global()
      path_was = System.get_env("PATH")
      System.put_env("PATH", Install.commands_dir() <> ":" <> path_was)
      on_exit(fn -> System.put_env("PATH", path_was) end)

      output = init_global()

      for word <- Install.commands(),
          do: assert(File.exists?(Path.join(Install.commands_dir(), word)))

      refute output =~ "skipped"
    end

    test "names every skill it wrote" do
      [_, after_heading] = init_global() |> String.split("~/.claude/skills/", parts: 2)
      [written | _] = String.split(after_heading, "\n\n", parts: 2)

      for {path, _} <- Whiska.Install.skills(:global) do
        name = path |> Path.dirname() |> Path.basename()
        assert written =~ ~r/\b#{name}\b/, "#{name} is not named"
      end
    end

    test "says where each worktree skill landed, a plain file included", %{home: home} do
      output = init_global()

      for name <- ~w(spawn-worktree send-to-worktree drop-worktree) do
        real = Whiska.Layout.canonical(Path.join(home, ".claude/skills/#{name}/SKILL.md"))
        [line] = output |> String.split("\n") |> Enum.filter(&(&1 =~ "#{name} "))
        assert line =~ real
        refute line =~ "symlink"
      end
    end

    test "is idempotent — a second run changes nothing", %{home: home, settings: path} do
      md = Path.join(home, ".claude/CLAUDE.md")
      File.mkdir_p!(Path.dirname(md))
      File.write!(md, @old_block)

      init_global()
      before = {File.read!(md), File.read!(path)}
      init_global()

      assert {File.read!(md), File.read!(path)} == before
    end

    test "survives a settings.json whose shape Whiska did not write", %{settings: path} do
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, JSON.encode!(%{"statusLine" => "my-line.sh", "hooks" => []}))

      init_global()

      assert settings(path)["statusLine"] == "my-line.sh"
    end

    test "whiska init in a repo survives one too", %{repo: repo, settings: path} do
      # `whiska init` never read ~/.claude before; a shape it cannot read there
      # must not take the per-repo install down with it.
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, JSON.encode!(%{"statusLine" => "my-line.sh"}))

      capture_io(fn -> assert CLI.run(["init"], repo) == 0 end)
    end

    test "refuses rather than overwrite settings it cannot parse", %{settings: path} do
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "{not json")

      output = capture_io(:stderr, fn -> assert CLI.run(["init", "--global"], nil) == 1 end)

      assert output =~ "could not parse"
      assert File.read!(path) == "{not json"
    end

    test "needs no repo at all", %{home: home} do
      # No cwd, no git checkout: the global install is about the machine.
      capture_io(fn -> assert CLI.run(["init", "--global"], nil) == 0 end)
      assert File.exists?(Path.join(home, ".claude/settings.json"))
    end

    test "says what it wrote and how to switch a repo over" do
      output = init_global()

      assert output =~ "~/.claude"
      assert output =~ "whiska uninstall"
    end
  end

  describe "a repo that also has the per-repo install" do
    test "both can stand; the repo's own copy is the one in force", %{repo: repo, home: home} do
      init_global()
      init(repo)

      assert File.exists?(Path.join(repo, ".claude/hooks/whiska.sh"))
      assert File.exists?(Path.join(home, ".claude/hooks/whiska.sh"))

      assert settings(Path.join(repo, ".claude/settings.json"))["hooks"]["SessionStart"] ==
               Install.merge(%{})["hooks"]["SessionStart"]
    end

    test "whiska init says the global install is there and how to drop the repo copy", %{
      repo: repo
    } do
      init_global()
      output = init(repo)

      assert output =~ "global"
      assert output =~ "whiska uninstall"
    end

    test "whiska init says nothing about global when there is no global install", %{repo: repo} do
      refute init(repo) =~ "--global"
    end
  end

  describe "whiska uninstall --global" do
    test "takes the old block, the hooks, the scripts and the skills back out", %{
      home: home,
      settings: path
    } do
      init_global()
      File.write!(Path.join(home, ".claude/CLAUDE.md"), @old_block)
      uninstall_global()

      refute File.read!(Path.join(home, ".claude/CLAUDE.md")) =~ "<!-- whiska:start -->"
      refute File.exists?(Path.join(home, Install.shim_path()))
      refute File.exists?(Path.join(home, Install.statusline_path()))
      refute File.exists?(Path.join(home, ".claude/skills/show/SKILL.md"))
      refute File.exists?(Path.join(home, ".claude/skills/whiska-delivered"))
      refute File.exists?(Path.join(home, ".claude/skills/whiska-finish"))

      settings = settings(path)
      assert settings["hooks"]["Stop"] == []
      assert settings["hooks"]["UserPromptSubmit"] == []
      assert settings["hooks"]["SessionStart"] == []
      refute Map.has_key?(settings, "statusLine")
    end

    test "takes the eight commands back out too" do
      init_global()
      assert File.exists?(Path.join(Install.commands_dir(), "inbox"))

      uninstall_global()

      for word <- Install.commands(),
          do: refute(File.exists?(Path.join(Install.commands_dir(), word)), word)
    end

    test "gives the person the line an older install displaced back", %{
      home: home,
      settings: path
    } do
      ours = ~s|bash "$HOME/.claude/hooks/whiska-statusline.sh"|
      File.mkdir_p!(Path.dirname(path))
      File.write!(Path.join(home, Install.base_statusline_path()), "my-line.sh")
      File.write!(path, JSON.encode!(%{"statusLine" => %{"command" => ours}}))

      uninstall_global()

      assert settings(path)["statusLine"]["command"] == "my-line.sh"
      refute File.exists?(Path.join(home, Install.base_statusline_path()))
    end

    test "leaves everything that was not Whiska's", %{home: home, settings: path} do
      File.mkdir_p!(Path.join(home, ".claude/skills/mine"))
      File.write!(Path.join(home, ".claude/skills/mine/SKILL.md"), "mine")
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, JSON.encode!(%{"model" => "opus"}))
      md = Path.join(home, ".claude/CLAUDE.md")
      File.write!(md, "# Mine\n\nKeep me.\n")

      init_global()
      uninstall_global()

      assert File.read!(Path.join(home, ".claude/skills/mine/SKILL.md")) == "mine"
      assert settings(path)["model"] == "opus"
      assert File.read!(md) =~ "Keep me."
    end

    test "is safe to run when nothing is installed", %{home: home} do
      capture_io(fn -> assert CLI.run(["uninstall", "--global"], nil) == 0 end)
      refute File.exists?(Path.join(home, ".claude/hooks/whiska.sh"))
    end
  end

  describe "whiska uninstall — one repo" do
    test "takes this repo's old block, hooks, scripts and skills back out", %{repo: repo} do
      init(repo)
      File.write!(Path.join(repo, "CLAUDE.md"), @old_block)
      uninstall(repo)

      refute File.read!(Path.join(repo, "CLAUDE.md")) =~ "<!-- whiska:start -->"
      refute File.exists?(Path.join(repo, ".claude/hooks/whiska.sh"))
      refute File.exists?(Path.join(repo, ".claude/hooks/whiska-statusline.sh"))
      refute File.exists?(Path.join(repo, ".claude/skills/spawn-worktree/SKILL.md"))

      settings = Path.join(repo, ".claude/settings.json") |> settings()
      assert settings["hooks"]["PreToolUse"] == []
      refute Map.has_key?(settings, "statusLine")
    end

    test "leaves the house alone — uninstalling is not forgetting", %{repo: repo} do
      house = Path.join(repo, ".git/whiska")
      File.mkdir_p!(house)
      File.write!(Path.join(house, "whiska.db"), "not really a database")

      init(repo)
      uninstall(repo)

      assert File.exists?(Path.join(house, "whiska.db"))
    end

    test "prints what it removed", %{repo: repo} do
      init(repo)
      File.write!(Path.join(repo, "CLAUDE.md"), @old_block)
      output = uninstall(repo)

      assert output =~ "CLAUDE.md"
      assert output =~ ".claude/hooks/whiska.sh"
    end
  end
end
