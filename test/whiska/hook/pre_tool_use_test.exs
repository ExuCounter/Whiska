defmodule Whiska.Hook.PreToolUseTest do
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
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root, main: main, worktree: worktree}
  end

  defp payload(fields), do: JSON.encode!(fields)

  defp run(fields), do: PreToolUse.run(payload(fields))

  describe "denying" do
    test "returns a PreToolUse deny decision for a main-checkout write", %{
      main: main,
      worktree: worktree
    } do
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

  describe "allowing" do
    test "a write inside the mouse's own worktree", %{worktree: worktree} do
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
  end
end
