defmodule Whiska.Watch.TranscriptTest do
  @moduledoc """
  What a mouse is doing, read from its own Claude Code transcript (ADR-0050).

  The parsing is pure — lines in, one phrase out — so every case here is a
  handful of JSONL rather than a session.
  """
  use ExUnit.Case, async: true

  alias Whiska.Watch.Transcript

  defp tool(name, input) do
    JSON.encode!(%{
      "type" => "assistant",
      "message" => %{"content" => [%{"type" => "tool_use", "name" => name, "input" => input}]}
    })
  end

  defp said(text) do
    JSON.encode!(%{
      "type" => "assistant",
      "message" => %{"content" => [%{"type" => "text", "text" => text}]}
    })
  end

  defp user(text) do
    JSON.encode!(%{"type" => "user", "message" => %{"content" => text}})
  end

  defp agent_call(id) do
    JSON.encode!(%{
      "type" => "assistant",
      "message" => %{
        "content" => [%{"type" => "tool_use", "id" => id, "name" => "Agent", "input" => %{}}]
      }
    })
  end

  defp tool_result(id, content \\ "done") do
    JSON.encode!(%{
      "type" => "user",
      "message" => %{
        "content" => [%{"type" => "tool_result", "tool_use_id" => id, "content" => content}]
      }
    })
  end

  defp call(id, name, input) do
    JSON.encode!(%{
      "type" => "assistant",
      "message" => %{
        "content" => [%{"type" => "tool_use", "id" => id, "name" => name, "input" => input}]
      }
    })
  end

  # The receipt Claude Code writes for a background `Agent` call, copied from a
  # real transcript (`Whiska.TranscriptTest` holds the rest of its shape).
  defp launched(tool_use_id, agent_id) do
    tool_use_id
    |> tool_result([
      %{"type" => "text", "text" => "Async agent launched successfully.\nagentId: #{agent_id}"}
    ])
    |> JSON.decode!()
    |> Map.put("toolUseResult", %{"status" => "async_launched", "agentId" => agent_id})
    |> JSON.encode!()
  end

  defp passed_over do
    started =
      JSON.encode!(%{
        "type" => "user",
        "timestamp" => DateTime.to_iso8601(DateTime.utc_now()),
        "toolUseResult" => %{"stdout" => "", "backgroundTaskId" => "bfz2zzaps"},
        "message" => %{
          "content" => [%{"type" => "tool_result", "tool_use_id" => "toolu_b", "content" => "x"}]
        }
      })

    [call("toolu_b", "Bash", %{"command" => "mix test"}), started, said("Suite running.")]
  end

  defp transcript(tmp, worktree, lines, silent_for) do
    dir = Transcript.project_dir(worktree, tmp)
    File.mkdir_p!(dir)
    file = Path.join(dir, "s.jsonl")
    File.write!(file, Enum.join(lines, "\n"))
    File.touch!(file, System.os_time(:second) - silent_for)
  end

  describe "waiting_on_in/1" do
    test "an Agent call with no result yet is a subagent still working" do
      assert %{subagent?: true} =
               Transcript.waiting_on_in(Enum.join([said("on it"), agent_call("toolu_a")], "\n"))
    end

    test "once its result is written the subagent is back" do
      assert %{subagent?: false} =
               Transcript.waiting_on_in(
                 Enum.join([agent_call("toolu_a"), tool_result("toolu_a")], "\n")
               )
    end

    test "another tool in flight is not a subagent, but is a tool" do
      assert Transcript.waiting_on_in(call("toolu_b", "Bash", %{"command" => "mix test"})) ==
               %{subagent?: false, in_tool?: true}
    end

    test "a shell command run in the background explains no silence, a restarted subagent does" do
      answered = fn tool_use_id, result ->
        JSON.encode!(%{
          "type" => "user",
          "toolUseResult" => result,
          "message" => %{
            "content" => [
              %{"type" => "tool_result", "tool_use_id" => tool_use_id, "content" => "x"}
            ]
          }
        })
      end

      backgrounded = [
        call("toolu_b", "Bash", %{"command" => "mix test"}),
        answered.("toolu_b", %{"stdout" => "", "backgroundTaskId" => "bfz2zzaps"})
      ]

      resumed = [
        call("toolu_r", "SendMessage", %{"to" => "af4b8edd5d3bdba93"}),
        answered.("toolu_r", %{"success" => true, "resumedAgentId" => "af4b8edd5d3bdba93"})
      ]

      assert Transcript.waiting_on_in(Enum.join(backgrounded, "\n")) ==
               %{subagent?: false, in_tool?: false}

      assert Transcript.waiting_on_in(Enum.join(resumed, "\n")) ==
               %{subagent?: true, in_tool?: false}
    end

    test "once every call has its result the mouse is waiting on the model" do
      lines = [
        call("toolu_b", "Bash", %{"command" => "mix test"}),
        tool_result("toolu_b"),
        user("go on")
      ]

      assert Transcript.waiting_on_in(Enum.join(lines, "\n")) ==
               %{subagent?: false, in_tool?: false}
    end

    test "a subagent's own calls are not the mouse's" do
      line =
        JSON.encode!(%{
          "type" => "assistant",
          "isSidechain" => true,
          "message" => %{
            "content" => [%{"type" => "tool_use", "id" => "toolu_s", "name" => "Agent"}]
          }
        })

      assert Transcript.waiting_on_in(line) == %{subagent?: false, in_tool?: false}
    end

    test "text that is not a transcript is waiting on nothing it can name" do
      assert Transcript.waiting_on_in("not json") == %{subagent?: false, in_tool?: false}
    end
  end

  describe "last_action/2" do
    test "an edit is the tool and the file, relative to the worktree" do
      lines = [said("on it"), tool("Edit", %{"file_path" => "/repo/worktrees/a/lib/auth.ex"})]

      assert Transcript.last_action(Enum.join(lines, "\n"), "/repo/worktrees/a") ==
               {:tool, "Edit lib/auth.ex"}
    end

    test "a shell call is the command, not the file" do
      line = tool("Bash", %{"command" => "mix test", "description" => "Run the tests"})

      assert Transcript.last_action(line, "/repo/worktrees/a") == {:tool, "Bash mix test"}
    end

    test "a long shell command is cut, so one row cannot eat the board" do
      long = String.duplicate("x", 200)
      line = tool("Bash", %{"command" => "mix test #{long}"})

      assert {:tool, phrase} = Transcript.last_action(line, "/repo/worktrees/a")
      assert String.length(phrase) <= 60
      assert String.ends_with?(phrase, "…")
    end

    test "a tool with nothing worth naming is just the tool" do
      assert Transcript.last_action(tool("TodoWrite", %{}), "/repo/worktrees/a") ==
               {:tool, "TodoWrite"}
    end

    test "the last line wins, whatever came before it" do
      lines = [
        tool("Read", %{"file_path" => "/repo/worktrees/a/mix.exs"}),
        said("reading the deps"),
        tool("Grep", %{"pattern" => "defmodule"})
      ]

      assert Transcript.last_action(Enum.join(lines, "\n"), "/repo/worktrees/a") ==
               {:tool, "Grep defmodule"}
    end

    test "with no tool call after it, the last thing said is the action" do
      lines = [tool("Read", %{"file_path" => "/x"}), said("Tests pass. Nothing is waiting.")]

      assert Transcript.last_action(Enum.join(lines, "\n"), "/repo/worktrees/a") ==
               {:said, "Nothing is waiting."}
    end

    test "what the person typed is never the mouse's action" do
      lines = [tool("Edit", %{"file_path" => "/repo/worktrees/a/x.ex"}), user("now do the tests")]

      assert Transcript.last_action(Enum.join(lines, "\n"), "/repo/worktrees/a") ==
               {:tool, "Edit x.ex"}
    end

    test "a half-written line is skipped rather than crashing the board" do
      lines = [tool("Edit", %{"file_path" => "/repo/worktrees/a/x.ex"}), ~s({"type":"assist)]

      assert Transcript.last_action(Enum.join(lines, "\n"), "/repo/worktrees/a") ==
               {:tool, "Edit x.ex"}
    end

    test "an escape sequence a mouse printed never reaches the terminal" do
      line = said("done \e]0;PWNED\a\e[2J")

      assert {:said, phrase} = Transcript.last_action(line, "/repo/worktrees/a")
      assert phrase =~ "done"
      refute phrase =~ "\e"
      refute phrase =~ "\a"
    end

    test "a newline in what a tool is doing cannot forge a second row" do
      line = tool("Grep", %{"pattern" => "x\n🐭 main  idle  all clear"})

      assert {:tool, phrase} = Transcript.last_action(line, "/repo/worktrees/a")
      refute phrase =~ "\n"
    end

    test "a field of the wrong shape is skipped, never raised" do
      for line <- [
            JSON.encode!(%{
              "type" => "assistant",
              "message" => %{"content" => [%{"type" => "tool_use", "name" => 123}]}
            }),
            JSON.encode!(%{
              "type" => "assistant",
              "message" => %{"content" => [%{"type" => "text", "text" => %{"a" => 1}}]}
            }),
            JSON.encode!(%{"type" => "assistant", "message" => %{"content" => "not a list"}})
          ] do
        assert Transcript.last_action(line, "/repo/worktrees/a") == nil
      end
    end

    test "nothing readable at all is no action, not a guess" do
      assert Transcript.last_action("", "/repo/worktrees/a") == nil
      assert Transcript.last_action("not json\n{}\n", "/repo/worktrees/a") == nil
    end

    test "the invisible marker a mouse ends on is not a sentence" do
      # The finished marker is three U+2063 and the person never sees it, so it
      # must not become the row either.
      lines = [said("Tests pass.\n\n⁣⁣⁣")]

      assert Transcript.last_action(Enum.join(lines, "\n"), "/repo/worktrees/a") ==
               {:said, "Tests pass."}
    end
  end

  describe "project_dir/2" do
    test "is Claude Code's own spelling of the worktree path" do
      assert Transcript.project_dir("/Users/me/Desktop/projects/whiska/worktrees/feat-a", "/home") ==
               "/home/.claude/projects/-Users-me-Desktop-projects-whiska-worktrees-feat-a"
    end

    test "every character that is not a letter or digit becomes a dash, one for one" do
      # `~/.herdr/worktrees/x` really is recorded as `--herdr-worktrees-x`: the
      # dot and the slash each become their own dash.
      assert Transcript.project_dir("/Users/me/.herdr/worktrees/x", "/home") ==
               "/home/.claude/projects/-Users-me--herdr-worktrees-x"
    end
  end

  describe "read/2" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "whiska-tr-#{Whiska.Test.Unique.id()}")
      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)
      {:ok, tmp: tmp}
    end

    test "reads the newest transcript of that worktree", %{tmp: tmp} do
      worktree = "/repo/worktrees/feat-a"
      dir = Transcript.project_dir(worktree, tmp)
      File.mkdir_p!(dir)

      File.write!(Path.join(dir, "old.jsonl"), tool("Read", %{"file_path" => "/old"}))
      File.write!(Path.join(dir, "new.jsonl"), tool("Edit", %{"file_path" => "#{worktree}/x.ex"}))

      old = Path.join(dir, "old.jsonl")
      File.touch!(old, System.os_time(:second) - 600)

      assert Transcript.read(worktree, user_home: tmp) == {:tool, "Edit x.ex"}
    end

    test "a mouse with no transcript at all has no action", %{tmp: tmp} do
      assert Transcript.read("/repo/worktrees/gone", user_home: tmp) == nil
    end
  end

  describe "activity/2" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "whiska-act-#{Whiska.Test.Unique.id()}")
      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)
      {:ok, tmp: tmp}
    end

    test "says how long the mouse has been silent, alongside what it is doing", %{tmp: tmp} do
      worktree = "/repo/worktrees/feat-a"
      dir = Transcript.project_dir(worktree, tmp)
      File.mkdir_p!(dir)
      file = Path.join(dir, "s.jsonl")
      File.write!(file, tool("Edit", %{"file_path" => "#{worktree}/x.ex"}))
      File.touch!(file, System.os_time(:second) - 300)

      assert %{action: {:tool, "Edit x.ex"}, silent_for: silent} =
               Transcript.activity(worktree, user_home: tmp)

      assert_in_delta silent, 300, 5
    end

    test "a transcript that cannot be stat'd is not silent since 1970", %{tmp: tmp} do
      worktree = "/repo/worktrees/feat-a"
      dir = Transcript.project_dir(worktree, tmp)
      File.mkdir_p!(dir)
      File.ln_s!(Path.join(dir, "gone.jsonl"), Path.join(dir, "s.jsonl"))

      assert %{silent_for: nil} = Transcript.activity(worktree, user_home: tmp)
    end

    test "a mouse with no transcript is not silent, it is unknown", %{tmp: tmp} do
      assert Transcript.activity("/repo/worktrees/gone", user_home: tmp) ==
               %{action: nil, silent_for: nil, context: nil}
    end

    test "carries how full the context is, from the last assistant message's usage", %{tmp: tmp} do
      worktree = "/repo/worktrees/feat-a"
      dir = Transcript.project_dir(worktree, tmp)
      File.mkdir_p!(dir)

      usage = %{"input_tokens" => 5, "cache_read_input_tokens" => 90_000}

      line =
        JSON.encode!(%{
          "type" => "assistant",
          "message" => %{"usage" => usage, "content" => [%{"type" => "text", "text" => "hi"}]}
        })

      File.write!(Path.join(dir, "s.jsonl"), line)

      assert %{context: 90_005} = Transcript.activity(worktree, user_home: tmp)
    end
  end

  describe "passed_over/2" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "whiska-passed-#{Whiska.Test.Unique.id()}")
      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)
      {:ok, tmp: tmp}
    end

    test "a stop passed over while a background command runs, until it reports", %{tmp: tmp} do
      worktree = "/repo/worktrees/feat-a"
      transcript(tmp, worktree, passed_over(), 0)

      assert Transcript.passed_over(worktree, user_home: tmp) == :in_flight

      reported =
        user("<task-notification>\n<task-id>bfz2zzaps</task-id>\n<status>completed</status>")

      transcript(tmp, worktree, passed_over() ++ [reported, said("Green.\n⁣⁣⁣")], 0)

      assert Transcript.passed_over(worktree, user_home: tmp) == nil
    end

    test "a transcript the same size and age is not read again", %{tmp: tmp} do
      worktree = "/repo/worktrees/feat-a"
      transcript(tmp, worktree, passed_over(), 60)

      assert Transcript.passed_over(worktree, user_home: tmp) == :in_flight

      file = Path.join(Transcript.project_dir(worktree, tmp), "s.jsonl")
      %File.Stat{mtime: mtime, size: size} = File.stat!(file, time: :posix)
      File.write!(file, String.duplicate(" ", size))
      File.touch!(file, mtime)

      assert Transcript.passed_over(worktree, user_home: tmp) == :in_flight

      File.write!(file, " ")
      assert Transcript.passed_over(worktree, user_home: tmp) == nil
    end

    test "running/2 counts what is out from the same tail", %{tmp: tmp} do
      worktree = "/repo/worktrees/feat-a"
      transcript(tmp, worktree, passed_over(), 0)

      assert Transcript.running(worktree, user_home: tmp) == %{agents: 0, tasks: 1}
    end
  end

  describe "waiting_on/2" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "whiska-wait-#{Whiska.Test.Unique.id()}")
      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)
      {:ok, tmp: tmp}
    end

    # Read from feat/rules-in-claude-md on 2026-10-11: the output of the calls
    # sent alongside a background `Agent` call was written between the call and
    # its receipt, and pushed the call out of the board's every-tick read.
    test "a subagent launched far back is still out", %{tmp: tmp} do
      worktree = "/repo/worktrees/feat-a"

      lines = [
        call("toolu_b", "Bash", %{"command" => "cat lib/whiska/install.ex"}),
        agent_call("toolu_a"),
        tool_result("toolu_b", String.duplicate("x", 100 * 1024)),
        launched("toolu_a", "a628f31a26fa313db")
      ]

      transcript(tmp, worktree, lines, 150)

      assert Transcript.waiting_on(worktree, user_home: tmp) ==
               %{subagent?: true, in_tool?: false}
    end

    test "a mouse with no transcript waits on nothing it can name", %{tmp: tmp} do
      assert Transcript.waiting_on("/repo/worktrees/gone", user_home: tmp) ==
               %{subagent?: false, in_tool?: false}
    end
  end
end
