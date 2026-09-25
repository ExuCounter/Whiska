defmodule Whiska.Rule.SniffTest do
  use ExUnit.Case, async: true

  alias Whiska.Rule.Sniff

  describe "a build mouse is untouched by this rule" do
    test "edits pass through" do
      assert :allow = Sniff.decide("Write", %{"file_path" => "lib/x.ex"}, "build")
      assert :allow = Sniff.decide("Edit", %{"file_path" => "lib/x.ex"}, "build")
    end

    test "mutating shell commands pass through" do
      assert :allow = Sniff.decide("Bash", %{"command" => "rm -rf lib/"}, "build")
    end
  end

  describe "a sniff mouse never writes code (ADR-0018)" do
    test "every edit tool is denied, wherever it points" do
      # Not just edits outside the worktree — all of them.
      for tool <- ~w(Write Edit MultiEdit NotebookEdit) do
        assert {:deny, reason} = Sniff.decide(tool, %{"file_path" => "lib/inside.ex"}, "sniff")
        assert reason =~ "sniff"
      end
    end

    test "a mutating shell command is denied" do
      assert {:deny, _} = Sniff.decide("Bash", %{"command" => "rm -rf lib/"}, "sniff")
      assert {:deny, _} = Sniff.decide("Bash", %{"command" => "echo x > out.txt"}, "sniff")
      assert {:deny, _} = Sniff.decide("Bash", %{"command" => "git commit -m wip"}, "sniff")
    end

    test "a read-only shell command is allowed — investigation is the whole point" do
      assert :allow = Sniff.decide("Bash", %{"command" => "git log --oneline"}, "sniff")
      assert :allow = Sniff.decide("Bash", %{"command" => "grep -rn foo lib/"}, "sniff")
      assert :allow = Sniff.decide("Bash", %{"command" => "ls -la"}, "sniff")
    end

    test "an unreadable command is denied, not guessed at" do
      assert {:deny, _} = Sniff.decide("Bash", %{"command" => "eval \"$CMD\""}, "sniff")
      assert {:deny, _} = Sniff.decide("Bash", %{"command" => "some-unknown-tool"}, "sniff")
    end

    test "reading tools are never touched" do
      assert :allow = Sniff.decide("Read", %{"file_path" => "lib/x.ex"}, "sniff")
      assert :allow = Sniff.decide("Grep", %{"pattern" => "foo"}, "sniff")
      assert :allow = Sniff.decide("Glob", %{"pattern" => "**/*.ex"}, "sniff")
    end

    test "the reason explains the mode and points at the way out" do
      {:deny, reason} = Sniff.decide("Write", %{"file_path" => "lib/x.ex"}, "sniff")

      assert reason =~ "sniff"
      assert reason =~ "whiska mode build"
    end
  end
end
