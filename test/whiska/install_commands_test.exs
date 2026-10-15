defmodule Whiska.InstallCommandsTest do
  @moduledoc """
  The eight one-word commands (ADR-0079): what `whiska init --global` writes
  under the whiska home.
  """
  # One test narrows PATH for the whole VM, which a concurrent `mix` or escript
  # would run under.
  use ExUnit.Case, async: false

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
      dir = Path.join(System.tmp_dir!(), "whiska-cmd-#{Whiska.Test.Unique.id()}")
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

  describe "write_commands/1 — never through a symlink" do
    test "a link where a word would go is skipped and named, and its target untouched" do
      dir = Path.join(System.tmp_dir!(), "whiska-cmdlink-#{Whiska.Test.Unique.id()}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      target = Path.join(dir, "rc")
      File.write!(target, "mine\n")
      File.ln_s!(target, Path.join(dir, "show"))
      path_was = System.get_env("PATH")
      System.put_env("PATH", "/usr/bin:/bin")
      on_exit(fn -> System.put_env("PATH", path_was) end)

      assert {:ok, {written, [{"show", why}]}} = Install.write_commands(dir)
      assert "inbox" in written
      refute "show" in written
      assert why =~ "symlink"
      assert File.read!(target) == "mine\n"
    end
  end
end
