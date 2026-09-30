defmodule Whiska.TranscriptTest do
  @moduledoc """
  Reading Claude Code's own JSONL: where a session's transcript lives, its tail,
  and whether the mouse has a subagent still out (ADR-0052).

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

  defp jsonl(lines), do: lines |> List.flatten() |> Enum.join("\n")

  describe "subagents_in_flight?/1" do
    test "a reviewer launched and not handed back is still out" do
      text = jsonl([launched("ae96c5149391564f6"), said("Waiting on the correctness reviewer.")])

      assert Transcript.subagents_in_flight?(text)
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

      refute Transcript.subagents_in_flight?(text)
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

      assert Transcript.subagents_in_flight?(text)
    end

    test "a transcript carrying no origin is read from the frame in the text" do
      text =
        jsonl([
          launched("ae96c5149391564f6"),
          handed_back_without_origin("ae96c5149391564f6"),
          said("Back. ⁣⁣⁣")
        ])

      refute Transcript.subagents_in_flight?(text)
    end

    test "a turn that launched nothing is over" do
      refute Transcript.subagents_in_flight?(jsonl([said("Done. ⁣⁣⁣")]))
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

      refute Transcript.subagents_in_flight?(jsonl([printed, said("Done. ⁣⁣⁣")]))
    end

    test "a turn the person started clears whatever was out when they typed" do
      text =
        jsonl([
          launched("ae96c5149391564f6"),
          typed("stop that, do this instead"),
          said("On it. ⁣⁣⁣")
        ])

      refute Transcript.subagents_in_flight?(text)
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

      assert Transcript.subagents_in_flight?(jsonl([launched("ae96c5149391564f6"), chat]))
    end

    test "a subagent's own entries never count as the mouse's" do
      sidechain =
        Enum.map(launched("deadbeef0000"), fn line ->
          line |> JSON.decode!() |> Map.put("isSidechain", true) |> JSON.encode!()
        end)

      refute Transcript.subagents_in_flight?(jsonl([sidechain, said("Done. ⁣⁣⁣")]))
    end

    test "a line that will not parse is skipped, never a crash" do
      text = jsonl(["{not json", "", launched("ae96c5149391564f6"), "half a li"])

      assert Transcript.subagents_in_flight?(text)
    end

    test "a tail that starts after the launch reads as nothing out, and is delivered" do
      [_call, result] = launched("ae96c5149391564f6")

      refute Transcript.subagents_in_flight?(jsonl([result, said("Waiting on the reviewer.")]))
    end

    test "nothing readable at all means nothing is out — the safe direction is to deliver" do
      refute Transcript.subagents_in_flight?("")
      refute Transcript.subagents_in_flight?("{not json\n{also not")
    end
  end

  describe "tail/2" do
    setup do
      path = Path.join(System.tmp_dir!(), "whiska-tail-#{System.unique_integer([:positive])}")
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
      path = Path.join(System.tmp_dir!(), "whiska-start-#{System.unique_integer([:positive])}")
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
end
