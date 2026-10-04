defmodule Whiska.Hook.PreToolUseTest do
  # Serial: the code under test opens the house under the one VM-wide name
  # `Whiska.Repo`, and the tests set HERDR_PANE_ID in the OS env.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Whiska.Hook.PreToolUse
  alias Whiska.Marker
  alias Whiska.Schema.Mouse
  alias Whiska.Storage

  setup do
    root = Path.join(System.tmp_dir!(), "whiska-hook-#{System.unique_integer([:positive])}")
    main = Path.join(root, "myrepo")
    worktree = Path.join(main, "worktrees/feat-thing")
    File.mkdir_p!(Path.join(main, ".git"))
    File.mkdir_p!(Path.join(worktree, "lib"))
    File.write!(Path.join(worktree, ".git"), "gitdir: #{main}/.git/worktrees/feat-thing\n")

    was = System.get_env("HERDR_PANE_ID")
    System.delete_env("HERDR_PANE_ID")

    on_exit(fn ->
      File.rm_rf!(root)
      if was, do: System.put_env("HERDR_PANE_ID", was), else: System.delete_env("HERDR_PANE_ID")
    end)

    {:ok, root: root, main: main, worktree: worktree}
  end

  defp payload(fields), do: JSON.encode!(fields)

  defp run(fields), do: PreToolUse.run(payload(fields))

  # A mouse a spawn shaped as build, the way every real one starts (ADR-0069).
  defp shaped_build(main, worktree) do
    {:ok, mouse_id} = Marker.read_or_mint(worktree)
    {:ok, handle} = Storage.open(main)
    Storage.record_mouse(%{mouse_id: mouse_id, path: worktree, branch: "feat-thing"})
    {:ok, _} = Storage.shape(mouse_id, "build", nil, nil)
    Storage.close(handle)
  end

  describe "denying" do
    test "returns a PreToolUse deny decision for a main-checkout write", %{
      main: main,
      worktree: worktree
    } do
      shaped_build(main, worktree)

      assert {:deny, reason} =
               run(%{
                 "cwd" => worktree,
                 "tool_name" => "Write",
                 "tool_input" => %{"file_path" => Path.join(main, "CONTEXT.md")}
               })

      assert reason =~ "ADR-0013"
    end

    test "encodes the decision in the shape Claude Code expects" do
      json = PreToolUse.encode({:deny, "nope"})

      assert %{
               "hookSpecificOutput" => %{
                 "hookEventName" => "PreToolUse",
                 "permissionDecision" => "deny",
                 "permissionDecisionReason" => "nope"
               }
             } = JSON.decode!(json)
    end

    test "allow produces no output at all, leaving other permission checks alone" do
      assert PreToolUse.encode(:allow) == :none
    end
  end

  # A folder under `worktrees/` that is no checkout of its own is nobody — no
  # mouse, no mode, no marker (ADR-0030's note). Containment does not go with
  # identity: a session there still cannot write into the main checkout
  # (ADR-0013).
  describe "a folder under worktrees that is no worktree" do
    test "cannot write into the main checkout", %{main: main} do
      folder = Path.join(main, "worktrees/quality")
      File.mkdir_p!(Path.join(folder, "QUAL-350"))

      assert {:deny, reason} =
               run(%{
                 "cwd" => folder,
                 "tool_name" => "Write",
                 "tool_input" => %{"file_path" => Path.join(main, "CONTEXT.md")}
               })

      assert reason =~ "ADR-0013"
    end

    test "mints no mouse and no marker file", %{main: main} do
      folder = Path.join(main, "worktrees/quality")
      File.mkdir_p!(folder)

      run(%{
        "cwd" => folder,
        "tool_name" => "Write",
        "tool_input" => %{"file_path" => Path.join(main, "CONTEXT.md")}
      })

      refute File.exists?(Marker.path(folder))

      {:ok, handle} = Storage.open(main)
      on_exit(fn -> Storage.close(handle) end)
      assert Storage.all(Mouse) == []
    end

    test "a mutating bash command into the main checkout is denied too", %{main: main} do
      folder = Path.join(main, "worktrees/quality")
      File.mkdir_p!(folder)

      assert {:deny, _} =
               run(%{
                 "cwd" => folder,
                 "tool_name" => "Bash",
                 "tool_input" => %{"command" => "rm -rf #{main}/lib"}
               })
    end
  end

  describe "allowing" do
    test "a write inside the mouse's own worktree", %{main: main, worktree: worktree} do
      shaped_build(main, worktree)

      assert :allow =
               run(%{
                 "cwd" => worktree,
                 "tool_name" => "Write",
                 "tool_input" => %{"file_path" => Path.join(worktree, "lib/fine.ex")}
               })
    end

    test "any tool call made from the main checkout itself", %{main: main} do
      # The hook is installed repo-wide, so it fires in the main checkout too.
      # Protecting the main session from itself needs a different vantage point
      # and is out of scope for this slice (ADR-0030).
      assert :allow =
               run(%{
                 "cwd" => main,
                 "tool_name" => "Write",
                 "tool_input" => %{"file_path" => Path.join(main, "CONTEXT.md")}
               })
    end

    test "a write below a folder under worktrees that is no worktree", %{main: main} do
      folder = Path.join(main, "worktrees/quality")
      File.mkdir_p!(folder)

      assert :allow =
               run(%{
                 "cwd" => folder,
                 "tool_name" => "Write",
                 "tool_input" => %{"file_path" => Path.join(folder, "notes.md")}
               })
    end

    test "a directory with no worktrees ancestor at all", %{root: root} do
      assert :allow =
               run(%{
                 "cwd" => root,
                 "tool_name" => "Write",
                 "tool_input" => %{"file_path" => Path.join(root, "x.ex")}
               })
    end
  end

  describe "identity is minted on the first invocation (ADR-0002, ADR-0030)" do
    test "writes the marker file the first time the hook runs in a worktree", %{
      worktree: worktree
    } do
      refute File.exists?(Marker.path(worktree))

      run(%{"cwd" => worktree, "tool_name" => "Read", "tool_input" => %{}})

      assert File.exists?(Marker.path(worktree))
    end

    test "records the mouse in the house, keyed by the marker id", %{
      main: main,
      worktree: worktree
    } do
      run(%{"cwd" => worktree, "tool_name" => "Read", "tool_input" => %{}})

      {:ok, mouse_id} = Marker.read_or_mint(worktree)
      {:ok, handle} = Storage.open(main)
      on_exit(fn -> Storage.close(handle) end)

      assert [%Mouse{} = mouse] = Storage.all(Mouse)
      assert mouse.mouse_id == mouse_id
      assert mouse.path == worktree
      assert mouse.branch == "feat-thing"
      assert mouse.mode == "build"
      assert is_nil(mouse.pane)
    end

    test "keeps the same id across invocations", %{worktree: worktree} do
      run(%{"cwd" => worktree, "tool_name" => "Read", "tool_input" => %{}})
      {:ok, first} = Marker.read_or_mint(worktree)

      run(%{"cwd" => worktree, "tool_name" => "Read", "tool_input" => %{}})
      {:ok, second} = Marker.read_or_mint(worktree)

      assert first == second
    end

    test "mints identity even when the call is denied", %{main: main, worktree: worktree} do
      run(%{
        "cwd" => worktree,
        "tool_name" => "Write",
        "tool_input" => %{"file_path" => Path.join(main, "CONTEXT.md")}
      })

      assert File.exists?(Marker.path(worktree))
    end
  end

  describe "robustness" do
    test "allows, loudly, when the payload is not valid JSON" do
      stderr = capture_io(:stderr, fn -> assert :allow = PreToolUse.run("not json{") end)

      assert stderr =~ "whiska"
    end

    test "allows when the payload is valid JSON but not a PreToolUse event" do
      assert :allow = PreToolUse.run(JSON.encode!(%{"something" => "else"}))
    end

    test "still enforces the rule when the house cannot be opened", %{
      main: main,
      worktree: worktree
    } do
      # Storage is bookkeeping; the decision must not depend on it.
      File.rm_rf!(Path.join(main, ".git"))
      File.write!(Path.join(main, ".git"), "gitdir: nowhere")

      stderr =
        capture_io(:stderr, fn ->
          assert {:deny, _} =
                   run(%{
                     "cwd" => worktree,
                     "tool_name" => "Write",
                     "tool_input" => %{"file_path" => Path.join(main, "CONTEXT.md")}
                   })
        end)

      assert stderr =~ "whiska"
    end

    test "mints identity even when the house cannot be opened", %{
      main: main,
      worktree: worktree
    } do
      File.rm_rf!(Path.join(main, ".git"))
      File.write!(Path.join(main, ".git"), "gitdir: nowhere")

      capture_io(:stderr, fn ->
        run(%{"cwd" => worktree, "tool_name" => "Read", "tool_input" => %{}})
      end)

      assert File.exists?(Marker.path(worktree))
    end
  end

  describe "a mouse nobody shaped reads but does not write (ADR-0069)" do
    test "its first edit is denied, and the reason sends it to the person", %{worktree: worktree} do
      assert {:deny, reason} =
               run(%{
                 "cwd" => worktree,
                 "tool_name" => "Write",
                 "tool_input" => %{"file_path" => Path.join(worktree, "lib/x.ex")}
               })

      assert reason =~ "never given a shape"
      assert reason =~ "whiska mode build"
    end

    test "it may still read", %{worktree: worktree} do
      assert :allow =
               run(%{
                 "cwd" => worktree,
                 "tool_name" => "Bash",
                 "tool_input" => %{"command" => "git log"}
               })
    end

    test "it may not shape itself", %{worktree: worktree} do
      assert {:deny, _} =
               run(%{
                 "cwd" => worktree,
                 "tool_name" => "Bash",
                 "tool_input" => %{"command" => "whiska mode build"}
               })
    end

    test "the person choosing build with whiska mode lets it write", %{
      main: main,
      worktree: worktree
    } do
      run(%{"cwd" => worktree, "tool_name" => "Read", "tool_input" => %{}})
      {:ok, mouse_id} = Marker.read_or_mint(worktree)
      {:ok, handle} = Storage.open(main)
      {:ok, _} = Storage.set_mode(mouse_id, "build")
      Storage.close(handle)

      assert :allow =
               run(%{
                 "cwd" => worktree,
                 "tool_name" => "Write",
                 "tool_input" => %{"file_path" => Path.join(worktree, "lib/x.ex")}
               })
    end
  end

  describe "mode drives which rule applies (ADR-0018)" do
    defp set_mode(main, worktree, mode) do
      # The hook itself mints the id on first run; reuse it.
      run(%{"cwd" => worktree, "tool_name" => "Read", "tool_input" => %{}})
      {:ok, mouse_id} = Marker.read_or_mint(worktree)
      {:ok, handle} = Storage.open(main)
      {:ok, _} = Storage.set_mode(mouse_id, mode)
      Storage.close(handle)
      mouse_id
    end

    test "a build mouse may edit inside its own worktree", %{main: main, worktree: worktree} do
      set_mode(main, worktree, "build")

      assert :allow =
               run(%{
                 "cwd" => worktree,
                 "tool_name" => "Write",
                 "tool_input" => %{"file_path" => Path.join(worktree, "lib/x.ex")}
               })
    end

    test "a sniff mouse may not edit even inside its own worktree", %{
      main: main,
      worktree: worktree
    } do
      set_mode(main, worktree, "sniff")

      assert {:deny, reason} =
               run(%{
                 "cwd" => worktree,
                 "tool_name" => "Write",
                 "tool_input" => %{"file_path" => Path.join(worktree, "lib/x.ex")}
               })

      assert reason =~ "sniff"
    end

    test "a sniff mouse may still read and run read-only commands", %{
      main: main,
      worktree: worktree
    } do
      set_mode(main, worktree, "sniff")

      assert :allow =
               run(%{
                 "cwd" => worktree,
                 "tool_name" => "Read",
                 "tool_input" => %{"file_path" => "x"}
               })

      assert :allow =
               run(%{
                 "cwd" => worktree,
                 "tool_name" => "Bash",
                 "tool_input" => %{"command" => "git log"}
               })
    end

    test "a sniff mouse is denied a mutating command", %{main: main, worktree: worktree} do
      set_mode(main, worktree, "sniff")

      assert {:deny, _} =
               run(%{
                 "cwd" => worktree,
                 "tool_name" => "Bash",
                 "tool_input" => %{"command" => "rm -rf lib"}
               })
    end

    test "sniff is checked before worktree containment, so its reason is the one shown",
         %{main: main, worktree: worktree} do
      set_mode(main, worktree, "sniff")

      {:deny, reason} =
        run(%{
          "cwd" => worktree,
          "tool_name" => "Write",
          "tool_input" => %{"file_path" => Path.join(main, "CONTEXT.md")}
        })

      # Both rules would deny this. The sniff one explains the real reason.
      assert reason =~ "sniff"
    end

    test "an unreadable mode degrades to build, loudly, and containment still holds",
         %{main: main, worktree: worktree} do
      File.rm_rf!(Path.join(main, ".git"))
      File.write!(Path.join(main, ".git"), "gitdir: nowhere")

      stderr =
        capture_io(:stderr, fn ->
          # Containment is pure path arithmetic and needs no database.
          assert {:deny, reason} =
                   run(%{
                     "cwd" => worktree,
                     "tool_name" => "Write",
                     "tool_input" => %{"file_path" => Path.join(main, "CONTEXT.md")}
                   })

          refute reason =~ "sniff"

          # ...and an edit inside the worktree is allowed rather than blocked.
          assert :allow =
                   run(%{
                     "cwd" => worktree,
                     "tool_name" => "Write",
                     "tool_input" => %{"file_path" => Path.join(worktree, "lib/x.ex")}
                   })
        end)

      assert stderr =~ "whiska"
    end
  end

  describe "a session is what it started as, not where its shell wandered (ADR-0053)" do
    defp started_in(dir) do
      path = Path.join(dir, "start-#{System.unique_integer([:positive])}.jsonl")
      File.write!(path, JSON.encode!(%{"type" => "user", "cwd" => dir}))
      path
    end

    test "the main session may still edit its own checkout after a cd", %{
      main: main,
      worktree: worktree
    } do
      assert :allow =
               run(%{
                 "cwd" => worktree,
                 "transcript_path" => started_in(main),
                 "tool_name" => "Write",
                 "tool_input" => %{"file_path" => Path.join(main, "CONTEXT.md")}
               })
    end

    test "a mouse that cd'd into the main checkout cannot write there by a bare name", %{
      main: main,
      worktree: worktree
    } do
      set_mode(main, worktree, "build")

      assert {:deny, reason} =
               run(%{
                 "cwd" => main,
                 "transcript_path" => started_in(worktree),
                 "tool_name" => "Bash",
                 "tool_input" => %{"command" => "rm CONTEXT.md"}
               })

      assert reason =~ "ADR-0013"
    end

    test "a relative cwd is no position at all", %{main: main, worktree: worktree} do
      set_mode(main, worktree, "build")

      File.cd!(main, fn ->
        assert :allow =
                 run(%{
                   "cwd" => ".",
                   "transcript_path" => started_in(worktree),
                   "tool_name" => "Bash",
                   "tool_input" => %{"command" => "touch x"}
                 })
      end)
    end

    test "and is recorded as no mouse at all", %{main: main, worktree: worktree} do
      run(%{
        "cwd" => worktree,
        "transcript_path" => started_in(main),
        "tool_name" => "Read",
        "tool_input" => %{}
      })

      refute File.exists?(Marker.path(worktree))
    end

    test "a mouse that cd'd out is still held to its own worktree", %{
      main: main,
      worktree: worktree
    } do
      assert {:deny, _} =
               run(%{
                 "cwd" => main,
                 "transcript_path" => started_in(worktree),
                 "tool_name" => "Write",
                 "tool_input" => %{"file_path" => Path.join(main, "CONTEXT.md")}
               })
    end

    test "the pane the house calls its main session is never a mouse, whatever it started in",
         %{main: main, worktree: worktree} do
      {:ok, handle} = Storage.open(main)
      :ok = Storage.set_main_pane("w1:p2")
      Storage.close(handle)

      System.put_env("HERDR_PANE_ID", "w1:p2")

      assert :allow =
               run(%{
                 "cwd" => worktree,
                 "transcript_path" => started_in(worktree),
                 "tool_name" => "Write",
                 "tool_input" => %{"file_path" => Path.join(main, "CONTEXT.md")}
               })

      refute File.exists?(Marker.path(worktree))
    end
  end
end
