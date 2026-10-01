defmodule Whiska.CLIInitGlobalSymlinkTest do
  @moduledoc """
  `~/.claude/CLAUDE.md`, `~/.claude/settings.json` and `~/.claude/skills` are
  commonly symlinks into a dotfiles repo. A write that replaces the link with a
  plain file disconnects that repo silently: the person keeps editing dotfiles
  and nothing they write reaches Claude Code again.

  So every write the global install makes goes through the link and changes what
  it points at, and `whiska uninstall` leaves a link alone rather than unlinking
  it.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Whiska.CLI
  alias Whiska.Install

  setup do
    previous = Application.get_env(:whiska, :user_home)
    root = Path.join(System.tmp_dir!(), "whiska-link-#{System.unique_integer([:positive])}")
    home = Path.join(root, "home")
    dotfiles = Path.join(root, "dotfiles")
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

  test "a symlinked CLAUDE.md is written through, not replaced", %{home: home, dotfiles: dotfiles} do
    target = Path.join(dotfiles, "CLAUDE.md")
    File.write!(target, "# Mine\n\nPlain language, always.\n")
    link(target, Path.join(home, ".claude/CLAUDE.md"))

    init_global()

    assert still_a_link?(Path.join(home, ".claude/CLAUDE.md"))
    assert File.read!(target) =~ "Plain language, always."
    assert File.read!(target) =~ "<!-- whiska:start -->"
  end

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

  test "a symlinked skills directory keeps its link and gains the skills", %{
    home: home,
    dotfiles: dotfiles
  } do
    target = Path.join(dotfiles, "skills")
    File.mkdir_p!(target)
    link(target, Path.join(home, ".claude/skills"))

    init_global()

    assert still_a_link?(Path.join(home, ".claude/skills"))
    assert File.exists?(Path.join(target, "whiska-questions/SKILL.md"))
  end

  test "a symlinked skill file is written through", %{home: home, dotfiles: dotfiles} do
    target = Path.join(dotfiles, "whiska-finish.md")
    File.write!(target, "stale\n")
    File.mkdir_p!(Path.join(home, ".claude/skills/whiska-finish"))
    link(target, Path.join(home, ".claude/skills/whiska-finish/SKILL.md"))

    init_global()

    assert still_a_link?(Path.join(home, ".claude/skills/whiska-finish/SKILL.md"))
    assert File.read!(target) =~ "whiska-finish"
  end

  test "the report says to commit the dotfiles change", %{home: home, dotfiles: dotfiles} do
    link(Path.join(dotfiles, "CLAUDE.md"), Path.join(home, ".claude/CLAUDE.md"))
    File.write!(Path.join(dotfiles, "CLAUDE.md"), "# Mine\n")

    assert init_global() =~ "commit"
  end

  test "uninstall leaves a symlink alone rather than unlinking it", %{
    home: home,
    dotfiles: dotfiles
  } do
    target = Path.join(dotfiles, "CLAUDE.md")
    File.write!(target, "# Mine\n")
    link(target, Path.join(home, ".claude/CLAUDE.md"))

    skill_target = Path.join(dotfiles, "whiska-reply.md")
    File.write!(skill_target, "stale\n")
    File.mkdir_p!(Path.join(home, ".claude/skills/whiska-reply"))
    link(skill_target, Path.join(home, ".claude/skills/whiska-reply/SKILL.md"))

    init_global()
    output = capture_io(fn -> assert CLI.run(["uninstall", "--global"], nil) == 0 end)

    # The block goes, through the link; the link itself stays.
    assert still_a_link?(Path.join(home, ".claude/CLAUDE.md"))
    refute File.read!(target) =~ "<!-- whiska:start -->"
    assert File.read!(target) =~ "# Mine"

    # A skill file that is a link is left where it is, and said so.
    assert still_a_link?(Path.join(home, ".claude/skills/whiska-reply/SKILL.md"))
    assert output =~ "symlink"
  end

  test "a real file is still removed outright", %{home: home} do
    init_global()
    capture_io(fn -> assert CLI.run(["uninstall", "--global"], nil) == 0 end)

    refute File.exists?(Path.join(home, Install.shim_path()))
  end
end
