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
    on_exit(fn -> File.rm_rf!(root) end)

    {:ok, layout} = Layout.resolve(worktree)
    {:ok, root: root, main: main, worktree: worktree, layout: layout}
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
      input = %{"file_path" => Path.join(main, ".whiska/checks.yml")}

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

  describe "tools this slice deliberately does not police" do
    test "allows Bash even when the command names the main checkout", %{
      main: main,
      layout: layout
    } do
      # KNOWN HOLE, accepted for v0.0.1: `sed -i`, `cat >`, `git -C <main>` can
      # still reach the main checkout. Deciding mutating-vs-reading for an
      # arbitrary shell string is the same judgment sniff mode needs (ADR-0018),
      # and it gets built once, there, rather than badly here.
      input = %{"command" => "sed -i '' s/a/b/ #{main}/CONTEXT.md"}

      assert :allow = MainCheckout.decide("Bash", input, layout)
    end

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
