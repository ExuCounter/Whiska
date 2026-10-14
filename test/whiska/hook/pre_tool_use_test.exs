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

  # A mouse a spawn shaped, the way every real one starts (ADR-0069).
  defp shaped(main, worktree, mode) do
    {:ok, mouse_id} = Marker.read_or_mint(worktree)
    {:ok, handle} = Storage.open(main)
    Storage.record_mouse(%{mouse_id: mouse_id, path: worktree, branch: "feat-thing"})
    {:ok, _} = Storage.shape(mouse_id, mode, nil, nil)
    Storage.close(handle)
  end

  defp held(main, worktree) do
    shaped(main, worktree, "build")
    {:ok, mouse_id} = Marker.read_or_mint(worktree)
    {:ok, handle} = Storage.open(main)
    {:ok, _} = Storage.hold(mouse_id)
    Storage.close(handle)
    mouse_id
  end

  defp write(cwd, path),
    do: run(%{"cwd" => cwd, "tool_name" => "Write", "tool_input" => %{"file_path" => path}})

  defp bash(cwd, command),
    do: run(%{"cwd" => cwd, "tool_name" => "Bash", "tool_input" => %{"command" => command}})

  describe "the decision's output" do
    test "encodes a deny in the shape Claude Code expects" do
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

  # The mode's limits and the person's commands are the deny list a mouse starts
  # with (ADR-next-a-mouse-starts-in-bypass-mode); the hook holds only the hold.
  describe "a mouse that is not held is left to its deny list" do
    test "a build mouse may write anywhere, the main checkout included", %{
      main: main,
      worktree: worktree
    } do
      shaped(main, worktree, "build")

      assert :allow = write(worktree, Path.join(worktree, "lib/fine.ex"))
      assert :allow = write(worktree, Path.join(main, "CONTEXT.md"))
      assert :allow = bash(worktree, "sed -i '' s/a/b/ #{main}/CONTEXT.md")
    end

    test "a sniff mouse's edits and shell commands pass the hook", %{
      main: main,
      worktree: worktree
    } do
      shaped(main, worktree, "sniff")

      assert :allow = write(worktree, Path.join(worktree, "lib/x.ex"))
      assert :allow = bash(worktree, "rm -rf lib")
      assert :allow = bash(worktree, "ls nope 2>/dev/null | xargs wc -l")
    end

    test "the person's commands pass the hook", %{main: main, worktree: worktree} do
      shaped(main, worktree, "build")

      assert :allow = bash(worktree, "whiska hold feat-other")
      assert :allow = bash(worktree, "away")
    end

    test "a mouse nobody shaped is not limited either", %{worktree: worktree} do
      assert :allow = write(worktree, Path.join(worktree, "lib/x.ex"))
      assert :allow = bash(worktree, "git commit -am wip")
    end
  end

  describe "allowing" do
    test "any tool call made from the main checkout itself", %{main: main} do
      assert :allow = write(main, Path.join(main, "CONTEXT.md"))
    end

    test "a directory with no worktrees ancestor at all", %{root: root} do
      assert :allow = write(root, Path.join(root, "x.ex"))
    end
  end

  # A folder under `worktrees/` that is no checkout of its own is nobody — no
  # mouse, no mode, no marker (ADR-0030).
  describe "a folder under worktrees that is no worktree" do
    test "may write, and mints no mouse and no marker file", %{main: main} do
      folder = Path.join(main, "worktrees/quality")
      File.mkdir_p!(folder)

      assert :allow = write(folder, Path.join(main, "CONTEXT.md"))

      refute File.exists?(Marker.path(folder))

      {:ok, handle} = Storage.open(main)
      on_exit(fn -> Storage.close(handle) end)
      assert Storage.all(Mouse) == []
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
  end

  describe "robustness" do
    test "allows, loudly, when the payload is not valid JSON" do
      stderr = capture_io(:stderr, fn -> assert :allow = PreToolUse.run("not json{") end)

      assert stderr =~ "whiska"
    end

    test "allows when the payload is valid JSON but not a PreToolUse event" do
      assert :allow = PreToolUse.run(JSON.encode!(%{"something" => "else"}))
    end

    test "a house that will not open allows, loudly: the mouse is taken as not held", %{
      main: main,
      worktree: worktree
    } do
      File.rm_rf!(Path.join(main, ".git"))
      File.write!(Path.join(main, ".git"), "gitdir: nowhere")

      stderr =
        capture_io(:stderr, fn ->
          assert :allow = write(worktree, Path.join(worktree, "lib/x.ex"))
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

  describe "a mouse on hold (ADR-0079)" do
    test "the rule refuses whatever the hook asks it about, a read included, and says to end the turn",
         %{
           main: main,
           worktree: worktree
         } do
      held(main, worktree)

      assert {:deny, reason} =
               run(%{"cwd" => worktree, "tool_name" => "Read", "tool_input" => %{}})

      assert reason =~ "on hold"
      assert reason =~ "end the turn"
      assert reason =~ "resume feat-thing"
    end

    test "lifting the hold lets it work again", %{main: main, worktree: worktree} do
      mouse_id = held(main, worktree)
      {:ok, handle} = Storage.open(main)
      {:ok, _} = Storage.lift_hold(mouse_id)
      Storage.close(handle)

      assert :allow = run(%{"cwd" => worktree, "tool_name" => "Read", "tool_input" => %{}})
    end

    test "a mouse that is not held is unchanged", %{main: main, worktree: worktree} do
      shaped(main, worktree, "build")
      assert :allow = run(%{"cwd" => worktree, "tool_name" => "Read", "tool_input" => %{}})
    end
  end

  describe "a session is what it started as, not where its shell wandered (ADR-0053)" do
    defp started_in(dir) do
      path = Path.join(dir, "start-#{System.unique_integer([:positive])}.jsonl")
      File.write!(path, JSON.encode!(%{"type" => "user", "cwd" => dir}))
      path
    end

    test "the main session that cd'd into a worktree is recorded as no mouse at all", %{
      main: main,
      worktree: worktree
    } do
      run(%{
        "cwd" => worktree,
        "transcript_path" => started_in(main),
        "tool_name" => "Read",
        "tool_input" => %{}
      })

      refute File.exists?(Marker.path(worktree))
    end

    test "a held mouse that cd'd out is still the held mouse", %{
      main: main,
      worktree: worktree
    } do
      held(main, worktree)

      assert {:deny, reason} =
               run(%{
                 "cwd" => main,
                 "transcript_path" => started_in(worktree),
                 "tool_name" => "Bash",
                 "tool_input" => %{"command" => "git status"}
               })

      assert reason =~ "on hold"
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
