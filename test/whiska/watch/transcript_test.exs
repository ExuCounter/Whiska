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
      tmp = Path.join(System.tmp_dir!(), "whiska-tr-#{System.unique_integer([:positive])}")
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
end
