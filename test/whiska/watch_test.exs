defmodule Whiska.WatchTest do
  @moduledoc """
  The board: one row per mouse, as this repo's Claude Code statusline draws it
  (ADR-0051).

  Rows are pure — mouse records, questions and herdr's pane list in, lines out —
  so nothing here needs a house, an owl or a transcript on disk.
  """
  use ExUnit.Case, async: true

  alias Whiska.Schema.Mouse
  alias Whiska.Schema.Question
  alias Whiska.Watch

  @now ~U[2026-09-29 12:00:00Z]

  defp mouse(branch, opts \\ []) do
    %Mouse{
      mouse_id: "m-#{branch}",
      branch: branch,
      path: "/repo/worktrees/#{branch}",
      mode: "build",
      created_at: @now,
      died_at: Keyword.get(opts, :died_at)
    }
  end

  defp pane(branch, status) do
    %{
      pane_id: "w1:p#{branch}",
      cwd: "/repo/worktrees/#{branch}",
      agent: "claude",
      agent_status: status
    }
  end

  defp question(id, branch, opts \\ []) do
    %Question{
      id: id,
      mouse_id: "m-#{branch}",
      status: Keyword.get(opts, :status, "sent"),
      kind: Keyword.get(opts, :kind, "needs-decision"),
      text: Keyword.get(opts, :text, "Body.\n\nwhich db?\n\u2063\u2063"),
      asked_at: @now
    }
  end

  defp board(mice, opts \\ []) do
    Watch.board(mice,
      questions: Keyword.get(opts, :questions, []),
      panes: Keyword.get(opts, :panes, {:ok, Keyword.get(opts, :bare_panes, [])}),
      action: Keyword.get(opts, :action, fn _mouse -> nil end)
    )
  end

  describe "board/2" do
    test "a working mouse shows its last action" do
      rows =
        board([mouse("feat-a")],
          bare_panes: [pane("feat-a", "working")],
          action: fn _ -> {:tool, "Edit lib/auth.ex"} end
        ).rows

      assert [%{branch: "feat-a", status: "working", detail: "Edit lib/auth.ex"}] = rows
    end

    test "an idle mouse shows the last thing it said, in quotes" do
      rows =
        board([mouse("feat-a")],
          bare_panes: [pane("feat-a", "idle")],
          action: fn _ -> {:said, "31 tests pass."} end
        ).rows

      assert [%{status: "idle", detail: ~s("31 tests pass.")}] = rows
    end

    test "a question on the person beats whatever the mouse was doing" do
      rows =
        board([mouse("feat-a")],
          questions: [question(52, "feat-a")],
          bare_panes: [pane("feat-a", "idle")],
          action: fn _ -> {:tool, "Edit lib/auth.ex"} end
        ).rows

      assert [%{detail: ~s(waiting on you · #52 · "which db?")}] = rows
    end

    test "a question with no pointer still names itself" do
      rows =
        board([mouse("feat-a")],
          questions: [question(52, "feat-a", text: "All done.\n\u2063\u2063\u2063")],
          bare_panes: [pane("feat-a", "idle")]
        ).rows

      assert [%{detail: "waiting on you · #52"}] = rows
    end

    test "a question's pointer is cut to a row's width" do
      rows =
        board([mouse("feat-a")],
          questions: [
            question(52, "feat-a", text: String.duplicate("long ", 60) <> "\n\u2063\u2063")
          ],
          bare_panes: [pane("feat-a", "idle")]
        ).rows

      assert [%{detail: detail}] = rows
      assert String.length(detail) <= 90
      refute detail =~ "\n"
    end

    test "an escape sequence in a pointer never reaches the terminal" do
      rows =
        board([mouse("feat-a")],
          questions: [question(52, "feat-a", text: "body\n\e]0;PWNED\a pick one\n\u2063\u2063")],
          bare_panes: [pane("feat-a", "idle")]
        ).rows

      assert [%{detail: detail}] = rows
      refute detail =~ "\e"
    end

    test "herdr's done is a mouse ready for input, and reads as idle" do
      rows = board([mouse("feat-a")], bare_panes: [pane("feat-a", "done")]).rows

      assert [%{status: "idle"}] = rows
    end

    test "an agent herdr cannot classify is not called idle" do
      rows = board([mouse("feat-a")], bare_panes: [pane("feat-a", "unknown")]).rows

      assert [%{status: "?"}] = rows
    end

    test "a mouse with no pane of its own is shown, not hidden" do
      assert [%{branch: "feat-a", status: "no pane"}] = board([mouse("feat-a")]).rows
    end

    test "herdr unreachable leaves every status unknown rather than guessed" do
      rows = board([mouse("feat-a")], panes: {:error, :closed}).rows

      assert [%{status: "?"}] = rows
    end

    test "waiting rows come first, then working, then the rest" do
      mice = [mouse("feat-idle"), mouse("feat-work"), mouse("feat-ask")]

      rows =
        board(mice,
          questions: [question(52, "feat-ask")],
          bare_panes: [
            pane("feat-idle", "idle"),
            pane("feat-work", "working"),
            pane("feat-ask", "idle")
          ]
        ).rows

      assert ["feat-ask", "feat-work", "feat-idle"] = Enum.map(rows, & &1.branch)
    end

    test "past five rows the rest become a count" do
      mice = Enum.map(1..8, &mouse("feat-#{&1}"))
      panes = Enum.map(1..8, &pane("feat-#{&1}", "working"))

      board = board(mice, bare_panes: panes)

      assert length(board.rows) == 5
      assert board.more == 3
    end

    test "the cap never drops a mouse that is waiting on the person" do
      mice = Enum.map(1..8, &mouse("feat-#{&1}"))
      panes = Enum.map(1..8, &pane("feat-#{&1}", "working"))

      board = board(mice, bare_panes: panes, questions: [question(52, "feat-8")])

      assert "feat-8" in Enum.map(board.rows, & &1.branch)
      assert length(board.rows) == 5
    end

    test "the cap gives way rather than hide a question, however many are waiting" do
      mice = Enum.map(1..7, &mouse("feat-#{&1}"))
      panes = Enum.map(1..7, &pane("feat-#{&1}", "working"))
      questions = Enum.map(1..7, &question(&1, "feat-#{&1}"))

      board = board(mice, bare_panes: panes, questions: questions)

      assert length(board.rows) == 7
      assert board.more == 0
      assert board.waiting == 0
    end

    test "a dead mouse is not a row, and its orphaned questions are counted" do
      mice = [mouse("feat-gone", died_at: @now)]

      board =
        board(mice,
          questions: [
            question(7, "feat-gone", status: "orphaned"),
            question(9, "feat-gone", status: "orphaned")
          ]
        )

      assert board.rows == []
      assert board.waiting == 2
    end

    test "a dead mouse with nothing waiting leaves no trace" do
      assert board([mouse("feat-gone", died_at: @now)]) == %{rows: [], more: 0, waiting: 0}
    end

    test "a dead mouse takes no room from the live ones" do
      mice = [mouse("feat-gone", died_at: @now), mouse("feat-a")]

      board =
        board(mice,
          questions: [question(51, "feat-gone", status: "orphaned")],
          bare_panes: [pane("feat-a", "working")]
        )

      assert [%{branch: "feat-a"}] = board.rows
      assert board.waiting == 1
    end

    test "a question whose mouse has no row is counted underneath" do
      board = board([], questions: [question(52, "feat-vanished")])

      assert board.rows == []
      assert board.waiting == 1
    end

    test "a question shown on a row is not counted twice" do
      board =
        board([mouse("feat-a")],
          questions: [question(52, "feat-a")],
          bare_panes: [pane("feat-a", "idle")]
        )

      assert board.waiting == 0
    end
  end

  # Where a row's detail starts, which the ticker must never move.
  defp detail_column(line) do
    [head, _detail] = String.split(line, ~r/(Edit x\.ex|waiting on you|#51 orphaned)/, parts: 2)
    String.length(head)
  end

  describe "render/2" do
    test "is one line per mouse, columns lined up" do
      board =
        board([mouse("feat-a"), mouse("feat-longer-name")],
          bare_panes: [pane("feat-a", "working"), pane("feat-longer-name", "idle")],
          action: fn m -> if m.branch == "feat-a", do: {:tool, "Edit x.ex"}, else: nil end
        )

      assert Watch.render(board) ==
               """
               🐭 feat-a            working  Edit x.ex
               🐭 feat-longer-name  idle
               """
               |> String.trim_trailing()
    end

    test "an escape sequence in a branch name never reaches the terminal" do
      board =
        board([mouse("feat/a\e[2Kfake")],
          bare_panes: [pane("feat/a\e[2Kfake", "idle")]
        )

      rendered = Watch.render(board)

      refute rendered =~ "\e"
      assert rendered =~ "feat/a"
    end

    test "a board printed once, with no frame behind it, has no ticker at all" do
      board =
        board([mouse("feat-a")],
          bare_panes: [pane("feat-a", "working")],
          action: fn _mouse -> {:tool, "Edit x.ex"} end
        )

      assert Watch.render(board) == "🐭 feat-a  working  Edit x.ex"
    end

    test "the ticker's column holds its place when the last working mouse stops" do
      # `blocked` is as wide a word as `working`, so any difference between the
      # two is the ticker's column and not the status one.
      column =
        fn status ->
          board([mouse("feat-a")],
            bare_panes: [pane("feat-a", status)],
            action: fn _mouse -> {:tool, "Edit x.ex"} end
          )
          |> Watch.render(frame: 0)
          |> detail_column()
        end

      assert column.("working") == column.("blocked")
    end

    test "the columns line up across a working and a waiting row" do
      board =
        board([mouse("feat-a"), mouse("feat-b")],
          questions: [question(52, "feat-b")],
          bare_panes: [pane("feat-a", "working"), pane("feat-b", "working")],
          action: fn _mouse -> {:tool, "Edit x.ex"} end
        )

      columns =
        board
        |> Watch.render(frame: 1)
        |> String.split("\n")
        |> Enum.map(&detail_column/1)

      assert [column, column] = columns
    end

    test "a working row's ticker advances a frame at a time, and wraps" do
      board = board([mouse("feat-a")], bare_panes: [pane("feat-a", "working")])

      assert Watch.render(board, frame: 0) == "🐭 feat-a  working  ·"
      assert Watch.render(board, frame: 1) == "🐭 feat-a  working  ··"
      assert Watch.render(board, frame: 2) == "🐭 feat-a  working  ···"
      assert Watch.render(board, frame: 3) == "🐭 feat-a  working  ·"
    end

    test "the ticker never moves the detail column as it grows" do
      board =
        board([mouse("feat-a")],
          bare_panes: [pane("feat-a", "working")],
          action: fn _mouse -> {:tool, "Edit x.ex"} end
        )

      columns =
        Enum.map(0..2, fn frame ->
          [line] = String.split(Watch.render(board, frame: frame), "\n")
          line |> String.split("Edit x.ex") |> hd() |> String.length()
        end)

      assert [same, same, same] = columns
    end

    test "an idle mouse's row is still" do
      board = board([mouse("feat-a")], bare_panes: [pane("feat-a", "idle")])

      for frame <- 0..3, do: refute(Watch.render(board, frame: frame) =~ "·")
    end

    test "a mouse blocked, off its pane or behind an unreachable herdr is still" do
      for {panes, status} <- [
            {{:ok, [pane("feat-a", "blocked")]}, "blocked"},
            {{:ok, []}, "no pane"},
            {:no_socket, "?"}
          ] do
        board = board([mouse("feat-a")], panes: panes)

        assert Watch.render(board, frame: 1) == "🐭 feat-a  #{status}"
      end
    end

    test "a row waiting on the person is still, whatever herdr says it is doing" do
      board =
        board([mouse("feat-a")],
          questions: [question(52, "feat-a")],
          bare_panes: [pane("feat-a", "working")]
        )

      refute Watch.render(board, frame: 1) =~ "··"
      assert Watch.render(board, frame: 1) =~ "waiting on you"
    end

    test "a very long branch is cut rather than pushing the columns apart" do
      long = String.duplicate("a", 40)
      board = board([mouse(long)], bare_panes: [pane(long, "working")])

      assert [line] = String.split(Watch.render(board), "\n")
      assert line =~ "…"
      assert String.length(line) < 50
    end

    test "the overflow count is its own line" do
      mice = Enum.map(1..8, &mouse("feat-#{&1}"))
      panes = Enum.map(1..8, &pane("feat-#{&1}", "working"))

      assert Watch.render(board(mice, bare_panes: panes)) =~ "🐭 +3 more"
    end

    test "what no row covers is counted at the bottom" do
      assert Watch.render(board([], questions: [question(52, "feat-vanished")])) ==
               "🐱 1 waiting"
    end

    test "a quiet repo draws nothing at all" do
      assert Watch.render(board([])) == ""
    end

    test "a dead mouse draws nothing but the count of what it left behind" do
      board =
        board([mouse("feat-gone", died_at: @now)],
          questions: [question(51, "feat-gone", status: "orphaned")]
        )

      assert Watch.render(board) == "🐱 1 waiting"
    end
  end
end
