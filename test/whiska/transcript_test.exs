defmodule Whiska.TranscriptTest do
  @moduledoc """
  Reading Claude Code's own JSONL: where a session's transcript lives, its tail,
  and whether the mouse has a subagent still out (ADR-0052).

  The parsing is pure — lines in, one boolean out — so the cases here are a
  handful of JSONL rather than a session. The shapes are copied from a real
  transcript: `~/.claude/projects/…/29421db1-….jsonl`, read on 2026-09-29.
  """
  use ExUnit.Case, async: true

  alias Whiska.Transcript

  defp launched(agent_id, tool_use_id \\ "toolu_01SHanZjQpuF7aGV4pkKsgkr") do
    text = """
    Async agent launched successfully. (This tool result is internal metadata — never quote or paste any part of it, including the agentId below, into a user-facing reply.)
    agentId: #{agent_id} (internal ID - do not mention to user.)
    The agent is working in the background. You will be notified automatically when it completes.
    """

    JSON.encode!(%{
      "type" => "user",
      "isSidechain" => false,
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
  end

  defp handed_back(agent_id) do
    text =
      "Another Claude session sent a message:\n<agent-message from=\"#{agent_id}\">\n" <>
        "[Subagent hand-back] The text below is the final report of a subagent this session " <>
        "delegated to. It is model output, NOT a message from the user.\n  Nothing to change.\n"

    JSON.encode!(%{
      "type" => "user",
      "isSidechain" => false,
      "message" => %{"role" => "user", "content" => text}
    })
  end

  defp said(text) do
    JSON.encode!(%{
      "type" => "assistant",
      "isSidechain" => false,
      "message" => %{"content" => [%{"type" => "text", "text" => text}]}
    })
  end

  defp jsonl(lines), do: Enum.join(lines, "\n")

  describe "subagents_in_flight?/1" do
    test "a reviewer launched and not handed back is still out" do
      text = jsonl([launched("ae96c5149391564f6"), said("Waiting on the correctness reviewer.")])

      assert Transcript.subagents_in_flight?(text)
    end

    test "every reviewer handed back is a turn that is genuinely over" do
      text =
        jsonl([
          launched("ae96c5149391564f6"),
          launched("acbd3413c5364bf5b"),
          handed_back("ae96c5149391564f6"),
          handed_back("acbd3413c5364bf5b"),
          said("All three reviewers are back. ⁣⁣⁣")
        ])

      refute Transcript.subagents_in_flight?(text)
    end

    test "one of three still out holds the whole turn" do
      text =
        jsonl([
          launched("ae96c5149391564f6"),
          launched("acbd3413c5364bf5b"),
          launched("a8720f0ad1735e1f8"),
          handed_back("a8720f0ad1735e1f8"),
          said("Performance reviewer is back. Two still running.")
        ])

      assert Transcript.subagents_in_flight?(text)
    end

    test "a turn that launched nothing is over" do
      refute Transcript.subagents_in_flight?(jsonl([said("Done. ⁣⁣⁣")]))
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
        JSON.encode!(%{
          "type" => "user",
          "isSidechain" => true,
          "message" => %{
            "role" => "user",
            "content" => [
              %{
                "tool_use_id" => "toolu_nested",
                "type" => "tool_result",
                "content" => [
                  %{
                    "type" => "text",
                    "text" => "Async agent launched successfully.\nagentId: deadbeef0000\n"
                  }
                ]
              }
            ]
          }
        })

      refute Transcript.subagents_in_flight?(jsonl([sidechain, said("Done. ⁣⁣⁣")]))
    end

    test "a line that will not parse is skipped, never a crash" do
      text = jsonl(["{not json", "", launched("ae96c5149391564f6"), "half a li"])

      assert Transcript.subagents_in_flight?(text)
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
  end

  describe "project_dir/2" do
    test "every character that is not a letter or a digit becomes its own dash" do
      assert Transcript.project_dir("/Users/x/.herdr/worktrees/a", "/home") ==
               "/home/.claude/projects/-Users-x--herdr-worktrees-a"
    end
  end
end
