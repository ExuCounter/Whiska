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

  describe "env and command run the command after them (ADR-0069)" do
    # Both are on the read-only list for what they do alone — print the
    # environment, say where a command lives. Followed by a command, they run
    # it, and that command is the one to judge, or a sniff mouse, or one
    # nobody shaped, could run `env whiska mode build` and shape itself.
    test "the wrapped command is judged" do
      assert Shell.mutating?("env whiska mode build")
      assert Shell.mutating?("/usr/bin/env whiska mode build")
      assert Shell.mutating?("env FOO=1 whiska shape build")
      assert Shell.mutating?("env -i rm -rf lib")
      assert Shell.mutating?("env -u HOME whiska mode build")
      assert Shell.mutating?("command whiska mode build")
      assert Shell.mutating?("command -p rm x")
      assert Shell.mutating?("find . -exec env rm {} \\;")
      refute Shell.mutating?("env git log")
      refute Shell.mutating?("command grep -r x lib")
    end

    test "alone, or only asking, they stay read-only" do
      refute Shell.mutating?("env")
      refute Shell.mutating?("env | grep PATH")
      refute Shell.mutating?("command -v git")
      refute Shell.mutating?("command -V mix")
    end

    test "an env flag it cannot read is assumed to run something" do
      assert Shell.mutating?(~s(env -S "rm -rf lib"))
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

  describe "shell builtins that only move around" do
    # Found by running the installed hook: `cd <main> && git status` was denied
    # from inside a worktree. `cd` changes no file, but it was missing from the
    # allowlist, so the segment read as mutating and the rule saw a command that
    # both mutated and named the main checkout.
    test "cd reads" do
      refute Shell.mutating?("cd /tmp")
      refute Shell.mutating?("cd /tmp && git status")
      refute Shell.mutating?("(cd /tmp && git status)")
      assert Shell.mutating?("(cd /tmp && rm x)")
      assert Shell.mutating?("(env rm x)")
      refute Shell.mutating?("(env git log)")
      assert Shell.mutating?("cat <(rm x; true)")
      assert Shell.mutating?("(cat <(rm x))")
      assert Shell.mutating?("cat <(rm x)")
      refute Shell.mutating?("pushd /tmp")
      refute Shell.mutating?("popd")
    end

    test "but cd does not launder what follows it" do
      assert Shell.mutating?("cd /tmp && rm -rf x")
      assert Shell.mutating?("cd /tmp && touch x")
    end
  end

  # A command on the read-only list reads until a flag, an extra operand or an
  # environment variable makes it write or run something (ADR-0034). Each case
  # below that writes was run against the real tool on macOS before it went in;
  # the ones marked GNU or by tool name follow that tool's documentation.
  describe "read-only commands that a flag or an operand makes write" do
    for command <- [
          # sort: an output file, and a program it runs to compress temp files
          "sort -o out.txt in.txt",
          "sort -no out.txt in.txt",
          "sort -oout.txt in.txt",
          "sort --output=out.txt in.txt",
          "sort --out=out.txt in.txt",
          "sort --compress-program=gzip in.txt",
          # uniq and xxd: a second operand is the output file
          "uniq a b",
          "uniq -c a b",
          "uniq -f 1 a b",
          "uniq - b",
          "uniq -- a b",
          "xxd a b",
          "xxd -r dump.hex bin",
          "xxd -c 8 a b",
          # yq: in place, and splitting into files
          "yq -i .a f.yml",
          "yq -Pi .a f.yml",
          "yq --inplace .a f.yml",
          "yq --in-place .a f.yml",
          "yq -s '.name' f.yml",
          "yq --split-exp '.name' f.yml",
          # file: compiling a magic file writes magic.mgc
          "file -C -m magic",
          "file --compile -m magic",
          # tree: an output file, and -R writes 00Tree.html into every folder
          "tree -o out.txt",
          "tree -ao out.txt",
          "tree -R -H . lib",
          # xmllint: an output file, and a shell that can save
          "xmllint --output out.xml a.xml",
          "xmllint -o out.xml a.xml",
          "xmllint -output out.xml a.xml",
          "xmllint --shell a.xml",
          # less and more: a log file, and commands run on start
          "less -o log.txt in.txt",
          "less -Olog.txt in.txt",
          "less --log-file=log.txt in.txt",
          "more -o log.txt in.txt",
          "less '+!rm x' in.txt",
          # tools that run a command named in a flag
          "rg --pre ./pre.sh foo lib/",
          "rg --pre=./pre.sh foo lib/",
          "rg --hostname-bin ./h.sh foo lib/",
          "ag --pager 'rm x' foo lib/",
          "ag --pag=x foo lib/",
          "man -P 'rm x' ls",
          "man --pager='rm x' ls",
          "man -H ls",
          "fd -x rm",
          "fd -e tmp -x rm {}",
          "fd -X rm",
          "fd --exec rm",
          "fd --exec-batch rm",
          "fd -Hx rm",
          ~S[fd -x grep foo \; -x rm],
          "fd --exec=rm",
          "arch -arm64 rm x",
          "arch -x86_64 touch x",
          # system state, which takes root but is still a write
          "hostname newname",
          "hostname -F /etc/hostname",
          "date 0101000099",
          "date -s 2020-01-01",
          "date --set=2020-01-01",
          "date -f %Y 2020",
          # git: an output file, config that names a program, and reflog's writers
          "git diff --output=/tmp/x",
          "git diff --output /tmp/x",
          "git log -p --output=/tmp/x",
          "git show --output=/tmp/x HEAD",
          "git -c diff.external=./x diff",
          "git -c core.fsmonitor=./x status",
          "git --config-env=core.pager=X log",
          "git grep -O'rm x' foo",
          "git grep --open-files-in-pager=x foo",
          "git ls-remote --upload-pack=./x .",
          "git reflog expire --all",
          "git reflog delete HEAD@{1}",
          "git reflog drop main",
          # environment variables that carry a program to run
          "GIT_EXTERNAL_DIFF=./x git diff",
          "GIT_CONFIG_PARAMETERS=x git log",
          "env GIT_EXTERNAL_DIFF=./x git diff",
          "LESSOPEN='|./x' less in.txt",
          "MANPAGER=./x man ls",
          "PAGER=./x man ls",
          "RIPGREP_CONFIG_PATH=./rc rg foo"
        ] do
      test "#{command} writes" do
        assert Shell.mutating?(unquote(command))
      end
    end

    # The other half matters as much: a check that denies these leaves a sniff
    # mouse unable to look at anything.
    for command <- [
          "sort in.txt",
          "sort -n -k2 in.txt",
          "sort -t o in.txt",
          "sort -to in.txt",
          "sort -u -T /tmp in.txt",
          "uniq in.txt",
          "uniq -c in.txt",
          "uniq -f 1 in.txt",
          "uniq --skip-fields 1 in.txt",
          "uniq -",
          "cat in.txt | sort | uniq -c",
          "xxd mix.exs",
          "xxd -s 16 -l 32 mix.exs",
          "xxd -c16 mix.exs",
          "xxd -r dump.hex",
          "yq .a f.yml",
          "yq -o=json .a f.yml",
          "yq -o json .a f.yml",
          "yq -ojson .a f.yml",
          "yq -P -I2 .a f.yml",
          "file mix.exs",
          "file -b --mime-type mix.exs",
          "tree",
          "tree -L 2 lib",
          "tree -a -I _build",
          "xmllint --format a.xml",
          "xmllint --noout --schema s.xsd a.xml",
          "less in.txt",
          "less -R in.txt",
          "more in.txt",
          "rg -n foo lib/",
          "rg --pre-glob '*.gz' foo lib/",
          "rg --no-pre foo lib/",
          "ag foo lib/",
          "man ls",
          "man -k grep",
          "man 1 ls",
          "fd -e ex",
          "fd -o root",
          "fd -t f -x grep -l foo",
          ~S[fd -x grep foo \; -e ex],
          "arch",
          "arch -arm64 ls",
          "hostname",
          "hostname -s",
          "date",
          "date +%s",
          "date -u '+%Y-%m-%d %H:%M'",
          "date -r 0",
          "date -d yesterday +%F",
          "date -j -f %Y 2020 +%s",
          "date -v+1d",
          "join -o 1.1,2.2 a.txt b.txt",
          "strings -o bin",
          "cut -d , -f 1 --output-delimiter=: a.csv",
          "git diff",
          "git diff --stat HEAD~1",
          "git log --output-indicator-new=+ -p",
          "git diff -O order.txt",
          "git grep -n foo",
          "git reflog",
          "git reflog show HEAD",
          "git reflog main",
          "git ls-remote origin",
          "LC_ALL=C sort in.txt",
          "NO_COLOR=1 rg foo lib/"
        ] do
      test "#{command} reads" do
        refute Shell.mutating?(unquote(command))
      end
    end
  end
end
