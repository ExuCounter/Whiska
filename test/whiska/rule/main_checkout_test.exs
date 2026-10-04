defmodule Whiska.Rule.MainCheckoutTest do
  use ExUnit.Case, async: true

  alias Whiska.Layout
  alias Whiska.Rule.MainCheckout

  setup do
    root = Path.join(System.tmp_dir!(), "whiska-rule-#{System.unique_integer([:positive])}")
    main = Path.join(root, "myrepo")
    worktree = Path.join(main, "worktrees/feat-thing")
    File.mkdir_p!(Path.join(worktree, "lib"))
    File.mkdir_p!(Path.join(main, "lib"))
    File.write!(Path.join(worktree, ".git"), "gitdir: #{main}/.git/worktrees/feat-thing\n")
    on_exit(fn -> File.rm_rf!(root) end)

    {:ok, layout} = Layout.resolve(worktree)
    {:ok, root: root, main: main, worktree: worktree, layout: layout}
  end

  describe "a folder under worktrees that is no worktree" do
    setup %{main: main} do
      folder = Path.join(main, "worktrees/quality")
      File.mkdir_p!(folder)
      {:ok, layout} = Layout.unplaced(folder)
      {:ok, folder: folder, unplaced: layout}
    end

    test "denies a write into the main checkout", %{main: main, unplaced: layout} do
      input = %{"file_path" => Path.join(main, "lib/leak.ex")}

      assert {:deny, _} = MainCheckout.decide("Write", input, layout)
    end

    test "allows a write below the folder itself", %{folder: folder, unplaced: layout} do
      input = %{"file_path" => Path.join(folder, "notes.md")}

      assert :allow = MainCheckout.decide("Write", input, layout)
    end

    test "says where the call came from without calling it a mouse", %{
      main: main,
      folder: folder,
      unplaced: layout
    } do
      input = %{"file_path" => Path.join(main, "lib/leak.ex")}

      assert {:deny, reason} = MainCheckout.decide("Write", input, layout)
      assert reason =~ folder
      assert reason =~ "no worktree"
      refute reason =~ "this mouse's worktree"
    end
  end

  describe "file-path tools targeting the main checkout" do
    test "denies Write", %{main: main, layout: layout} do
      input = %{"file_path" => Path.join(main, "lib/leak.ex"), "content" => "boom"}

      assert {:deny, reason} = MainCheckout.decide("Write", input, layout)
      assert reason =~ "main checkout"
    end

    test "denies Edit", %{main: main, layout: layout} do
      input = %{"file_path" => Path.join(main, "lib/leak.ex")}

      assert {:deny, _} = MainCheckout.decide("Edit", input, layout)
    end

    test "denies MultiEdit", %{main: main, layout: layout} do
      input = %{"file_path" => Path.join(main, "lib/leak.ex"), "edits" => []}

      assert {:deny, _} = MainCheckout.decide("MultiEdit", input, layout)
    end

    test "denies NotebookEdit, which names its target notebook_path", %{
      main: main,
      layout: layout
    } do
      input = %{"notebook_path" => Path.join(main, "analysis.ipynb")}

      assert {:deny, _} = MainCheckout.decide("NotebookEdit", input, layout)
    end

    test "the deny reason names the offending path and the worktree", %{
      main: main,
      worktree: worktree,
      layout: layout
    } do
      target = Path.join(main, "CONTEXT.md")

      assert {:deny, reason} = MainCheckout.decide("Write", %{"file_path" => target}, layout)
      assert reason =~ target
      assert reason =~ worktree
    end
  end

  describe "file-path tools staying inside the mouse's own worktree" do
    test "allows a write inside the worktree", %{worktree: worktree, layout: layout} do
      input = %{"file_path" => Path.join(worktree, "lib/fine.ex")}

      assert :allow = MainCheckout.decide("Write", input, layout)
    end

    test "allows a write at the worktree root itself", %{worktree: worktree, layout: layout} do
      input = %{"file_path" => Path.join(worktree, "mix.exs")}

      assert :allow = MainCheckout.decide("Write", input, layout)
    end

    test "resolves a relative path against the worktree root", %{layout: layout} do
      assert :allow = MainCheckout.decide("Write", %{"file_path" => "lib/fine.ex"}, layout)
    end

    test "denies a relative path that climbs out into the main checkout", %{layout: layout} do
      # ../../ from <main>/worktrees/feat-thing lands squarely in <main>.
      input = %{"file_path" => "../../CONTEXT.md"}

      assert {:deny, _} = MainCheckout.decide("Write", input, layout)
    end
  end

  describe "no carve-out in v0.0.1 (ADR-0013, as sharpened)" do
    test "denies the main checkout's CLAUDE.md", %{main: main, layout: layout} do
      # ADR-0013 carves out Whiska's own config files, but only for the MAIN
      # SESSION editing its own repo's setup. A mouse reaching in from a worktree
      # is the containment breach the ADR exists to stop, so: no carve-out here.
      input = %{"file_path" => Path.join(main, "CLAUDE.md")}

      assert {:deny, _} = MainCheckout.decide("Write", input, layout)
    end

    test "denies the main checkout's .whiska config directory", %{main: main, layout: layout} do
      input = %{"file_path" => Path.join(main, ".whiska/dispatch.yml")}

      assert {:deny, _} = MainCheckout.decide("Write", input, layout)
    end
  end

  describe "another mouse's worktree" do
    test "denies writing into a sibling worktree", %{main: main, layout: layout} do
      sibling = Path.join(main, "worktrees/other-branch/lib/x.ex")

      assert {:deny, _} = MainCheckout.decide("Write", %{"file_path" => sibling}, layout)
    end
  end

  describe "paths outside the repo entirely" do
    test "allows them — the rule is about the main checkout, not a sandbox", %{layout: layout} do
      assert :allow =
               MainCheckout.decide("Write", %{"file_path" => "/etc/whiska-scratch"}, layout)
    end
  end

  describe "Bash reaching into the main checkout (ADR-0013)" do
    test "denies a mutating command that names the main checkout", %{main: main, layout: layout} do
      input = %{"command" => "sed -i '' s/a/b/ #{main}/CONTEXT.md"}

      assert {:deny, reason} = MainCheckout.decide("Bash", input, layout)
      assert reason =~ "main checkout"
    end

    test "denies a redirect into the main checkout", %{main: main, layout: layout} do
      input = %{"command" => "echo boom > #{main}/lib/leak.ex"}

      assert {:deny, _} = MainCheckout.decide("Bash", input, layout)
    end

    test "denies git -C pointed at the main checkout", %{main: main, layout: layout} do
      input = %{"command" => "git -C #{main} commit -am wip"}

      assert {:deny, _} = MainCheckout.decide("Bash", input, layout)
    end

    test "ALLOWS reading the main checkout — the rule contains changes, not reads", %{
      main: main,
      layout: layout
    } do
      assert :allow =
               MainCheckout.decide("Bash", %{"command" => "cat #{main}/CONTEXT.md"}, layout)

      assert :allow =
               MainCheckout.decide("Bash", %{"command" => "grep -rn foo #{main}/lib"}, layout)

      assert :allow =
               MainCheckout.decide("Bash", %{"command" => "git -C #{main} log --oneline"}, layout)
    end

    test "allows a mutating command confined to the mouse's own worktree", %{
      worktree: worktree,
      layout: layout
    } do
      assert :allow =
               MainCheckout.decide("Bash", %{"command" => "rm -rf #{worktree}/_build"}, layout)

      assert :allow = MainCheckout.decide("Bash", %{"command" => "mix format"}, layout)
      assert :allow = MainCheckout.decide("Bash", %{"command" => "git commit -am wip"}, layout)
    end

    test "allows a mutating command aimed outside the repo entirely", %{layout: layout} do
      assert :allow =
               MainCheckout.decide("Bash", %{"command" => "rm /tmp/whiska-scratch"}, layout)
    end

    test "resolves a relative path against the worktree before judging", %{layout: layout} do
      assert {:deny, _} =
               MainCheckout.decide(
                 "Bash",
                 %{"command" => "sed -i '' s/a/b/ ../../CONTEXT.md"},
                 layout
               )

      assert :allow =
               MainCheckout.decide("Bash", %{"command" => "sed -i '' s/a/b/ lib/mine.ex"}, layout)
    end

    test "denies a sibling worktree", %{main: main, layout: layout} do
      input = %{"command" => "rm -rf #{main}/worktrees/other-branch/lib"}

      assert {:deny, _} = MainCheckout.decide("Bash", input, layout)
    end
  end

  describe "Bash spellings of a main-checkout path (ADR-0013, ADR-0034)" do
    # MAIN is the main checkout, WT this mouse's worktree. HOME is the test's
    # root, so HOME_MAIN and HOME_BRACED spell the main checkout through it.
    @denied [
      {"a stderr redirect", "echo x 2>MAIN/f"},
      {"a stdout-and-stderr redirect", "echo x &>MAIN/f"},
      {"an append with no space", "echo x >>MAIN/f"},
      {"a clobbering redirect", "echo x >|MAIN/f"},
      {"a numbered redirect with a space", "echo x 2> MAIN/f"},
      {"dd's of=", "dd if=/dev/zero of=MAIN/f count=1"},
      {"a long option with =", "curl --output=MAIN/f https://example.com"},
      {"a quoted target", ~S(touch "MAIN/f")},
      {"$HOME", "rm HOME_MAIN/f"},
      {"${HOME}", "rm HOME_BRACED/f"},
      {"$HOME in double quotes", ~S(rm "HOME_MAIN/f")},
      {"$HOME after of=", "dd if=/dev/zero of=HOME_MAIN/f"},
      {"a nested shell", ~S(bash -c 'rm MAIN/f')},
      {"a nested shell redirecting", ~S(sh -c "echo x > MAIN/f")},
      {"cd into main, then a bare relative name", "cd MAIN && rm CONTEXT.md"},
      {"cd up into main, then a bare relative name", "cd ../.. && rm CONTEXT.md"},
      {"cd into main, then a relative redirect", "cd MAIN; echo x > notes.md"},
      {"cd into main, then a build", "cd MAIN && mix compile"},
      {"a relative redirect climbing out", "echo x 2>../../f"},
      {"cd with -P", "cd -P MAIN && rm CONTEXT.md"},
      {"cd with --", "cd -- MAIN && rm CONTEXT.md"},
      {"cd behind command", "command cd MAIN && rm CONTEXT.md"},
      {"cd behind an assignment", "CDPATH= cd MAIN && rm CONTEXT.md"},
      {"cd to a path with an empty quote", ~S(cd MAIN"" && rm CONTEXT.md)},
      {"quotes inside the path", "rm SPLIT_QUOTES/f"},
      {"a backslash inside the path", "rm SPLIT_BACKSLASH/f"},
      {"${HOME:-…}", "rm ${HOME:-/nowhere}/myrepo/f"},
      {"a bare name from the parent folder", "cd ROOT && rm -rf myrepo"},
      {"removing a folder above the main checkout", "rm -rf ROOT"},
      {"env inside a subshell", "(env rm MAIN/f)"}
    ]

    @allowed [
      {"discarding stderr", "mix test 2>/dev/null"},
      {"merging stderr", "mix test 2>&1 | tail -5"},
      {"a relative redirect", "mix test > out.txt 2>&1"},
      {"dd into the worktree", "dd if=/dev/zero of=build/f count=1"},
      {"an env assignment", "MIX_ENV=test mix compile"},
      {"cd within the worktree", "cd lib && rm old.ex"},
      {"cd into main to read", "cd MAIN && git log --oneline"},
      {"cd into main to read, then back to write", "cd MAIN && cat CONTEXT.md; cd WT && touch x"},
      {"cd elsewhere to write", "cd /tmp && rm -f whiska-scratch"},
      {"writing under $HOME, outside the repo", "rm -f $HOME/.cache/whiska-scratch"},
      {"writing under ~, outside the repo", "rm -f ~/.cache/whiska-scratch"},
      {"a nested shell inside the worktree", ~S(bash -c 'mix test')},
      {"an absolute path into the worktree", "rm -rf WT/_build"},
      {"an unknown variable", "rm -rf $TMPDIR/whiska-scratch"},
      {"reading main with git -C", "git -C MAIN log --oneline"},
      {"a pattern full of slashes", ~S(sed -i '' 's/a\/b/c/' lib/x.ex)},
      {"cd into main inside a subshell, then a write", "(cd MAIN && git log); rm build/x"},
      {"cd into main inside a subshell, then a build", "(cd MAIN && git status) && mix test"},
      {"a bare name from inside the worktree", "rm -rf myrepo"}
    ]

    defp spell(command, %{root: root, main: main, worktree: worktree}) do
      command
      |> String.replace("SPLIT_QUOTES", String.replace(main, "myrepo", ~S(my"re"po)))
      |> String.replace("SPLIT_BACKSLASH", String.replace(main, "myrepo", ~S(my\repo)))
      |> String.replace("ROOT", root)
      |> String.replace("HOME_MAIN", "$HOME/myrepo")
      |> String.replace("HOME_BRACED", "${HOME}/myrepo")
      |> String.replace("MAIN", main)
      |> String.replace("WT", worktree)
    end

    for {name, command} <- @denied do
      test "denies #{name}", context do
        command = spell(unquote(command), context)

        assert {:deny, _} =
                 MainCheckout.decide("Bash", %{"command" => command}, context.layout,
                   home: context.root
                 ),
               "expected a denial for: #{command}"
      end
    end

    for {name, command} <- @allowed do
      test "allows #{name}", context do
        command = spell(unquote(command), context)

        assert :allow =
                 MainCheckout.decide("Bash", %{"command" => command}, context.layout,
                   home: context.root
                 ),
               "expected no denial for: #{command}"
      end
    end
  end

  describe "Bash runs where the shell stands, not where the mouse started (ADR-0053)" do
    test "denies a write while standing in the main checkout", %{main: main, layout: layout} do
      for command <- ["rm CONTEXT.md", "echo x > notes.md", "mix compile"] do
        assert {:deny, reason} =
                 MainCheckout.decide("Bash", %{"command" => command}, layout, cwd: main),
               "expected a denial for: #{command}"

        assert reason =~ main
      end
    end

    test "says to step back into the worktree", %{
      main: main,
      worktree: worktree,
      layout: layout
    } do
      assert {:deny, reason} =
               MainCheckout.decide("Bash", %{"command" => "rm CONTEXT.md"}, layout, cwd: main)

      assert reason =~ "cd #{worktree}"
    end

    test "allows reads while standing in the main checkout", %{main: main, layout: layout} do
      for command <- ["cat CONTEXT.md", "git status", "grep -rn foo lib/"] do
        assert :allow = MainCheckout.decide("Bash", %{"command" => command}, layout, cwd: main)
      end
    end

    test "allows a write once the command steps back into the worktree", %{
      main: main,
      worktree: worktree,
      layout: layout
    } do
      command = "cd #{worktree} && rm lib/old.ex"

      assert :allow = MainCheckout.decide("Bash", %{"command" => command}, layout, cwd: main)
    end

    test "resolves a relative path against where the shell stands", %{
      worktree: worktree,
      layout: layout
    } do
      cwd = Path.join(worktree, "lib")
      out_to_main = %{"command" => "rm " <> Path.join(["..", "..", "..", "CONTEXT.md"])}

      assert {:deny, _} = MainCheckout.decide("Bash", out_to_main, layout, cwd: cwd)

      assert :allow =
               MainCheckout.decide("Bash", %{"command" => "rm ../mix.exs"}, layout, cwd: cwd)
    end
  end

  describe "tools this slice deliberately does not police" do
    test "allows reads of the main checkout", %{main: main, layout: layout} do
      assert :allow =
               MainCheckout.decide(
                 "Read",
                 %{"file_path" => Path.join(main, "CONTEXT.md")},
                 layout
               )

      assert :allow = MainCheckout.decide("Grep", %{"path" => main}, layout)
      assert :allow = MainCheckout.decide("Glob", %{"path" => main}, layout)
    end
  end

  describe "malformed input" do
    test "allows a file-path tool with no path at all", %{layout: layout} do
      assert :allow = MainCheckout.decide("Write", %{}, layout)
      assert :allow = MainCheckout.decide("Write", %{"file_path" => nil}, layout)
    end
  end

  describe "symlinked paths" do
    test "denies through a symlink pointing at the main checkout", %{
      root: root,
      main: main,
      layout: layout
    } do
      link = Path.join(root, "link-to-main")

      case File.ln_s(main, link) do
        :ok ->
          input = %{"file_path" => Path.join(link, "CONTEXT.md")}
          assert {:deny, _} = MainCheckout.decide("Write", input, layout)

        {:error, _} ->
          # Symlink creation unavailable; nothing to assert.
          :ok
      end
    end
  end
end
