defmodule Whiska.ShellTest do
  use ExUnit.Case, async: true

  alias Whiska.Shell

  # The governing principle: anything this module cannot confidently read is
  # reported as mutating. A sniff mouse must never write code, so a command we
  # do not understand has to be treated as the dangerous case, not the safe one.

  describe "plainly read-only commands" do
    for command <- [
          "ls -la",
          "cat README.md",
          "head -20 mix.exs",
          "grep -rn foo lib/",
          "rg --json pattern",
          "find . -name '*.ex'",
          "wc -l lib/whiska.ex",
          "pwd",
          "echo hello",
          "sort lib/a.txt",
          "diff a.txt b.txt",
          "jq '.foo' data.json",
          "stat mix.exs",
          "sed 's/a/b/' input.txt"
        ] do
      test "#{command}" do
        refute Shell.mutating?(unquote(command))
      end
    end
  end

  describe "plainly mutating commands" do
    for command <- [
          "rm -rf lib/",
          "mv a.ex b.ex",
          "cp a.ex b.ex",
          "touch new.ex",
          "mkdir -p lib/foo",
          "chmod +x script.sh",
          "sed -i '' s/a/b/ file.txt",
          "sed --in-place s/a/b/ file.txt",
          "tee output.txt",
          "mix format",
          "npm install"
        ] do
      test "#{command}" do
        assert Shell.mutating?(unquote(command))
      end
    end
  end

  describe "redirections write files even when the command reads" do
    test "truncating redirect" do
      assert Shell.mutating?("cat a.txt > b.txt")
    end

    test "appending redirect" do
      assert Shell.mutating?("echo hi >> log.txt")
    end

    test "a redirect on stderr still creates a file" do
      assert Shell.mutating?("grep foo bar 2> errors.txt")
    end

    test "but a file-descriptor duplication does not" do
      refute Shell.mutating?("grep foo bar 2>&1")
      refute Shell.mutating?("ls -la 1>&2")
    end

    test "and reading from a file does not" do
      refute Shell.mutating?("grep foo < input.txt")
    end
  end

  describe "git, which is read-only or not depending on the subcommand" do
    for command <- [
          "git log --oneline -5",
          "git diff HEAD",
          "git status --short",
          "git show abc123",
          "git blame lib/whiska.ex",
          "git rev-parse --show-toplevel",
          "git ls-files"
        ] do
      test "#{command} reads" do
        refute Shell.mutating?(unquote(command))
      end
    end

    for command <- [
          "git commit -m wip",
          "git push origin main",
          "git add .",
          "git checkout -b feat/x",
          "git reset --hard",
          "git clean -fd",
          "git stash",
          "git branch -d old",
          "git config user.name x"
        ] do
      test "#{command} mutates" do
        assert Shell.mutating?(unquote(command))
      end
    end
  end

  describe "compound commands — every part has to be safe" do
    test "a read-only chain stays read-only" do
      refute Shell.mutating?("ls -la && git status && cat README.md")
    end

    test "one mutating part taints the whole chain" do
      assert Shell.mutating?("ls -la && rm -rf lib/")
      assert Shell.mutating?("cat a.txt; touch b.txt")
      assert Shell.mutating?("grep foo bar || echo fail > log.txt")
    end

    test "a pipe into a mutating command is caught" do
      assert Shell.mutating?("cat a.txt | tee b.txt")
      refute Shell.mutating?("cat a.txt | grep foo | wc -l")
    end
  end

  describe "constructs we cannot read are treated as mutating" do
    for command <- [
          "eval \"$CMD\"",
          "bash -c 'rm -rf /'",
          "sh -c 'echo hi'",
          "xargs rm",
          "echo $(rm -rf lib)",
          "echo `rm -rf lib`",
          "exec rm file"
        ] do
      test "#{command}" do
        assert Shell.mutating?(unquote(command))
      end
    end

    test "an unrecognised command is assumed to mutate" do
      assert Shell.mutating?("some-unknown-tool --do-things")
    end

    test "an empty command is not mutating" do
      refute Shell.mutating?("")
      refute Shell.mutating?("   ")
    end
  end

  describe "leading environment assignments" do
    test "are stepped over to find the real command" do
      refute Shell.mutating?("MIX_ENV=test git log")
      assert Shell.mutating?("MIX_ENV=test rm -rf _build")
    end
  end

  describe "paths/1 — which paths a command names" do
    test "picks out absolute and relative paths" do
      assert "/etc/hosts" in Shell.paths("cat /etc/hosts")
      assert "lib/whiska.ex" in Shell.paths("grep foo lib/whiska.ex")
      assert "./local.ex" in Shell.paths("cat ./local.ex")
    end

    test "sees the target of a redirect" do
      assert "out/log.txt" in Shell.paths("echo hi > out/log.txt")
    end

    test "sees a path given to git -C" do
      assert "/main/checkout" in Shell.paths("git -C /main/checkout commit -m x")
    end

    test "strips surrounding quotes" do
      assert "/a path/file.ex" in Shell.paths(~s|cat "/a path/file.ex"|)
      assert "/a path/file.ex" in Shell.paths(~s|cat '/a path/file.ex'|)
    end

    test "ignores flags and bare words that are not paths" do
      paths = Shell.paths("grep -rn --color foo lib/")
      refute "-rn" in paths
      refute "--color" in paths
      refute "foo" in paths
      assert "lib/" in paths
    end
  end

  # The describes below are the false denials found by reading the module against
  # real shell usage. Most are the same underlying mistake: matching a regex
  # against the raw command string, which cannot tell an operator from an
  # ordinary character inside a quoted argument.

  describe "quoting — an operator inside quotes is not an operator" do
    test "alternation in a quoted regex does not split the command" do
      refute Shell.mutating?(~S[rg "foo|bar" lib/])
      refute Shell.mutating?(~S[rg 'foo|bar' lib/])
    end

    test "a fat arrow in a search pattern is not a redirect" do
      refute Shell.mutating?(~S[grep -r "=>" lib/])
      refute Shell.mutating?(~S[git log --grep="fix > bug"])
    end

    test "a semicolon or ampersand inside quotes does not split the command" do
      refute Shell.mutating?(~S[rg "a;b" lib/])
      refute Shell.mutating?(~S[rg "a && b" lib/])
    end

    test "but a real redirect outside quotes still writes" do
      assert Shell.mutating?(~S[rg "foo|bar" lib/ > out.txt])
    end

    test "a substitution is literal in single quotes and live in double" do
      refute Shell.mutating?(~S[grep '$(rm -rf /)' lib/])
      assert Shell.mutating?(~S[echo "$(rm -rf lib)"])
    end
  end

  describe "find — judged by its action, not by the letters in a flag" do
    test "an -exec running a read-only command reads" do
      refute Shell.mutating?(~S[find . -name '*.ex' -exec grep -l foo {} \;])
    end

    test "an -exec running a mutating command mutates" do
      assert Shell.mutating?(~S[find . -name '*.tmp' -exec rm {} \;])
    end

    test "-delete mutates" do
      assert Shell.mutating?(~S[find . -name '*.tmp' -delete])
    end

    # The escaped `\;` that ends an -exec clause has to be recognised as a
    # terminator, or everything after the first clause goes unread — and an
    # unread clause is reported read-only, which is the direction ADR-0034
    # exists to prevent.
    test "a later -exec clause is still judged" do
      assert Shell.mutating?(~S[find . -exec grep -l foo {} \; -exec rm {} \;])
    end
  end

  describe "a keyword as an argument is not a keyword" do
    test "searching for the word exec or eval reads" do
      refute Shell.mutating?("grep -rn exec lib/")
      refute Shell.mutating?("cat lib/eval.ex")
    end
  end

  describe "awk, which reads unless its program writes" do
    test "a printing program reads" do
      refute Shell.mutating?(~S[awk '{print $1}' data.txt])
    end

    test "a program that redirects or shells out mutates" do
      assert Shell.mutating?(~S[awk '{print > "out.txt"}' data.txt])
      assert Shell.mutating?(~S[awk 'BEGIN{system("rm -rf /")}'])
    end
  end

  describe "read-only tools that were missing from the allowlist" do
    for command <- ["shasum -a 256 mix.exs", "ps aux", "od -c mix.exs", "id -u"] do
      test "#{command}" do
        refute Shell.mutating?(unquote(command))
      end
    end
  end
end
