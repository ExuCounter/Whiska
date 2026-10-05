defmodule Whiska.CLIInitGlobalTest do
  @moduledoc """
  `whiska init --global` and `whiska uninstall` end to end (ADR-0056).

  Everything here runs against a pinned `:user_home` in a temp folder. Nothing
  may touch the person's own `~/.claude`.
  """
  # Serial: each test points the global `:user_home` at a home of its own.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Whiska.ClaudeMd
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

    on_exit(fn ->
      Application.put_env(:whiska, :user_home, previous)
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

  describe "whiska init --global" do
    test "writes the block into ~/.claude/CLAUDE.md", %{home: home} do
      init_global()

      body = File.read!(Path.join(home, ".claude/CLAUDE.md"))
      assert body =~ "<!-- whiska:start -->"
      assert body =~ "## Worktrees"
      assert body == ClaudeMd.merge("", :global)
    end

    test "keeps what the person's own global CLAUDE.md already says", %{home: home} do
      path = Path.join(home, ".claude/CLAUDE.md")
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "# Mine\n\nPlain language, always.\n")

      init_global()

      assert File.read!(path) =~ "Plain language, always."
      assert File.read!(path) =~ "<!-- whiska:start -->"
    end

    test "writes the shim and the statusline script, executable", %{home: home} do
      init_global()

      for rel <- [Install.shim_path(), Install.statusline_path()] do
        path = Path.join(home, rel)
        assert File.exists?(path), "#{rel} was not written"
        assert File.stat!(path).mode |> rem(0o1000) == 0o755
      end
    end

    test "wires both hooks and the statusline into ~/.claude/settings.json", %{settings: path} do
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

    test "keeps the person's own global statusline rather than losing it", %{
      home: home,
      settings: path
    } do
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, JSON.encode!(%{"statusLine" => %{"command" => "my-line.sh"}}))

      init_global()

      # The statusLine entry is Whiska's now, and the line it displaced is
      # recorded where the script picks it up and runs it first.
      assert settings(path)["statusLine"]["command"] == Install.statusline_command(:global)
      assert File.read!(Path.join(home, Install.base_statusline_path())) == "my-line.sh"
    end

    test "writes all nine skills, the worktree ones included", %{home: home} do
      init_global()

      for name <- ~w(whiska-questions whiska-delivered whiska-reply whiska-finish
                     whiska-spec grilling spawn-worktree send-to-worktree drop-worktree) do
        assert File.exists?(Path.join(home, ".claude/skills/#{name}/SKILL.md"))
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
      init_global()
      before = {File.read!(Path.join(home, ".claude/CLAUDE.md")), File.read!(path)}
      init_global()

      assert {File.read!(Path.join(home, ".claude/CLAUDE.md")), File.read!(path)} == before
    end

    test "survives a settings.json whose shape Whiska did not write", %{settings: path} do
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, JSON.encode!(%{"statusLine" => "my-line.sh", "hooks" => []}))

      init_global()

      assert settings(path)["statusLine"]["command"] == Install.statusline_command(:global)
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
      assert File.exists?(Path.join(home, ".claude/CLAUDE.md"))
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
      assert File.read!(Path.join(home, ".claude/CLAUDE.md")) =~ "in force"
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
    test "takes the block, the hooks, the scripts and the skills back out", %{
      home: home,
      settings: path
    } do
      init_global()
      uninstall_global()

      refute File.read!(Path.join(home, ".claude/CLAUDE.md")) =~ "<!-- whiska:start -->"
      refute File.exists?(Path.join(home, Install.shim_path()))
      refute File.exists?(Path.join(home, Install.statusline_path()))
      refute File.exists?(Path.join(home, ".claude/skills/whiska-questions/SKILL.md"))

      settings = settings(path)
      assert settings["hooks"]["Stop"] == []
      refute Map.has_key?(settings, "statusLine")
    end

    test "gives the person their own statusline back", %{settings: path} do
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, JSON.encode!(%{"statusLine" => %{"command" => "my-line.sh"}}))

      init_global()
      uninstall_global()

      assert settings(path)["statusLine"]["command"] == "my-line.sh"
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
    test "takes this repo's block, hooks, scripts and skills back out", %{repo: repo} do
      init(repo)
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
      output = uninstall(repo)

      assert output =~ "CLAUDE.md"
      assert output =~ ".claude/hooks/whiska.sh"
    end
  end
end
