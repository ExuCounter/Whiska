defmodule Whiska.InstallCommandsTest do
  @moduledoc """
  The eight one-word commands and their slash commands
  (ADR-next-the-person-decides-what-reaches-them): what `whiska init --global`
  writes under the whiska home and under `~/.claude/skills`, and the two skills
  it stops shipping.
  """
  use ExUnit.Case, async: true

  alias Whiska.Install

  @words ~w(inbox show reply dismiss focus away hold resume)

  describe "commands/0 — the words, and the script behind each" do
    test "are the eight, and jump is not one of them" do
      assert Install.commands() == @words
    end

    test "the directory is `bin` under the whiska home, never ~/.local/bin" do
      assert Install.commands_dir() == Path.join(Whiska.OpenHouses.home(), "bin")
    end

    test "each script resolves whiska the way the shim does and execs the long command" do
      for word <- @words do
        script = Install.command_script(word)
        assert String.starts_with?(script, "#!/usr/bin/env bash\n")
        assert script =~ Install.resolve_whiska()
        assert script =~ ~s|exec "$whiska_bin" #{word} "$@"|
        refute script =~ "/Users/"
      end
    end

    test "a script, actually run, hands its word and arguments to whiska" do
      dir = Path.join(System.tmp_dir!(), "whiska-cmd-#{System.unique_integer([:positive])}")
      bin = Path.join(dir, "bin")
      File.mkdir_p!(bin)
      on_exit(fn -> File.rm_rf!(dir) end)

      fake = Path.join(bin, "whiska")
      File.write!(fake, ~s(#!/bin/sh\nprintf '%s\\n' "$@"\n))
      File.chmod!(fake, 0o755)

      script = Path.join(dir, "reply")
      File.write!(script, Install.command_script("reply"))
      File.chmod!(script, 0o755)

      {out, 0} =
        System.cmd(script, ["12", "go", "with", "it"],
          env: [{"PATH", bin <> ":" <> System.get_env("PATH")}, {"WHISKA_BIN", nil}]
        )

      assert out == "reply\n12\ngo\nwith\nit\n"
    end
  end

  describe "skills/0 — one slash command per word (ADR-0022)" do
    test "ships a skill named by each word, a thin wrapper around the fixed command" do
      for word <- @words do
        assert {_path, body} =
                 List.keyfind(Install.skills(), ".claude/skills/#{word}/SKILL.md", 0),
               "#{word} has no skill"

        assert body =~ "name: #{word}\n"
        assert body =~ "whiska #{word}"
      end
    end

    test "the two long-named skills are no longer shipped, and are named as retired" do
      for name <- ~w(whiska-questions whiska-reply) do
        refute List.keyfind(Install.skills(), ".claude/skills/#{name}/SKILL.md", 0)
        assert ".claude/skills/#{name}/SKILL.md" in Install.retired_skills()
      end

      assert {_path, _body} =
               List.keyfind(Install.skills(), ".claude/skills/whiska-delivered/SKILL.md", 0)
    end

    test "/show reads everything in full with no argument, one by id with one, and offers the picker" do
      {_path, body} = List.keyfind(Install.skills(), ".claude/skills/show/SKILL.md", 0)
      assert body =~ "whiska show\n"
      assert body =~ "whiska show $ARGUMENTS"
      assert body =~ "AskUserQuestion"
      assert body =~ "cannot see"
      assert body =~ "verbatim"
      assert body =~ "no fence"
      assert body =~ ~r/never reply/
    end

    test "/reply carries the person's own words and nothing else" do
      {_path, body} = List.keyfind(Install.skills(), ".claude/skills/reply/SKILL.md", 0)
      assert body =~ "whiska reply $ARGUMENTS"
      assert body =~ "own words"
      assert body =~ "herdr agent prompt"
      assert body =~ "frees the slot"
    end

    test "/inbox is machine-wide and says so, and runs only when typed" do
      {_path, body} = List.keyfind(Install.skills(), ".claude/skills/inbox/SKILL.md", 0)
      assert body =~ "whiska inbox"
      assert body =~ ~r/every repo|across/i
      assert body =~ ~r/only when the person types/i
    end

    test "/away, /focus, /hold and /resume run the command and show what it said" do
      for word <- ~w(away focus hold resume) do
        {_path, body} = List.keyfind(Install.skills(), ".claude/skills/#{word}/SKILL.md", 0)
        assert body =~ "whiska #{word}", word
        assert body =~ "verbatim", word
      end

      {_path, hold} = List.keyfind(Install.skills(), ".claude/skills/hold/SKILL.md", 0)
      assert hold =~ "whiska hold $ARGUMENTS"
      {_path, resume} = List.keyfind(Install.skills(), ".claude/skills/resume/SKILL.md", 0)
      assert resume =~ "whiska resume $ARGUMENTS"
    end

    test "the finished picker lands a branch by cherry-pick, not by merge" do
      {_path, body} =
        List.keyfind(Install.skills(), ".claude/skills/whiska-delivered/SKILL.md", 0)

      assert body =~ "Land here"
      assert body =~ "cherry-pick"
      assert body =~ ~r/oldest first/
      assert body =~ ~r/skipping .*merges/
      refute body =~ "--no-ff"
      refute body =~ "Merge here"
      assert body =~ "finish: land here"
    end
  end
end
