defmodule Whiska.CLIInitGlobalSymlinkTest do
  @moduledoc """
  `~/.claude/settings.json` and `~/.claude/skills` are commonly symlinks into a
  dotfiles repo. A write that replaces the link with a plain file disconnects
  that repo silently: the person keeps editing dotfiles and nothing they write
  reaches Claude Code again.

  So every write the global install makes goes through the link and changes what
  it points at, and neither `whiska init` nor `whiska uninstall` deletes through
  a link (ADR-0056).
  """
  # Serial: each test points the global `:user_home` at a home of its own.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Whiska.CLI
  alias Whiska.Install

  setup do
    previous = Application.get_env(:whiska, :user_home)
    root = Path.join(System.tmp_dir!(), "whiska-link-#{Whiska.Test.Unique.id()}")
    home = Path.join(root, "home")
    # Inside the home, as a dotfiles repo usually is: "resolves outside the
    # home" is not the same as "reached through a link".
    dotfiles = Path.join(home, "dotfiles")
    File.mkdir_p!(Path.join(home, ".claude"))
    File.mkdir_p!(dotfiles)
    Application.put_env(:whiska, :user_home, home)

    on_exit(fn ->
      Application.put_env(:whiska, :user_home, previous)
      File.rm_rf!(root)
    end)

    {:ok, home: home, dotfiles: dotfiles}
  end

  defp init_global, do: capture_io(fn -> assert CLI.run(["init", "--global"], nil) == 0 end)

  defp link(target, link_path) do
    File.ln_s!(target, link_path)
    assert {:ok, _} = :file.read_link(link_path)
  end

  defp still_a_link?(path), do: match?({:ok, _}, :file.read_link(path))

  test "a symlinked settings.json is written through, not replaced", %{
    home: home,
    dotfiles: dotfiles
  } do
    target = Path.join(dotfiles, "settings.json")
    File.write!(target, JSON.encode!(%{"model" => "opus"}))
    link(target, Path.join(home, ".claude/settings.json"))

    init_global()

    assert still_a_link?(Path.join(home, ".claude/settings.json"))
    settings = target |> File.read!() |> JSON.decode!()
    assert settings["model"] == "opus"
    assert settings["hooks"]["Stop"] != nil
  end

  test "the report says to commit the dotfiles change", %{home: home, dotfiles: dotfiles} do
    File.write!(Path.join(dotfiles, "settings.json"), "{}")
    link(Path.join(dotfiles, "settings.json"), Path.join(home, ".claude/settings.json"))

    assert init_global() =~ "commit"
  end

  test "uninstall leaves a symlink alone rather than unlinking it", %{
    home: home,
    dotfiles: dotfiles
  } do
    skill_target = Path.join(dotfiles, "reply.md")
    File.write!(skill_target, "stale\n")
    File.mkdir_p!(Path.join(home, ".claude/skills/reply"))
    link(skill_target, Path.join(home, ".claude/skills/reply/SKILL.md"))

    init_global()

    output = capture_io(fn -> assert CLI.run(["uninstall", "--global"], nil) == 0 end)

    # A skill file that is a link is left where it is, and said so.
    assert still_a_link?(Path.join(home, ".claude/skills/reply/SKILL.md"))
    assert output =~ "symlink"
  end

  test "a retired skill reached through a symlink is left alone and named, never removed", %{
    home: home,
    dotfiles: dotfiles
  } do
    retired = Path.join(dotfiles, "whiska-questions.md")
    File.write!(retired, "name: whiska-questions\n")
    File.mkdir_p!(Path.join(home, ".claude/skills/whiska-questions"))
    link(retired, Path.join(home, ".claude/skills/whiska-questions/SKILL.md"))

    output = init_global()

    assert still_a_link?(Path.join(home, ".claude/skills/whiska-questions/SKILL.md"))
    assert File.read!(retired) == "name: whiska-questions\n"
    assert output =~ ".claude/skills/whiska-questions/SKILL.md"
    assert output =~ "symlink"
  end

  test "uninstall does not delete through a symlinked parent directory", %{
    home: home,
    dotfiles: dotfiles
  } do
    # ~/.claude/skills is commonly one link into a dotfiles repo, rather than a
    # link per skill file. A leaf that is not itself a link still lives there.
    skills = Path.join(dotfiles, "skills")
    File.mkdir_p!(skills)
    File.mkdir_p!(Path.join(skills, "show"))
    File.write!(Path.join(skills, "show/SKILL.md"), "mine\n")
    link(skills, Path.join(home, ".claude/skills"))

    init_global()
    assert File.regular?(Path.join(skills, "show/SKILL.md"))

    output = capture_io(fn -> assert CLI.run(["uninstall", "--global"], nil) == 0 end)

    assert File.regular?(Path.join(skills, "show/SKILL.md"))
    assert output =~ "symlink"
  end

  test "uninstall leaves a worktree skill whose directory links into dotfiles", %{
    home: home,
    dotfiles: dotfiles
  } do
    skill_dir = Path.join(dotfiles, "spawn-worktree")
    File.mkdir_p!(skill_dir)
    File.write!(Path.join(skill_dir, "SKILL.md"), "mine\n")
    File.mkdir_p!(Path.join(home, ".claude/skills"))
    link(skill_dir, Path.join(home, ".claude/skills/spawn-worktree"))

    init_global()
    output = capture_io(fn -> assert CLI.run(["uninstall", "--global"], nil) == 0 end)

    assert File.regular?(Path.join(skill_dir, "SKILL.md"))
    assert still_a_link?(Path.join(home, ".claude/skills/spawn-worktree"))
    assert output =~ "symlink"
  end

  test "a real file is still removed outright", %{home: home} do
    init_global()
    capture_io(fn -> assert CLI.run(["uninstall", "--global"], nil) == 0 end)

    refute File.exists?(Path.join(home, Install.shim_path()))
  end
end
