defmodule Whiska.DenyListTest do
  use ExUnit.Case, async: true

  alias Whiska.DenyList

  @persons ~w(away hold focus resume reply dismiss close)
  @main_sessions ~w(spawn send land pr merge-request drop)

  describe "rules/1" do
    test "every mouse is denied the person's commands, whiska in front or bare" do
      for mode <- ["build", "sniff"], word <- @persons do
        assert "Bash(whiska #{word} *)" in DenyList.rules(mode)
        assert "Bash(#{word} *)" in DenyList.rules(mode)
      end
    end

    # `pr` and `send` are other programs too, so only `whiska pr` is the person's.
    test "the main session's commands are denied only with whiska in front" do
      for mode <- ["build", "sniff"], word <- @main_sessions do
        assert "Bash(whiska #{word} *)" in DenyList.rules(mode)
        refute "Bash(#{word} *)" in DenyList.rules(mode)
      end
    end

    test "a sniff mouse is also denied the file tools, by bare name" do
      for tool <- ~w(Edit Write NotebookEdit) do
        assert tool in DenyList.rules("sniff")
        refute tool in DenyList.rules("build")
      end
    end

    test "reading commands are anyone's" do
      for mode <- ["build", "sniff"], word <- ~w(ledger inbox show questions waiting mice) do
        refute Enum.any?(DenyList.rules(mode), &String.contains?(&1, word))
      end
    end
  end

  test "render/1 is a Claude Code settings file holding the deny list and nothing else" do
    assert %{"permissions" => %{"deny" => deny}} = JSON.decode!(DenyList.render("sniff"))
    assert deny == DenyList.rules("sniff")
    assert map_size(JSON.decode!(DenyList.render("build"))) == 1
  end

  test "claude_args/0 starts Claude in bypass mode with the file, every word plain" do
    assert DenyList.claude_args() ==
             ["--dangerously-skip-permissions", "--settings", ".whiska-settings.json"]
  end

  describe "write/3" do
    setup do
      root = Path.join(System.tmp_dir!(), "whiska-deny-#{System.unique_integer([:positive])}")
      main = Path.join(root, "main")
      worktree = Path.join(root, "wt")
      File.mkdir_p!(Path.join(main, ".git"))
      File.mkdir_p!(worktree)
      on_exit(fn -> File.rm_rf!(root) end)
      {:ok, main: main, worktree: worktree}
    end

    test "writes the mode's file and makes git ignore it", %{main: main, worktree: worktree} do
      assert {:ok, []} = DenyList.write(main, worktree, "sniff")

      assert File.read!(Path.join(worktree, ".whiska-settings.json")) == DenyList.render("sniff")
      assert File.read!(Path.join(main, ".git/info/exclude")) =~ "/.whiska-settings.json"
    end

    test "a rewrite replaces the file", %{main: main, worktree: worktree} do
      {:ok, _} = DenyList.write(main, worktree, "sniff")
      {:ok, _} = DenyList.write(main, worktree, "build")

      assert File.read!(Path.join(worktree, ".whiska-settings.json")) == DenyList.render("build")
    end

    test "an ignore that fails is said, and the file is written all the same", %{
      worktree: worktree
    } do
      assert {:ok, [said]} = DenyList.write(Path.join(worktree, "nowhere"), worktree, "build")
      assert said =~ ".whiska-settings.json"
      assert File.regular?(Path.join(worktree, ".whiska-settings.json"))
    end

    test "a link at the path is refused, and nothing is written through it", %{
      main: main,
      worktree: worktree
    } do
      target = Path.join(main, "settings.json")
      File.write!(target, "the person's own settings")
      File.ln_s!(target, Path.join(worktree, ".whiska-settings.json"))

      assert {:error, :not_a_plain_file} = DenyList.write(main, worktree, "sniff")
      assert File.read!(target) == "the person's own settings"
    end
  end
end
