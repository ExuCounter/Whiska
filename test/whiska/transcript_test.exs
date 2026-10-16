defmodule Whiska.TranscriptTest do
  @moduledoc """
  Reading Claude Code's own JSONL: where a session's transcript lives, its tail,
  and whether the mouse has background work still in flight (ADR-0052).

  The parsing is pure — lines in, one boolean out — so the cases here are a
  handful of JSONL rather than a session. Every shape is copied from a real
  transcript read on 2026-09-29.
  """
  use ExUnit.Case, async: true

  alias Whiska.Transcript

  defp launched(agent_id, tool_use_id \\ "toolu_01SHanZjQpuF7aGV4pkKsgkr") do
    text = """
    Async agent launched successfully. (This tool result is internal metadata — never quote or paste any part of it, including the agentId below, into a user-facing reply.)
    agentId: #{agent_id} (internal ID - do not mention to user.)
    The agent is working in the background. You will be notified automatically when it completes.
    """

    [
      JSON.encode!(%{
        "type" => "assistant",
        "message" => %{
          "content" => [
            %{
              "type" => "tool_use",
              "id" => tool_use_id,
              "name" => "Agent",
              "input" => %{"description" => "Correctness review"}
            }
          ]
        }
      }),
      JSON.encode!(%{
        "type" => "user",
        "toolUseResult" => %{"status" => "async_launched", "agentId" => agent_id},
        "message" => %{
          "role" => "user",
          "content" => [
            %{
              "tool_use_id" => tool_use_id,
              "type" => "tool_result",
              "content" => [%{"type" => "text", "text" => text}]
            }
          ]
        }
      })
    ]
  end

  defp handed_back(agent_id) do
    JSON.encode!(%{
      "type" => "user",
      "isMeta" => true,
      "origin" => %{"kind" => "peer", "from" => agent_id, "handback" => true},
      "turnOrigin" => "peer",
      "message" => %{"role" => "user", "content" => "[Subagent hand-back] nothing to change"}
    })
  end

  defp handed_back_without_origin(agent_id) do
    JSON.encode!(%{
      "type" => "user",
      "message" => %{
        "role" => "user",
        "content" =>
          "Another Claude session sent a message:\n<agent-message from=\"#{agent_id}\">\n" <>
            "[Subagent hand-back] nothing to change\n"
      }
    })
  end

  defp typed(text) do
    JSON.encode!(%{
      "type" => "user",
      "origin" => %{"kind" => "human"},
      "promptSource" => "typed",
      "turnOrigin" => "human",
      "message" => %{"role" => "user", "content" => text}
    })
  end

  defp said(text) do
    JSON.encode!(%{
      "type" => "assistant",
      "message" => %{"content" => [%{"type" => "text", "text" => text}]}
    })
  end

  # A hand-back that lands while the mouse is busy is queued, and Claude Code
  # records the queued copy instead: an `attachment` entry whose `prompt` holds
  # the frame. Copied from a real transcript read on 2026-09-30.
  defp queued_handback(agent_id) do
    JSON.encode!(%{
      "type" => "attachment",
      "attachment" => %{
        "type" => "queued_command",
        "commandMode" => "prompt",
        "isMeta" => true,
        "origin" => %{"kind" => "peer", "from" => agent_id, "handback" => true},
        "prompt" =>
          "<agent-message from=\"#{agent_id}\">\n[Subagent hand-back] nothing to change\n"
      }
    })
  end

  # The same report can also come back framed as a task notification, with the
  # id in `<task-id>` and no `origin` anywhere on the entry.
  defp queued_notification(agent_id) do
    JSON.encode!(%{
      "type" => "attachment",
      "attachment" => %{
        "type" => "queued_command",
        "commandMode" => "task-notification",
        "prompt" =>
          "<task-notification>\n<task-id>#{agent_id}</task-id>\n" <>
            "<tool-use-id>toolu_011v8d56kJo2TbBoT4FrFjoU</tool-use-id>\n</task-notification>"
      }
    })
  end

  defp notification(agent_id) do
    JSON.encode!(%{
      "type" => "user",
      "message" => %{
        "role" => "user",
        "content" => "<task-notification>\n<task-id>#{agent_id}</task-id>\n</task-notification>"
      }
    })
  end

  defp queued_prompt(text) do
    JSON.encode!(%{
      "type" => "attachment",
      "attachment" => %{
        "type" => "queued_command",
        "commandMode" => "prompt",
        "origin" => %{"kind" => "human"},
        "prompt" => text
      }
    })
  end

  defp stamped(lines, timestamp) do
    lines
    |> List.flatten()
    |> Enum.map(fn line ->
      line |> JSON.decode!() |> Map.put("timestamp", timestamp) |> JSON.encode!()
    end)
  end

  # A call and the result Claude Code records for it, with the structured
  # `toolUseResult` beside the text the model reads. Shapes copied from real
  # transcripts read on 2026-10-14.
  defp called(tool, tool_use_id, result) do
    [
      JSON.encode!(%{
        "type" => "assistant",
        "message" => %{
          "content" => [
            %{"type" => "tool_use", "id" => tool_use_id, "name" => tool, "input" => %{}}
          ]
        }
      }),
      JSON.encode!(%{
        "type" => "user",
        "toolUseResult" => result,
        "message" => %{
          "role" => "user",
          "content" => [
            %{"tool_use_id" => tool_use_id, "type" => "tool_result", "content" => "launched"}
          ]
        }
      })
    ]
  end

  defp backgrounded(task_id, tool_use_id \\ "toolu_01JERQVrCMpUmv3GzdgonfK5") do
    called("Bash", tool_use_id, %{
      "stdout" => "",
      "stderr" => "",
      "interrupted" => false,
      "isImage" => false,
      "noOutputExpected" => false,
      "backgroundTaskId" => task_id
    })
  end

  defp resumed(agent_id, tool_use_id \\ "toolu_01XsrZAQezD5VUPyd9162UxM") do
    called("SendMessage", tool_use_id, %{
      "success" => true,
      "message" => "Resuming agent #{String.slice(agent_id, 0, 7)}",
      "resumedAgentId" => agent_id
    })
  end

  defp monitoring(task_id, persistent \\ false) do
    called("Monitor", "toolu_01Hbwb3Vsy6nAyoTKs8fzHVz", %{
      "taskId" => task_id,
      "timeoutMs" => 300_000,
      "persistent" => persistent
    })
  end

  defp workflow(task_id) do
    called("Workflow", "toolu_01Wf", %{
      "status" => "async_launched",
      "taskId" => task_id,
      "taskType" => "local_workflow",
      "runId" => "wf_158826e6-71c"
    })
  end

  defp task_stopped(task_id) do
    called("TaskStop", "toolu_01Stop", %{
      "message" => "Successfully stopped task: #{task_id} (Full suite)",
      "task_id" => task_id,
      "task_type" => "local_bash"
    })
  end

  defp reported(task_id, rest) do
    JSON.encode!(%{
      "type" => "user",
      "origin" => %{"kind" => "task-notification", "producer" => "session-task"},
      "message" => %{
        "role" => "user",
        "content" =>
          "<task-notification>\n<task-id>#{task_id}</task-id>\n#{rest}</task-notification>"
      }
    })
  end

  defp completed(task_id),
    do:
      reported(
        task_id,
        "<status>completed</status>\n<summary>Background command done</summary>\n"
      )

  defp jsonl(lines), do: lines |> List.flatten() |> Enum.join("\n")

  describe "in_flight?/2" do
    test "a reviewer launched and not handed back is still out" do
      text = jsonl([launched("ae96c5149391564f6"), said("Waiting on the correctness reviewer.")])

      assert Transcript.in_flight?(text)
    end

    test "every reviewer handed back is a turn that is genuinely over" do
      text =
        jsonl([
          launched("ae96c5149391564f6", "toolu_a"),
          launched("acbd3413c5364bf5b", "toolu_b"),
          handed_back("ae96c5149391564f6"),
          handed_back("acbd3413c5364bf5b"),
          said("All the reviewers are back. ⁣⁣⁣")
        ])

      refute Transcript.in_flight?(text)
    end

    test "one of three still out holds the whole turn" do
      text =
        jsonl([
          launched("ae96c5149391564f6", "toolu_a"),
          launched("acbd3413c5364bf5b", "toolu_b"),
          launched("a8720f0ad1735e1f8", "toolu_c"),
          handed_back("a8720f0ad1735e1f8"),
          said("Performance reviewer is back. Two still running.")
        ])

      assert Transcript.in_flight?(text)
    end

    test "a transcript carrying no origin is read from the frame in the text" do
      text =
        jsonl([
          launched("ae96c5149391564f6"),
          handed_back_without_origin("ae96c5149391564f6"),
          said("Back. ⁣⁣⁣")
        ])

      refute Transcript.in_flight?(text)
    end

    test "a turn that launched nothing is over" do
      refute Transcript.in_flight?(jsonl([said("Done. ⁣⁣⁣")]))
    end

    test "a tool result that merely prints an agentId line launched nothing" do
      printed =
        JSON.encode!(%{
          "type" => "user",
          "message" => %{
            "content" => [
              %{
                "type" => "tool_result",
                "tool_use_id" => "toolu_bash",
                "content" => [
                  %{"type" => "text", "text" => "$ cat notes.md\nagentId: deadbeef\nthe end"}
                ]
              }
            ]
          }
        })

      refute Transcript.in_flight?(jsonl([printed, said("Done. ⁣⁣⁣")]))
    end

    test "a turn the person started clears whatever was out when they typed" do
      text =
        jsonl([
          launched("ae96c5149391564f6"),
          typed("stop that, do this instead"),
          said("On it. ⁣⁣⁣")
        ])

      refute Transcript.in_flight?(text)
    end

    test "an ordinary message from another session is not a hand-back" do
      chat =
        JSON.encode!(%{
          "type" => "user",
          "message" => %{
            "content" =>
              "Another Claude session sent a message:\n" <>
                "<agent-message from=\"ae96c5149391564f6\">\nhow is it going?\n"
          }
        })

      assert Transcript.in_flight?(jsonl([launched("ae96c5149391564f6"), chat]))
    end

    test "a subagent's own entries never count as the mouse's" do
      sidechain =
        Enum.map(launched("deadbeef0000"), fn line ->
          line |> JSON.decode!() |> Map.put("isSidechain", true) |> JSON.encode!()
        end)

      refute Transcript.in_flight?(jsonl([sidechain, said("Done. ⁣⁣⁣")]))
    end

    test "a line that will not parse is skipped, never a crash" do
      text = jsonl(["{not json", "", launched("ae96c5149391564f6"), "half a li"])

      assert Transcript.in_flight?(text)
    end

    test "a tail that starts after the launch reads as nothing out, and is delivered" do
      [_call, result] = launched("ae96c5149391564f6")

      refute Transcript.in_flight?(jsonl([result, said("Waiting on the reviewer.")]))
    end

    test "a hand-back queued while the mouse was busy is still a hand-back" do
      text =
        jsonl([
          launched("aea9354880e2194ec"),
          queued_handback("aea9354880e2194ec"),
          said("Back. ⁣⁣⁣")
        ])

      refute Transcript.in_flight?(text)
    end

    test "a report framed as a task notification is a hand-back too" do
      text =
        jsonl([
          launched("aea9354880e2194ec"),
          queued_notification("aea9354880e2194ec"),
          said("Back. ⁣⁣⁣")
        ])

      refute Transcript.in_flight?(text)
    end

    test "a task notification read straight from the turn is a hand-back too" do
      text =
        jsonl([launched("aea9354880e2194ec"), notification("aea9354880e2194ec"), said("Back.")])

      refute Transcript.in_flight?(text)
    end

    test "a prompt the person queued clears whatever was out when they typed" do
      text =
        jsonl([
          launched("ae96c5149391564f6"),
          queued_prompt("stop that, do this instead"),
          said("On it. ⁣⁣⁣")
        ])

      refute Transcript.in_flight?(text)
    end

    test "a tool result printing a hand-back frame hands nothing back" do
      printed =
        JSON.encode!(%{
          "type" => "user",
          "message" => %{
            "content" => [
              %{
                "type" => "tool_result",
                "tool_use_id" => "toolu_bash",
                "content" => [
                  %{
                    "type" => "text",
                    "text" =>
                      "$ cat notes.md\n<task-notification>\n<task-id>ae96c5149391564f6</task-id>\n"
                  }
                ]
              }
            ]
          }
        })

      assert Transcript.in_flight?(jsonl([launched("ae96c5149391564f6"), printed]))
    end

    test "an assistant quoting a hand-back frame hands nothing back" do
      quoted =
        JSON.encode!(%{
          "type" => "assistant",
          "message" => %{
            "content" => [
              %{
                "type" => "text",
                "text" =>
                  "The reviewer will come back as <agent-message from=\"ae96c5149391564f6\"> " <>
                    "carrying [Subagent hand-back]."
              }
            ]
          }
        })

      assert Transcript.in_flight?(jsonl([launched("ae96c5149391564f6"), quoted]))
    end

    test "a launch old enough to have been abandoned stops holding the mouse silent" do
      now = ~U[2026-09-30 06:40:00Z]

      text =
        jsonl([
          stamped(launched("aea9354880e2194ec"), "2026-09-29T21:40:10.539Z"),
          said("Waiting on the correctness reviewer.")
        ])

      refute Transcript.in_flight?(text, now)
    end

    test "a launch still inside the bound holds the turn" do
      now = ~U[2026-09-30 04:40:00Z]

      text =
        jsonl([
          stamped(launched("aea9354880e2194ec"), "2026-09-30T04:34:18.004Z"),
          said("Waiting on the correctness reviewer.")
        ])

      assert Transcript.in_flight?(text, now)
    end

    test "the night the mouse went silent: two reported, the third came back queued" do
      now = ~U[2026-09-30 04:40:07Z]

      text =
        jsonl([
          stamped(launched("aea9354880e2194ec", "toolu_a"), "2026-09-30T04:29:00.000Z"),
          stamped(launched("ae3c8ed23a403e604", "toolu_b"), "2026-09-30T04:29:01.000Z"),
          stamped(launched("a4984a5dfda23ce03", "toolu_c"), "2026-09-30T04:29:02.000Z"),
          handed_back("ae3c8ed23a403e604"),
          queued_notification("aea9354880e2194ec"),
          handed_back("a4984a5dfda23ce03"),
          said("All three are back. ⁣⁣⁣")
        ])

      refute Transcript.in_flight?(text, now)
    end

    test "a background command not yet reported is still out" do
      text =
        jsonl([
          backgrounded("bfz2zzaps"),
          said("The full suite is running; I'll commit once it is back.")
        ])

      assert Transcript.in_flight?(text)
    end

    test "a background command is back once it reports" do
      text = jsonl([backgrounded("bfz2zzaps"), completed("bfz2zzaps"), said("Green. ⁣⁣⁣")])

      refute Transcript.in_flight?(text)
    end

    test "a reviewer restarted after it reported is out again" do
      text =
        jsonl([
          launched("af4b8edd5d3bdba93"),
          notification("af4b8edd5d3bdba93"),
          resumed("af4b8edd5d3bdba93"),
          said("The second review round is running.")
        ])

      assert Transcript.in_flight?(text)
    end

    test "a monitor's events are not its report; the end of its stream is" do
      event =
        reported("bdtmob3pl", "<summary>Monitor event: \"ci\"</summary>\n<event>one</event>\n")

      ended =
        reported(
          "bdtmob3pl",
          "<status>completed</status>\n<summary>Monitor \"ci\" stream ended</summary>\n"
        )

      assert Transcript.in_flight?(jsonl([monitoring("bdtmob3pl"), event, said("Watching CI.")]))
      refute Transcript.in_flight?(jsonl([monitoring("bdtmob3pl"), event, ended, said("Done.")]))
    end

    test "a monitor that expired is back" do
      expired =
        reported(
          "bojj2q14a",
          "<summary>Monitor event: \"ci\"</summary>\n<event>[Monitor expired after 25m with " <>
            "no events delivered. Re-arm it if you still need the watch.]</event>\n"
        )

      refute Transcript.in_flight?(jsonl([monitoring("bojj2q14a"), expired, said("Done.")]))
    end

    test "a monitor event whose output prints a status is not the end of the stream" do
      event =
        reported(
          "bdtmob3pl",
          "<summary>Monitor event: \"ci\"</summary>\n<event><status>completed</status></event>\n"
        )

      assert Transcript.in_flight?(jsonl([monitoring("bdtmob3pl"), event, said("Watching.")]))
    end

    test "a persistent monitor runs for the whole session and never holds a turn" do
      refute Transcript.in_flight?(jsonl([monitoring("bdtmob3pl", true), said("Watching.")]))
    end

    test "a workflow is out until it reports" do
      assert Transcript.in_flight?(jsonl([workflow("wi8y8u3am"), said("Fanned out.")]))
      refute Transcript.in_flight?(jsonl([workflow("wi8y8u3am"), completed("wi8y8u3am")]))
    end

    test "an agent still running work of its own has not reported, whatever its status says" do
      interim =
        reported(
          "ad65668c4e7729f3a",
          "<status>completed</status>\n<summary>Agent \"Review\" finished</summary>\n" <>
            "<note>This agent stopped with background work of its own still running. It may " <>
            "resume on its own when that work completes or reports, and the same task-id " <>
            "notifies again if it does; the result below may be interim.</note>\n"
        )

      text = jsonl([launched("ad65668c4e7729f3a"), interim, said("Reviewer still going.")])

      assert Transcript.in_flight?(text)
      refute Transcript.in_flight?(jsonl([text, completed("ad65668c4e7729f3a")]))
    end

    test "a report whose result quotes an interim note is still the report" do
      quoting =
        reported(
          "ad65668c4e7729f3a",
          "<status>completed</status>\n<summary>Agent \"Review\" finished</summary>\n" <>
            "<result>The hook reads a <note> about work still running as interim.</result>\n"
        )

      refute Transcript.in_flight?(jsonl([launched("ad65668c4e7729f3a"), quoting]))
    end

    test "an Agent call that ran in the foreground launched nothing, whatever its report prints" do
      foreground =
        called("Agent", "toolu_01Fg", %{"status" => "completed", "agentId" => "a1b2c3d4e5"})
        |> List.update_at(1, fn line ->
          line
          |> JSON.decode!()
          |> put_in(["message", "content"], [
            %{
              "type" => "tool_result",
              "tool_use_id" => "toolu_01Fg",
              "content" => [%{"type" => "text", "text" => "The page said:\nagentId: deadbeef\n"}]
            }
          ])
          |> JSON.encode!()
        end)

      refute Transcript.in_flight?(jsonl([foreground, said("Done. ⁣⁣⁣")]))
    end

    test "an Agent result Claude Code did not record as launched in the background launched nothing" do
      unrecorded =
        "ae96c51"
        |> launched()
        |> List.update_at(
          1,
          &(&1 |> JSON.decode!() |> Map.delete("toolUseResult") |> JSON.encode!())
        )

      refute Transcript.in_flight?(jsonl(unrecorded))
    end

    test "a task the mouse stopped is back, report or none" do
      text = jsonl([backgrounded("bfz2zzaps"), task_stopped("bfz2zzaps"), said("Stopped it.")])

      refute Transcript.in_flight?(text)
    end

    test "a task id in any other tool's result launches nothing" do
      mcp =
        called("mcp__tracker__create", "toolu_01Mcp", %{
          "taskId" => "t1",
          "backgroundTaskId" => "t2"
        })

      skill =
        called("Skill", "toolu_01Sk", %{"status" => "forked", "agentId" => "acf17a66bc47a963b"})

      refute Transcript.in_flight?(jsonl([mcp, skill, said("Done. ⁣⁣⁣")]))
    end

    test "nothing readable at all means nothing is out — the safe direction is to deliver" do
      refute Transcript.in_flight?("")
      refute Transcript.in_flight?("{not json\n{also not")
    end
  end

  describe "passed_over/2" do
    @now ~U[2026-10-14 15:00:00Z]

    defp read(lines), do: lines |> jsonl() |> Transcript.background()

    test "an unmarked last word with work out is a stop passed over, waiting on that work" do
      text = [stamped(backgrounded("bfz2zzaps"), "2026-10-14T14:50:00Z"), said("Suite running.")]

      assert Transcript.passed_over(read(text), @now) == :in_flight
    end

    test "past the half hour with nothing reported it is abandoned" do
      text = stamped([backgrounded("bfz2zzaps"), said("Suite running.")], "2026-10-14T14:20:00Z")

      assert Transcript.passed_over(read(text), @now) == :abandoned
    end

    test "a stop made once the work was half an hour old was delivered, not passed over" do
      text = [
        stamped(backgrounded("bfz2zzaps"), "2026-10-14T14:00:00Z"),
        stamped([said("Still running?")], "2026-10-14T14:40:00Z")
      ]

      assert Transcript.passed_over(read(text), @now) == nil
    end

    test "a marked last word was delivered beside a background command" do
      text = [stamped(backgrounded("bfz2zzaps"), "2026-10-14T14:50:00Z"), said("Pick one?\n⁣⁣")]

      assert Transcript.passed_over(read(text), @now) == nil
    end

    test "a marked last word with a subagent out is a stop passed over too (ADR-0052)" do
      for word <- ["Pick one?\n⁣⁣", "Done.\n⁣⁣⁣"] do
        text = [stamped(launched("ae96c51"), "2026-10-14T14:50:00Z"), said(word)]

        assert Transcript.passed_over(read(text), @now) == :in_flight
      end
    end

    test "a marked last word is abandoned once its subagent is half an hour old" do
      text = stamped([launched("ae96c51"), said("Done.\n⁣⁣⁣")], "2026-10-14T14:20:00Z")

      assert Transcript.passed_over(read(text), @now) == :abandoned
    end

    test "a marked last word said once its subagent was half an hour old was delivered" do
      text = [
        stamped(launched("ae96c51"), "2026-10-14T14:00:00Z"),
        stamped([said("Done.\n⁣⁣⁣")], "2026-10-14T14:40:00Z")
      ]

      assert Transcript.passed_over(read(text), @now) == nil
    end

    test "a marked last word after the subagent reported was delivered" do
      text = [launched("ae96c51"), completed("ae96c51"), said("Done.\n⁣⁣⁣")]

      assert Transcript.passed_over(read(text), @now) == nil
    end

    test "a turn that died on an API error was not passed over" do
      died =
        JSON.encode!(%{
          "type" => "assistant",
          "isApiErrorMessage" => true,
          "message" => %{"content" => [%{"type" => "text", "text" => "API Error: gone"}]}
        })

      text = [stamped(backgrounded("bfz2zzaps"), "2026-10-14T14:20:00Z"), said("Running."), died]

      assert Transcript.passed_over(read(text), @now) == nil
    end

    test "nothing unreported is nothing passed over" do
      text = [backgrounded("bfz2zzaps"), completed("bfz2zzaps"), said("Green.")]

      assert Transcript.passed_over(read(text), @now) == nil
    end

    test "a subagent's own words are not the mouse's last word" do
      theirs =
        "Waiting." |> said() |> JSON.decode!() |> Map.put("isSidechain", true) |> JSON.encode!()

      text = [
        stamped(backgrounded("bfz2zzaps"), "2026-10-14T14:50:00Z"),
        said("Done.\n⁣⁣⁣"),
        theirs
      ]

      assert Transcript.passed_over(read(text), @now) == nil
    end
  end

  describe "holds_stop?/3" do
    @now ~U[2026-10-14 15:00:00Z]

    test "an unmarked stop is held by any work out, a marked one only by a subagent" do
      command = read(stamped(backgrounded("bfz2zzaps"), "2026-10-14T14:50:00Z"))
      subagent = read(stamped(launched("ae96c51"), "2026-10-14T14:50:00Z"))

      assert Transcript.holds_stop?(command, :unmarked, @now)
      refute Transcript.holds_stop?(command, :marked, @now)
      assert Transcript.holds_stop?(subagent, :unmarked, @now)
      assert Transcript.holds_stop?(subagent, :marked, @now)
    end

    test "a subagent that reported, or is half an hour old, holds nothing" do
      reported = read([launched("ae96c51"), completed("ae96c51")])
      old = read(stamped(launched("ae96c51"), "2026-10-14T14:20:00Z"))

      refute Transcript.holds_stop?(reported, :marked, @now)
      refute Transcript.holds_stop?(old, :marked, @now)
    end
  end

  describe "releases_held?/3 — a held marked stop whose subagents are done and turn has ended" do
    @held_at ~U[2026-10-14 14:50:00Z]
    @word "Done.\n⁣⁣⁣"

    defp releases?(lines, stamp, held_at \\ @held_at),
      do: Transcript.releases_held?(read(stamped(lines, stamp)), held_at, @now)

    test "not while a subagent is still out" do
      refute releases?([launched("ae96c51"), said(@word)], "2026-10-14T14:50:00Z")
    end

    test "not while the mouse is mid-turn: the subagent reported and it woke to work" do
      lines = [launched("ae96c51"), said(@word), completed("ae96c51")]

      refute releases?(lines, "2026-10-14T14:50:00Z")
    end

    test "once the subagent is half an hour old and the mouse said nothing since" do
      assert releases?([launched("ae96c51"), said(@word)], "2026-10-14T14:20:00Z")
    end

    test "once the stop itself is half an hour old, even with the mouse working" do
      lines = [launched("ae96c51"), said(@word), completed("ae96c51")]

      assert releases?(lines, "2026-10-14T14:50:00Z", ~U[2026-10-14 14:20:00Z])
    end

    test "once the mouse's turn has ended again with nothing out" do
      lines = [launched("ae96c51"), said(@word), completed("ae96c51"), said("Fixed it.")]

      assert releases?(lines, "2026-10-14T14:50:00Z")
    end

    test "a turn that died on an API error has ended" do
      died =
        JSON.encode!(%{
          "type" => "assistant",
          "isApiErrorMessage" => true,
          "message" => %{"content" => [%{"type" => "text", "text" => "API Error: gone"}]}
        })

      lines = [launched("ae96c51"), said(@word), completed("ae96c51"), died]

      assert releases?(lines, "2026-10-14T14:50:00Z")
    end
  end

  describe "Whiska's own lines (ADR-0052)" do
    @letter_copy "/Users/p/whiska/worktrees/feat/composed-question-links/.whiska-letters/20261016-093700-b6aa0e31.md"

    # #657, from the mouse's own transcript on 2026-10-16: two reviewers launched
    # at 09:34, the mouse's unmarked note while they ran, then at 09:37:01 the
    # letter `whiska send` typed, stamped as though the person typed it, and the
    # mouse's answer to it.
    defp letter_while_reviewing do
      stamped(
        [
          launched("a19dd46ea60e1d4f5", "toolu_015jYKc7W3YoDosGsSVZD23H"),
          launched("adff5a697a18db578", "toolu_01KFzXWwV5Dtqso2CsbSJ3vD"),
          said("Both reviewers (general and security) are still running."),
          typed(Whiska.Send.line(@letter_copy, false)),
          called("Bash", "toolu_01Hu8LCpThGCFwLvQgERGkLd", %{"stdout" => "The person agreed"}),
          said("The letter conflicts with ADR-0089's rule for the Summary.")
        ],
        "2026-10-16T09:37:22.587Z"
      )
    end

    test "the letter Whiska typed keeps the two reviewers #657 had out, and its answer is a reply" do
      background = read(letter_while_reviewing())

      assert [{"Agent", _}, {"Agent", _}] = background.unreported
      assert background.reply?
    end

    test "the doorbell keeps the count, and the answer after it is a reply" do
      background =
        read([launched("ae96c5149391564f6"), typed(Whiska.Doorbell.line(656)), said("Building.")])

      assert [{"Agent", _}] = background.unreported
      assert background.reply?
    end

    test "a letter queued while the mouse was busy keeps the count and makes a reply too" do
      background =
        read([
          launched("ae96c5149391564f6"),
          queued_prompt(Whiska.Send.line(@letter_copy, true)),
          said("Answered.")
        ])

      assert [{"Agent", _}] = background.unreported
      assert background.reply?
    end

    test "the pickup, lifted-hold and review-round lines keep the count, and make no reply" do
      for line <- [
            Whiska.Pickup.line(),
            Whiska.Delivery.Mode.resume_line(),
            Whiska.ReviewRound.line(@letter_copy)
          ] do
        background = read([launched("ae96c5149391564f6"), typed(line), said("Carrying on.")])

        assert [{"Agent", _}] = background.unreported, line
        refute background.reply?, line
      end
    end

    test "what the person types into the pane still clears the count, and makes no reply" do
      for words <- [
            "stop that, do this instead",
            Whiska.Send.line(@letter_copy, false) <> " and hurry",
            Whiska.Send.line("/tmp/notes.md", false),
            String.replace(Whiska.Doorbell.line(656), "656", "#656")
          ] do
        background = read([launched("ae96c5149391564f6"), typed(words), said("On it.")])

        assert background.unreported == [], words
        refute background.reply?, words
      end
    end

    test "a note after the mouse launched new work on the letter is no reply" do
      background =
        read([
          launched("ae96c5149391564f6"),
          typed(Whiska.Send.line(@letter_copy, false)),
          launched("a5b0bb7bb6e23e2d6", "toolu_01New"),
          said("Reviewing the new piece.")
        ])

      assert length(background.unreported) == 2
      refute background.reply?
    end

    test "a report that wakes the mouse after its reply ends the reply" do
      background =
        read([
          launched("ae96c5149391564f6", "toolu_01A"),
          launched("a5b0bb7bb6e23e2d6", "toolu_01B"),
          typed(Whiska.Send.line(@letter_copy, false)),
          said("Answered."),
          reported("ae96c5149391564f6", "<status>completed</status>\n"),
          said("One reviewer is back; waiting on the other.")
        ])

      assert [{"Agent", _}] = background.unreported
      refute background.reply?
    end

    test "a report queued while the mouse answers the letter leaves it a reply" do
      background =
        read([
          launched("ae96c5149391564f6", "toolu_01A"),
          launched("a5b0bb7bb6e23e2d6", "toolu_01B"),
          typed(Whiska.Send.line(@letter_copy, false)),
          queued_notification("ae96c5149391564f6"),
          said("Answered.")
        ])

      assert [{"Agent", _}] = background.unreported
      assert background.reply?
    end

    test "a pickup after the reply's turn died carries the reply on" do
      died =
        JSON.encode!(%{
          "type" => "assistant",
          "isApiErrorMessage" => true,
          "message" => %{"content" => [%{"type" => "text", "text" => "API Error: gone"}]}
        })

      for line <- [Whiska.Pickup.line(), Whiska.Delivery.Mode.resume_line()] do
        background =
          read([
            launched("ae96c5149391564f6"),
            typed(Whiska.Send.line(@letter_copy, false)),
            died,
            typed(line),
            said("Answered.")
          ])

        assert background.reply?, line
      end
    end

    test "the lifted-hold line after a reply was written begins no second reply" do
      background =
        read([
          launched("ae96c5149391564f6"),
          typed(Whiska.Send.line(@letter_copy, false)),
          said("Answered."),
          typed(Whiska.Delivery.Mode.resume_line()),
          said("Carrying on.")
        ])

      refute background.reply?
    end

    test "a report with no stamp that wakes the mouse ends the reply too" do
      background =
        read([
          launched("ae96c5149391564f6", "toolu_01A"),
          launched("a5b0bb7bb6e23e2d6", "toolu_01B"),
          typed(Whiska.Send.line(@letter_copy, false)),
          said("Answered."),
          notification("ae96c5149391564f6"),
          said("One reviewer is back; waiting on the other.")
        ])

      assert [{"Agent", _}] = background.unreported
      refute background.reply?
    end

    test "a reply was written: beside its work it is in flight, and never abandoned" do
      reply = [launched("ae96c5149391564f6"), typed(Whiska.Doorbell.line(656)), said("Answered.")]

      assert Transcript.passed_over(read(stamped(reply, "2026-10-14T14:50:00Z")), @now) ==
               :in_flight

      assert Transcript.passed_over(read(stamped(reply, "2026-10-14T14:20:00Z")), @now) == nil
    end

    test "a letter with nothing out is no reply: nothing holds its stop" do
      background = read([typed(Whiska.Send.line(@letter_copy, false)), said("Answered.")])

      assert background.unreported == []
      refute background.reply?
    end
  end

  describe "stopped work" do
    test "an agent the person stopped is back" do
      killed =
        reported(
          "ac4593a54547b3f61",
          "<status>killed</status>\n<summary>Agent \"Review\" was stopped by user</summary>\n" <>
            "<note>A task-notification fires each time this agent stops with no live " <>
            "background children of its own.</note>\n"
        )

      refute Transcript.in_flight?(jsonl([launched("ac4593a54547b3f61"), killed]))
    end

    # Copied from a mouse restarted on 2026-10-15 with two reviewers out: one
    # notice names both, a `<task-id>` line each.
    test "every agent a restarted session says it lost is back, not only the first" do
      lost =
        JSON.encode!(%{
          "type" => "user",
          "origin" => %{"kind" => "task-notification"},
          "promptSource" => "system",
          "message" => %{
            "role" => "user",
            "content" =>
              "<task-notification>\n<task-id>abd0e5ca6ddc6be54</task-id>\n" <>
                "<task-id>a1d793af384a74209</task-id>\n<status>stopped</status>\n" <>
                "<summary>2 background agents didn't finish before the previous session " <>
                "ended: \"Fresh code review of branch\" (abd0e5ca6ddc6be54), \"Security " <>
                "review of branch\" (a1d793af384a74209).</summary>\n</task-notification>"
          }
        })

      text =
        jsonl([
          launched("abd0e5ca6ddc6be54", "toolu_01A"),
          launched("a1d793af384a74209", "toolu_01B"),
          lost
        ])

      refute Transcript.in_flight?(text)
    end

    test "a task id in the work's own output is not the notice's" do
      quoting =
        reported(
          "ae96c5149391564f6",
          "<status>completed</status>\n<result>see <task-id>a5b0bb7bb6e23e2d6</task-id></result>\n"
        )

      text =
        jsonl([
          launched("ae96c5149391564f6", "toolu_01A"),
          launched("a5b0bb7bb6e23e2d6", "toolu_01B"),
          quoting
        ])

      assert [{"Agent", _}] = Transcript.background(text).unreported
    end
  end

  describe "running/2" do
    test "counts the agents and the other tasks still out" do
      background =
        Transcript.background(
          jsonl([
            launched("ae96c5149391564f6", "toolu_01A"),
            resumed("af4b8ed0000000000"),
            backgrounded("bfz2zzaps")
          ])
        )

      assert Transcript.running(background, DateTime.utc_now()) == %{agents: 2, tasks: 1}
    end

    test "work half an hour old is not counted" do
      background =
        [launched("ae96c5149391564f6")]
        |> stamped("2026-10-16T09:00:00Z")
        |> jsonl()
        |> Transcript.background()

      assert Transcript.running(background, ~U[2026-10-16 09:31:00Z]) == %{agents: 0, tasks: 0}
    end
  end

  describe "subagent_in_flight?/2" do
    test "a subagent launched or restarted counts, a background command does not" do
      now = DateTime.utc_now()

      assert Transcript.subagent_in_flight?(
               Transcript.background(jsonl(launched("ae96c51"))),
               now
             )

      assert Transcript.subagent_in_flight?(Transcript.background(jsonl(resumed("af4b8ed"))), now)

      refute Transcript.subagent_in_flight?(
               Transcript.background(jsonl(backgrounded("bfz2zzaps"))),
               now
             )
    end
  end

  describe "ended_on_api_error?/1" do
    # The shape of the entry Claude Code wrote at 15:44:24 UTC on 2026-10-07 on
    # feat/sidebar-status, and of the bookkeeping entries that followed it.
    defp api_error(fields \\ %{}) do
      Map.merge(
        %{
          "type" => "assistant",
          "isSidechain" => false,
          "isApiErrorMessage" => true,
          "error" => "server_error",
          "message" => %{
            "model" => "<synthetic>",
            "role" => "assistant",
            "content" => [
              %{"type" => "text", "text" => "API Error: The response stopped arriving."}
            ]
          }
        },
        fields
      )
      |> JSON.encode!()
    end

    defp bookkeeping do
      [
        ~s({"type":"system","subtype":"turn_duration","durationMs":215204}),
        ~s({"type":"file-history-snapshot","messageId":"f3b7"}),
        ~s({"type":"permission-mode","permissionMode":"auto"}),
        ~s({"type":"attachment","attachment":{"type":"total_tokens_reminder"}})
      ]
    end

    test "is true when the last real entry is the API error" do
      text = jsonl([said("working on it"), api_error()])

      assert Transcript.ended_on_api_error?(text)
    end

    test "reads past the bookkeeping Claude Code writes after the error" do
      text = jsonl([said("working on it"), api_error(), bookkeeping()])

      assert Transcript.ended_on_api_error?(text)
    end

    test "is false once anything real follows the error" do
      assert not Transcript.ended_on_api_error?(jsonl([api_error(), typed("try again")]))
      assert not Transcript.ended_on_api_error?(jsonl([api_error(), said("on it")]))
    end

    test "is false for a turn that ended on an ordinary message" do
      refute Transcript.ended_on_api_error?(jsonl([api_error(), said("done"), bookkeeping()]))
    end

    test "a subagent's error is not the mouse's" do
      refute Transcript.ended_on_api_error?(
               jsonl([said("hi"), api_error(%{"isSidechain" => true})])
             )
    end

    test "is false for a transcript with nothing readable in it" do
      refute Transcript.ended_on_api_error?("")
      refute Transcript.ended_on_api_error?("not json\n{half")
    end
  end

  describe "api_error/1" do
    test "reads the kind, when it was written and when a rate limit resets" do
      text =
        jsonl([
          said("on it"),
          api_error(%{
            "error" => "rate_limit",
            "timestamp" => "2026-10-13T12:55:33.143Z",
            "quotaLimits" => %{"status" => "rejected", "resetsAt" => 1_791_986_400}
          })
        ])

      assert %{kind: "rate_limit", at: %DateTime{}, resets_at: reset} = Transcript.api_error(text)
      assert reset == DateTime.from_unix!(1_791_986_400)
    end

    test "an entry with no kind is unknown, and one with no reset has none" do
      text = jsonl([api_error(%{"error" => nil})])

      assert %{kind: "unknown", at: nil, resets_at: nil} = Transcript.api_error(text)
    end

    test "a reset no clock can hold is no reset, never a crash" do
      text = jsonl([api_error(%{"quotaLimits" => %{"resetsAt" => 10 ** 30}})])

      assert %{resets_at: nil} = Transcript.api_error(text)
    end

    test "a kind longer than any Claude Code writes is unknown" do
      text = jsonl([api_error(%{"error" => String.duplicate("x", 65)})])

      assert %{kind: "unknown"} = Transcript.api_error(text)
    end

    test "is nil when the last real entry is anything else" do
      assert Transcript.api_error(jsonl([api_error(), typed("try again")])) == nil
    end
  end

  describe "ran_on/1" do
    # The shape of an assistant entry, read from a real transcript on 2026-10-04.
    defp answered(model, fields \\ %{}) do
      Map.merge(
        %{
          "type" => "assistant",
          "isSidechain" => false,
          "message" => %{
            "model" => model,
            "role" => "assistant",
            "content" => [%{"type" => "text", "text" => "ok"}]
          }
        },
        fields
      )
      |> JSON.encode!()
    end

    defp lines(entries), do: Enum.join(entries, "\n")

    test "is the model id the latest answer came from, not the alias asked for" do
      assert Transcript.ran_on(lines([answered("claude-a-5"), answered("claude-b-5")])) ==
               "claude-b-5"
    end

    test "skips the placeholder Claude Code writes for a message no model sent" do
      assert Transcript.ran_on(lines([answered("claude-a-5"), answered("<synthetic>")])) ==
               "claude-a-5"
    end

    test "is the session's own model, never a subagent's" do
      text = lines([answered("claude-a-5"), answered("claude-b-5", %{"isSidechain" => true})])
      assert Transcript.ran_on(text) == "claude-a-5"
    end

    test "reads the answer's own model, not a model named in a tool call" do
      call =
        JSON.encode!(%{
          "type" => "assistant",
          "message" => %{
            "content" => [
              %{"type" => "tool_use", "name" => "Agent", "input" => %{"model" => "claude-c-5"}}
            ]
          }
        })

      assert Transcript.ran_on(lines([answered("claude-a-5"), call])) == "claude-a-5"
    end

    test "takes only a model id that is safe to print to a terminal" do
      text =
        lines([
          answered("claude-a-5"),
          answered("\e]0;x\a"),
          answered(String.duplicate("a", 200))
        ])

      assert Transcript.ran_on(text) == "claude-a-5"
    end

    test "is nil when no answer says, or nothing parses" do
      assert Transcript.ran_on("") == nil
      assert Transcript.ran_on("{not json\n" <> JSON.encode!(%{"type" => "user"})) == nil
    end
  end

  describe "tail/2" do
    setup do
      path = Path.join(System.tmp_dir!(), "whiska-tail-#{Whiska.Test.Unique.id()}")
      on_exit(fn -> File.rm_rf!(path) end)
      {:ok, path: path}
    end

    test "a file shorter than the budget comes back whole", %{path: path} do
      File.write!(path, "one\ntwo\n")

      assert Transcript.tail(path, 1024) == "one\ntwo\n"
    end

    test "a cut file drops its first line, which may be half a line", %{path: path} do
      File.write!(path, "aaaaaaaaaa\nbbbb\ncccc\n")

      assert Transcript.tail(path, 12) == "bbbb\ncccc\n"
    end

    test "a file that is not there is empty, never a crash", %{path: path} do
      assert Transcript.tail(path, 1024) == ""
    end

    test "a pipe is empty rather than a hook that hangs on it", %{path: path} do
      File.mkdir_p!(path)
      fifo = Path.join(path, "pipe")
      {_, 0} = System.cmd("mkfifo", [fifo])

      assert Transcript.tail(path, 1024) == ""
      assert Transcript.tail(fifo, 1024) == ""
    end
  end

  describe "project_dir/2" do
    test "every character that is not a letter or a digit becomes its own dash" do
      assert Transcript.project_dir("/Users/x/.herdr/worktrees/a", "/home") ==
               "/home/.claude/projects/-Users-x--herdr-worktrees-a"
    end
  end

  describe "started_in/1" do
    setup do
      path = Path.join(System.tmp_dir!(), "whiska-start-#{Whiska.Test.Unique.id()}")
      on_exit(fn -> File.rm_rf!(path) end)
      {:ok, path: path}
    end

    test "is the first directory the transcript names, not the last", %{path: path} do
      File.write!(path, [
        JSON.encode!(%{"type" => "mode"}),
        "\n",
        JSON.encode!(%{"type" => "user", "cwd" => "/repo"}),
        "\n",
        JSON.encode!(%{"type" => "user", "cwd" => "/repo/worktrees/feat"}),
        "\n"
      ])

      assert Transcript.started_in(path) == "/repo"
    end

    test "skips lines that will not parse", %{path: path} do
      File.write!(path, "{half a line\n" <> JSON.encode!(%{"cwd" => "/repo"}) <> "\n")

      assert Transcript.started_in(path) == "/repo"
    end

    test "a first line too big for any byte window is skipped, not an answer", %{path: path} do
      giant = JSON.encode!(%{"type" => "user", "message" => String.duplicate("x", 300_000)})
      File.write!(path, giant <> "\n" <> JSON.encode!(%{"cwd" => "/repo"}) <> "\n")

      assert Transcript.started_in(path) == "/repo"
    end

    test "gives up rather than reading a whole transcript of fat lines", %{path: path} do
      fat = JSON.encode!(%{"cwd" => "/repo", "message" => String.duplicate("x", 200_000)})
      File.write!(path, String.duplicate(fat <> "\n", 20))

      assert Transcript.started_in(path) == nil
    end

    test "a transcript that names no directory is nil", %{path: path} do
      File.write!(path, JSON.encode!(%{"type" => "mode"}) <> "\n")

      assert Transcript.started_in(path) == nil
    end

    test "a file that is not there is nil, never a crash", %{path: path} do
      assert Transcript.started_in(path) == nil
    end

    test "a pipe is nil rather than a hook that hangs on it", %{path: path} do
      File.mkdir_p!(path)
      fifo = Path.join(path, "pipe")
      {_, 0} = System.cmd("mkfifo", [fifo])

      assert Transcript.started_in(fifo) == nil
      assert Transcript.started_in(path) == nil
    end
  end

  describe "started_at/1 — when the session began (the doctor's staleness check)" do
    setup do
      dir = Path.join(System.tmp_dir!(), "whiska-startat-#{Whiska.Test.Unique.id()}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      {:ok, path: Path.join(dir, "session.jsonl")}
    end

    test "is when the file was created, to the second", %{path: path} do
      before = DateTime.utc_now()
      File.write!(path, JSON.encode!(%{"type" => "mode"}) <> "\n")

      assert %DateTime{} = at = Transcript.started_at(path)
      assert DateTime.diff(at, before, :second) |> abs() <= 2
    end

    # A resumed session is a new process reading `settings.json` afresh, but
    # Claude Code copies its predecessor's entries into the new transcript
    # verbatim, timestamps and all. Read from two real transcripts on
    # 2026-10-02, 64 minutes apart and sharing a first timestamp: the entries
    # say when the first session began, and only the file says when this one
    # did.
    test "is not the first timestamp inside, which a resumed session inherits", %{path: path} do
      File.write!(path, JSON.encode!(%{"timestamp" => "2026-09-01T00:00:00.000Z"}) <> "\n")

      assert %DateTime{} = at = Transcript.started_at(path)
      assert DateTime.diff(DateTime.utc_now(), at, :second) < 60
    end

    test "a file that is not there is nil, never a crash", %{path: path} do
      assert Transcript.started_at(path) == nil
    end

    test "a directory, or a stat that answers nothing readable, is nil", %{path: path} do
      File.write!(path, "{}\n")

      assert Transcript.started_at(Path.dirname(path)) == nil
      assert Transcript.started_at(path, fn _ -> nil end) == nil
      assert Transcript.started_at(path, fn _ -> "not a number" end) == nil
      assert Transcript.started_at(path, fn _ -> "0" end) == nil
    end

    # `stat -f %B` is macOS's birth time and GNU coreutils' filesystem block
    # size, and GNU exits 0 for it — so a plausible-timestamp check is what
    # keeps a block size from reading as a session that started in 1970.
    test "a number too small to be a timestamp is nil, not 1970", %{path: path} do
      File.write!(path, "{}\n")

      assert Transcript.started_at(path, fn _ -> "4096" end) == nil
    end
  end
end
