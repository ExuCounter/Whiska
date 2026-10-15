defmodule Whiska.Hook.StopTest do
  @moduledoc """
  The doorstep writer (ADR-0036): reads one Stop payload, leaves one entry in
  the house, exits. No socket, no database, no decision.
  """
  # Identity is read partly from HERDR_PANE_ID, which is process-wide.
  # Serial: the code under test opens the house under the one VM-wide name
  # `Whiska.Repo`, and the tests set HERDR_PANE_ID in the OS env.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Whiska.Doorstep
  alias Whiska.Doorstep.Entry
  alias Whiska.Hook.Stop
  alias Whiska.Marker
  alias Whiska.Storage

  setup do
    root = Path.join(System.tmp_dir!(), "whiska-stop-#{Whiska.Test.Unique.id()}")
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

    {:ok, main: main, worktree: worktree}
  end

  defp payload(fields), do: JSON.encode!(fields)

  test "leaves the whole final message on the house's doorstep, stamped", %{
    main: main,
    worktree: worktree
  } do
    text = "Two options.\n\n[worktree-status: needs-decision] pick one"

    assert :ok = Stop.run(payload(%{"cwd" => worktree, "last_assistant_message" => text}))

    {:ok, mouse_id} = Marker.read_or_mint(worktree)

    assert [{_, %Entry{} = entry}] = Doorstep.waiting(main)
    assert entry.mouse_id == mouse_id
    assert entry.branch == "feat-thing"
    assert entry.worktree_root == worktree
    assert entry.text == text
    assert DateTime.diff(DateTime.utc_now(), entry.stamped_at, :second) < 5
  end

  test "carries the worktree's spec, so it outlives the worktree", %{
    main: main,
    worktree: worktree
  } do
    File.write!(Path.join(worktree, ".whiska-spec.md"), "# Spec\n\nBuild it.\n")

    :ok = Stop.run(payload(%{"cwd" => worktree, "last_assistant_message" => "ok to build?"}))

    assert [{_, %Entry{spec: "# Spec\n\nBuild it.\n"}}] = Doorstep.waiting(main)
  end

  test "carries the worktree's research document beside its spec", %{
    main: main,
    worktree: worktree
  } do
    File.write!(Path.join(worktree, ".whiska-research.md"), "# Why it hangs\n\nFound.\n")

    :ok = Stop.run(payload(%{"cwd" => worktree, "last_assistant_message" => "done"}))

    assert [{_, %Entry{spec: nil, research: "# Why it hangs\n\nFound.\n"}}] =
             Doorstep.waiting(main)
  end

  test "carries the worktree's build plan beside its spec", %{main: main, worktree: worktree} do
    File.write!(Path.join(worktree, ".whiska-spec.md"), "# Spec\n")
    File.write!(Path.join(worktree, ".whiska-plan.md"), "# Build plan\n\nOne module.\n")

    :ok = Stop.run(payload(%{"cwd" => worktree, "last_assistant_message" => "ok to build?"}))

    assert [{_, %Entry{spec: "# Spec\n", plan: "# Build plan\n\nOne module.\n"}}] =
             Doorstep.waiting(main)
  end

  test "a research document that is a pipe is left out rather than read forever", %{
    main: main,
    worktree: worktree
  } do
    {_, 0} = System.cmd("mkfifo", [Path.join(worktree, ".whiska-research.md")])

    :ok = Stop.run(payload(%{"cwd" => worktree, "last_assistant_message" => "done"}))

    assert [{_, %Entry{research: nil, text: "done"}}] = Doorstep.waiting(main)
  end

  test "a spec JSON cannot carry is left out, and the message still arrives", %{
    main: main,
    worktree: worktree
  } do
    File.write!(Path.join(worktree, ".whiska-spec.md"), <<0xFF, 0xFE>>)

    :ok = Stop.run(payload(%{"cwd" => worktree, "last_assistant_message" => "ok to build?"}))

    assert [{_, %Entry{spec: nil, text: "ok to build?"}}] = Doorstep.waiting(main)
  end

  test "a spec that is a pipe is left out rather than read forever", %{
    main: main,
    worktree: worktree
  } do
    {_, 0} = System.cmd("mkfifo", [Path.join(worktree, ".whiska-spec.md")])

    :ok = Stop.run(payload(%{"cwd" => worktree, "last_assistant_message" => "ok to build?"}))

    assert [{_, %Entry{spec: nil, text: "ok to build?"}}] = Doorstep.waiting(main)
  end

  test "a session sitting in a subfolder still lands in the right house", %{
    main: main,
    worktree: worktree
  } do
    :ok =
      Stop.run(payload(%{"cwd" => Path.join(worktree, "lib"), "last_assistant_message" => "hi"}))

    assert [{_, %Entry{worktree_root: ^worktree}}] = Doorstep.waiting(main)
  end

  test "writes unconditionally — no marker is still an entry (ADR-0009)", %{
    main: main,
    worktree: worktree
  } do
    :ok =
      Stop.run(payload(%{"cwd" => worktree, "last_assistant_message" => "stopped, no marker"}))

    assert [{_, %Entry{text: "stopped, no marker"}}] = Doorstep.waiting(main)
  end

  test "mints the mouse's marker file if this is the first it has been seen", %{
    worktree: worktree
  } do
    refute File.exists?(Marker.path(worktree))
    :ok = Stop.run(payload(%{"cwd" => worktree, "last_assistant_message" => "x"}))
    assert File.exists?(Marker.path(worktree))
  end

  test "is a no-op outside a worktree — the main session stops all the time", %{main: main} do
    assert :ok = Stop.run(payload(%{"cwd" => main, "last_assistant_message" => "x"}))
    assert Doorstep.waiting(main) == []
    refute File.exists?(Doorstep.path(main))
  end

  test "an empty message is still a stop worth recording", %{main: main, worktree: worktree} do
    :ok = Stop.run(payload(%{"cwd" => worktree}))
    assert [{_, %Entry{text: ""}}] = Doorstep.waiting(main)
  end

  test "a malformed payload is a loud no-op, never a crash", %{main: main} do
    assert :ok = Stop.run("{not json")
    assert Doorstep.waiting(main) == []
  end

  describe "a claude started inside the mouse (ADR-0084)" do
    alias Whiska.Test.ClaudeTree

    test "leaves nothing on the doorstep: it is not the mouse", %{main: main, worktree: worktree} do
      pid = ClaudeTree.nested(Path.join(main, "procs"))

      assert :ok =
               Stop.run(
                 payload(%{"cwd" => worktree, "last_assistant_message" => "test output"}),
                 %{"CLAUDE_PID" => pid}
               )

      assert Doorstep.waiting(main) == []
    end

    test "the mouse's own claude still leaves its message", %{main: main, worktree: worktree} do
      pid = ClaudeTree.lone(Path.join(main, "procs"))

      :ok =
        Stop.run(
          payload(%{"cwd" => worktree, "last_assistant_message" => "done"}),
          %{"CLAUDE_PID" => pid}
        )

      assert [{_, %Entry{text: "done"}}] = Doorstep.waiting(main)
    end

    test "a claude above the mouse's herdr does not silence the mouse", %{
      main: main,
      worktree: worktree
    } do
      pid = ClaudeTree.under_herdr(Path.join(main, "procs"))

      :ok =
        Stop.run(
          payload(%{"cwd" => worktree, "last_assistant_message" => "done"}),
          %{"CLAUDE_PID" => pid}
        )

      assert [{_, %Entry{text: "done"}}] = Doorstep.waiting(main)
    end

    test "a pid that names no process is the mouse, and is delivered", %{
      main: main,
      worktree: worktree
    } do
      :ok =
        Stop.run(
          payload(%{"cwd" => worktree, "last_assistant_message" => "done"}),
          %{"CLAUDE_PID" => ClaudeTree.gone()}
        )

      assert [{_, %Entry{text: "done"}}] = Doorstep.waiting(main)
    end
  end

  describe "an unmarked stop with background work still out (ADR-0052)" do
    defp transcript(worktree, lines) do
      path = Path.join(worktree, "transcript.jsonl")
      File.write!(path, lines |> List.flatten() |> Enum.join("\n"))
      path
    end

    defp launched(agent_id) do
      [
        JSON.encode!(%{
          "type" => "assistant",
          "message" => %{
            "content" => [%{"type" => "tool_use", "id" => "toolu_1", "name" => "Agent"}]
          }
        }),
        JSON.encode!(%{
          "type" => "user",
          "toolUseResult" => %{"status" => "async_launched", "agentId" => agent_id},
          "message" => %{
            "content" => [
              %{
                "tool_use_id" => "toolu_1",
                "type" => "tool_result",
                "content" => [
                  %{
                    "type" => "text",
                    "text" => "Async agent launched successfully.\nagentId: #{agent_id}\n"
                  }
                ]
              }
            ]
          }
        })
      ]
    end

    defp background_command(task_id) do
      [
        JSON.encode!(%{
          "type" => "assistant",
          "message" => %{
            "content" => [%{"type" => "tool_use", "id" => "toolu_b", "name" => "Bash"}]
          }
        }),
        JSON.encode!(%{
          "type" => "user",
          "toolUseResult" => %{"stdout" => "", "backgroundTaskId" => task_id},
          "message" => %{
            "content" => [
              %{"type" => "tool_result", "tool_use_id" => "toolu_b", "content" => "x"}
            ]
          }
        })
      ]
    end

    defp handed_back(agent_id) do
      JSON.encode!(%{
        "type" => "user",
        "origin" => %{"kind" => "peer", "from" => agent_id, "handback" => true},
        "message" => %{"content" => "[Subagent hand-back] nothing to change"}
      })
    end

    defp held_stop(worktree, path, message) do
      :ok =
        Stop.run(
          payload(%{
            "cwd" => worktree,
            "transcript_path" => path,
            "last_assistant_message" => message
          })
        )
    end

    test "leaves nothing on the doorstep — the session will be woken again", %{
      main: main,
      worktree: worktree
    } do
      path = transcript(worktree, [launched("ae96c5149391564f6")])

      assert :ok =
               Stop.run(
                 payload(%{
                   "cwd" => worktree,
                   "transcript_path" => path,
                   "last_assistant_message" => "Still waiting on the three reviewers."
                 })
               )

      assert Doorstep.waiting(main) == []
    end

    test "a launch more than half a megabyte back still holds the turn", %{
      main: main,
      worktree: worktree
    } do
      read_since =
        for n <- 1..3 do
          JSON.encode!(%{
            "type" => "user",
            "message" => %{"content" => "file #{n}: " <> String.duplicate("x", 300 * 1024)}
          })
        end

      path = transcript(worktree, [launched("add045f13ddf15a65"), read_since])

      :ok =
        Stop.run(
          payload(%{
            "cwd" => worktree,
            "transcript_path" => path,
            "last_assistant_message" => "Both reviewers are still running."
          })
        )

      assert Doorstep.waiting(main) == []
    end

    test "a question or a report is held while a subagent is out, as #626 and #627 were",
         %{main: main, worktree: worktree} do
      path =
        transcript(worktree, [launched("ae96c5149391564f6"), launched("a8b36f1846b568361")])

      for message <- [
            "The reviewer is still running.\n\n\u2063\u2063",
            "Done, green. Two reviewers are still running.\n\n\u2063\u2063\u2063"
          ] do
        :ok =
          Stop.run(
            payload(%{
              "cwd" => worktree,
              "transcript_path" => path,
              "last_assistant_message" => message
            })
          )
      end

      assert Doorstep.waiting(main) == []
      assert [{_, %Entry{text: text, transcript: ^path}}] = Doorstep.held(main)
      assert text =~ "Two reviewers are still running"
    end

    test "a later marked stop supersedes the mouse's held one", %{
      main: main,
      worktree: worktree
    } do
      path = transcript(worktree, [launched("ae96c5149391564f6")])
      held_stop(worktree, path, "Pick A or B?\n\u2063\u2063")
      assert [_held] = Doorstep.held(main)

      done =
        transcript(worktree, [launched("ae96c5149391564f6"), handed_back("ae96c5149391564f6")])

      held_stop(worktree, done, "Shipped.\n\u2063\u2063\u2063")

      assert Doorstep.held(main) == []
      assert [{_, %Entry{text: "Shipped." <> _}}] = Doorstep.waiting(main)
    end

    test "a later unmarked stop is the mouse not asking again: the held one is delivered instead",
         %{main: main, worktree: worktree} do
      path = transcript(worktree, [launched("ae96c5149391564f6")])
      held_stop(worktree, path, "Pick A or B?\n\u2063\u2063")

      done =
        transcript(worktree, [launched("ae96c5149391564f6"), handed_back("ae96c5149391564f6")])

      held_stop(worktree, done, "Applied the reviewer's fixes.")

      assert Doorstep.held(main) == []
      assert [{_, %Entry{text: "Pick A or B?" <> _}}] = Doorstep.waiting(main)
    end

    test "the held stop delivered in an unmarked stop's place carries that turn's own facts", %{
      main: main,
      worktree: worktree
    } do
      path = transcript(worktree, [launched("ae96c5149391564f6")])
      held_stop(worktree, path, "Pick A or B?\n\u2063\u2063")

      File.write!(Path.join(worktree, Whiska.BuildPlan.filename()), "# Plan\n\nrevised\n")

      done =
        transcript(worktree, [launched("ae96c5149391564f6"), handed_back("ae96c5149391564f6")])

      held_stop(worktree, done, "Applied the reviewer's fixes.")

      assert [{_, %Entry{text: "Pick A or B?" <> _, plan: "# Plan\n\nrevised\n"}}] =
               Doorstep.waiting(main)
    end

    test "an unmarked stop of another mouse leaves a held one alone", %{
      main: main,
      worktree: worktree
    } do
      {:ok, _} =
        Doorstep.hold(main, %Entry{
          mouse_id: "someone-else",
          branch: "feat-other",
          worktree_root: "/elsewhere",
          stamped_at: DateTime.utc_now(),
          text: "Pick A or B?\n\u2063\u2063"
        })

      done =
        transcript(worktree, [launched("ae96c5149391564f6"), handed_back("ae96c5149391564f6")])

      held_stop(worktree, done, "Applied the reviewer's fixes.")

      assert [{_, %Entry{mouse_id: "someone-else"}}] = Doorstep.held(main)
      assert [{_, %Entry{text: "Applied" <> _}}] = Doorstep.waiting(main)
    end

    test "an unmarked stop with nothing held is written as ever", %{
      main: main,
      worktree: worktree
    } do
      done =
        transcript(worktree, [launched("ae96c5149391564f6"), handed_back("ae96c5149391564f6")])

      held_stop(worktree, done, "Applied the reviewer's fixes.")

      assert [{_, %Entry{text: "Applied" <> _}}] = Doorstep.waiting(main)
    end

    test "an unmarked stop passed over leaves the held one where it is", %{
      main: main,
      worktree: worktree
    } do
      path = transcript(worktree, [launched("ae96c5149391564f6")])

      for message <- ["Pick A or B?\n\u2063\u2063", "Still waiting on the reviewer."] do
        :ok =
          Stop.run(
            payload(%{
              "cwd" => worktree,
              "transcript_path" => path,
              "last_assistant_message" => message
            })
          )
      end

      assert [{_, %Entry{text: "Pick A or B?" <> _}}] = Doorstep.held(main)
      assert Doorstep.waiting(main) == []
    end

    test "a question or a report is left beside work that is no subagent", %{
      main: main,
      worktree: worktree
    } do
      path = transcript(worktree, [background_command("bfz2zzaps")])

      for message <- ["Pick A or B?\n\u2063\u2063", "Shipped.\n\u2063\u2063\u2063"] do
        :ok =
          Stop.run(
            payload(%{
              "cwd" => worktree,
              "transcript_path" => path,
              "last_assistant_message" => message
            })
          )
      end

      assert [_question, _report] = Doorstep.waiting(main)
    end

    test "a report is left when the only subagent out is half an hour old", %{
      main: main,
      worktree: worktree
    } do
      old = DateTime.utc_now() |> DateTime.add(-31 * 60) |> DateTime.to_iso8601()

      lines =
        for line <- launched("ae96c5149391564f6"),
            do: line |> JSON.decode!() |> Map.put("timestamp", old) |> JSON.encode!()

      path = transcript(worktree, [lines])

      :ok =
        Stop.run(
          payload(%{
            "cwd" => worktree,
            "transcript_path" => path,
            "last_assistant_message" => "Done, green.\n\u2063\u2063\u2063"
          })
        )

      assert [_report] = Doorstep.waiting(main)
    end

    test "a report is left once the reviewers it waited on have reported", %{
      main: main,
      worktree: worktree
    } do
      path =
        transcript(worktree, [launched("ae96c5149391564f6"), handed_back("ae96c5149391564f6")])

      :ok =
        Stop.run(
          payload(%{
            "cwd" => worktree,
            "transcript_path" => path,
            "last_assistant_message" => "Done, green.\n\u2063\u2063\u2063"
          })
        )

      assert [_report] = Doorstep.waiting(main)
    end

    test "a turn whose reviewers have all reported is left alone", %{
      main: main,
      worktree: worktree
    } do
      path =
        transcript(worktree, [launched("ae96c5149391564f6"), handed_back("ae96c5149391564f6")])

      :ok =
        Stop.run(
          payload(%{
            "cwd" => worktree,
            "transcript_path" => path,
            "last_assistant_message" => "All three are back."
          })
        )

      assert [{_, %Entry{text: "All three are back."}}] = Doorstep.waiting(main)
    end

    test "the entry carries the model the turn actually ran on", %{
      main: main,
      worktree: worktree
    } do
      answered =
        JSON.encode!(%{
          "type" => "assistant",
          "message" => %{"model" => "claude-a-5", "content" => [%{"type" => "text"}]}
        })

      path = transcript(worktree, [answered])

      :ok =
        Stop.run(
          payload(%{
            "cwd" => worktree,
            "transcript_path" => path,
            "last_assistant_message" => "Done."
          })
        )

      assert [{_, %Entry{ran_on: "claude-a-5", transcript: ^path}}] = Doorstep.waiting(main)
    end

    test "a transcript that is missing or unreadable still leaves the entry", %{
      main: main,
      worktree: worktree
    } do
      :ok =
        Stop.run(
          payload(%{
            "cwd" => worktree,
            "transcript_path" => Path.join(worktree, "gone.jsonl"),
            "last_assistant_message" => "x"
          })
        )

      assert [{_, %Entry{text: "x"}}] = Doorstep.waiting(main)
    end
  end

  describe "a session is what it started as, not where its shell wandered (ADR-0053)" do
    defp started_in(dir) do
      path = Path.join(dir, "start-#{System.unique_integer([:positive])}.jsonl")
      File.write!(path, JSON.encode!(%{"type" => "user", "cwd" => dir}))
      path
    end

    test "a main session that cd'd into a worktree leaves nothing behind", %{
      main: main,
      worktree: worktree
    } do
      assert :ok =
               Stop.run(
                 payload(%{
                   "cwd" => worktree,
                   "transcript_path" => started_in(main),
                   "last_assistant_message" => "Here is the answer you asked for."
                 })
               )

      assert Doorstep.waiting(main) == []
    end

    test "a mouse that cd'd out of its worktree still speaks for it", %{
      main: main,
      worktree: worktree
    } do
      :ok =
        Stop.run(
          payload(%{
            "cwd" => main,
            "transcript_path" => started_in(worktree),
            "last_assistant_message" => "done"
          })
        )

      assert [{_, %Entry{worktree_root: ^worktree, branch: "feat-thing"}}] =
               Doorstep.waiting(main)
    end

    test "the pane the house calls its main session is never a mouse", %{
      main: main,
      worktree: worktree
    } do
      {:ok, handle} = Storage.open(main)
      :ok = Storage.set_main_pane("w1:p2")
      Storage.close(handle)

      System.put_env("HERDR_PANE_ID", "w1:p2")
      on_exit(fn -> System.delete_env("HERDR_PANE_ID") end)

      assert :ok =
               Stop.run(
                 payload(%{
                   "cwd" => worktree,
                   "transcript_path" => started_in(worktree),
                   "last_assistant_message" => "an answer"
                 })
               )

      assert Doorstep.waiting(main) == []
    end

    test "a house that will not open still gets the message", %{
      main: main,
      worktree: worktree
    } do
      File.mkdir_p!(Path.join(main, ".git/whiska"))
      File.write!(Path.join(main, ".git/whiska/whiska.db"), "not a database")

      System.put_env("HERDR_PANE_ID", "w1:p2")

      capture_io(:stderr, fn ->
        assert :ok = Stop.run(payload(%{"cwd" => worktree, "last_assistant_message" => "x"}))
      end)

      assert [{_, %Entry{text: "x"}}] = Doorstep.waiting(main)
    end

    test "any other pane in that worktree is the mouse it looks like", %{
      main: main,
      worktree: worktree
    } do
      {:ok, handle} = Storage.open(main)
      :ok = Storage.set_main_pane("w1:p2")
      Storage.close(handle)

      System.put_env("HERDR_PANE_ID", "w1:p9")
      on_exit(fn -> System.delete_env("HERDR_PANE_ID") end)

      :ok = Stop.run(payload(%{"cwd" => worktree, "last_assistant_message" => "a question"}))

      assert [{_, %Entry{text: "a question"}}] = Doorstep.waiting(main)
    end
  end
end
