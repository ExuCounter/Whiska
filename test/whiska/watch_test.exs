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
  alias Whiska.Watch.Ink

  @now ~U[2026-09-29 12:00:00Z]

  defp mouse(branch, opts \\ []) do
    %Mouse{
      mouse_id: "m-#{branch}",
      branch: branch,
      path: "/repo/worktrees/#{branch}",
      mode: "build",
      created_at: Keyword.get(opts, :created_at, @now),
      died_at: Keyword.get(opts, :died_at)
    }
  end

  defp pane(branch, status, opts \\ []) do
    %{
      pane_id: "w1:p#{branch}",
      cwd: "/repo/worktrees/#{branch}",
      agent: "claude",
      agent_status: status,
      title: Keyword.get(opts, :title)
    }
  end

  defp question(id, branch, opts \\ []) do
    %Question{
      id: id,
      mouse_id: "m-#{branch}",
      mouse: Keyword.get(opts, :mouse, mouse(branch)),
      status: Keyword.get(opts, :status, "sent"),
      kind: Keyword.get(opts, :kind, "needs-decision"),
      text: Keyword.get(opts, :text, "Body.\n\nwhich db?\n\u2063\u2063"),
      asked_at: @now
    }
  end

  defp board(mice, opts \\ []) do
    Watch.board(mice,
      now: Keyword.get(opts, :now, @now),
      questions: Keyword.get(opts, :questions, []),
      panes: Keyword.get(opts, :panes, {:ok, Keyword.get(opts, :bare_panes, [])}),
      activity: activity(opts),
      held: Keyword.get(opts, :held),
      picked_up: Keyword.get(opts, :picked_up, %{})
    )
  end

  # The board asks one question of a mouse's transcript: what it is doing, and
  # how long since it did anything. A test pins either half.
  defp activity(opts) do
    action = Keyword.get(opts, :action, fn _mouse -> nil end)
    silent_for = Keyword.get(opts, :silent_for, 0)

    fn mouse -> %{action: action.(mouse), silent_for: silent_for} end
  end

  describe "a branch the owl picked up (ADR-0067)" do
    test "says so, and how long ago, while the turn it started is still running" do
      picked_up = %{"m-feat-a" => DateTime.add(@now, -180, :second)}

      assert [%{detail: "picked up 3m ago"}] =
               board([mouse("feat-a")],
                 panes: {:ok, [pane("feat-a", "working", title: "Order builder")]},
                 picked_up: picked_up
               ).rows
    end

    test "gives way to a question waiting on the person" do
      picked_up = %{"m-feat-a" => DateTime.add(@now, -180, :second)}

      assert [%{detail: detail}] =
               board([mouse("feat-a")],
                 questions: [question(7, "feat-a")],
                 panes: {:ok, [pane("feat-a", "working")]},
                 picked_up: picked_up
               ).rows

      assert detail =~ "waiting on you"
    end

    test "is gone from the row once the turn it started has ended" do
      assert [%{detail: "Order builder"}] =
               board([mouse("feat-a")],
                 panes: {:ok, [pane("feat-a", "idle", title: "Order builder")]},
                 picked_up: %{}
               ).rows
    end
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

    test "a working mouse shows its topic, not the tool call underneath it" do
      rows =
        board([mouse("feat-a")],
          bare_panes: [pane("feat-a", "working", title: "Order builder for distributors")],
          action: fn _ -> {:tool, "Bash python3 - <<'PY'"} end
        ).rows

      assert [%{detail: "Order builder for distributors"}] = rows
    end

    test "a blocked mouse shows what it is stuck on, not what it set out to do" do
      rows =
        board([mouse("feat-a")],
          bare_panes: [pane("feat-a", "blocked", title: "Order builder for distributors")],
          action: fn _ -> {:tool, "Bash mix test"} end
        ).rows

      assert [%{detail: "Bash mix test"}] = rows
    end

    test "a working mouse silent for two minutes shows what it is stuck in" do
      rows =
        board([mouse("feat-a")],
          bare_panes: [pane("feat-a", "working", title: "Order builder for distributors")],
          action: fn _ -> {:tool, "Bash mix test"} end,
          silent_for: 120
        ).rows

      assert [%{detail: "Bash mix test"}] = rows
    end

    test "a working mouse between tool calls keeps showing its topic" do
      rows =
        board([mouse("feat-a")],
          bare_panes: [pane("feat-a", "working", title: "Order builder for distributors")],
          action: fn _ -> {:tool, "Bash mix test"} end,
          silent_for: 119
        ).rows

      assert [%{detail: "Order builder for distributors"}] = rows
    end

    # An idle mouse is not stuck, it is waiting to be told what to do next, so
    # silence on its row says nothing and its topic stands.
    test "an idle mouse's long silence is not being stuck" do
      rows =
        board([mouse("feat-a")],
          bare_panes: [pane("feat-a", "idle", title: "Order builder for distributors")],
          action: fn _ -> {:tool, "Bash mix test"} end,
          silent_for: 86_400
        ).rows

      assert [%{detail: "Order builder for distributors"}] = rows
    end

    test "a blocked mouse whose transcript says nothing still shows its topic" do
      rows =
        board([mouse("feat-a")],
          bare_panes: [pane("feat-a", "blocked", title: "Order builder for distributors")]
        ).rows

      assert [%{detail: "Order builder for distributors"}] = rows
    end

    test "no topic and no transcript leaves the column empty" do
      rows = board([mouse("feat-a")], bare_panes: [pane("feat-a", "working")]).rows

      assert [%{detail: ""}] = rows
    end

    test "the agent glyph herdr leaves on the front of a title is not the topic" do
      rows =
        board([mouse("feat-a")],
          bare_panes: [pane("feat-a", "working", title: "\u2733 Order builder")]
        ).rows

      assert [%{detail: "Order builder"}] = rows
    end

    test "a title that is nothing but the agent glyph is not a topic" do
      rows =
        board([mouse("feat-a")],
          bare_panes: [pane("feat-a", "blocked", title: "\u2733 \u2733")],
          action: fn _ -> {:tool, "Bash mix test"} end
        ).rows

      assert [%{detail: "Bash mix test"}] = rows
    end

    test "a glyph with no space after it is still not part of the topic" do
      rows =
        board([mouse("feat-a")],
          bare_panes: [pane("feat-a", "working", title: "\u2733Order builder")]
        ).rows

      assert [%{detail: "Order builder"}] = rows
    end

    test "a working mouse with no transcript at all is not called stuck" do
      rows =
        board([mouse("feat-a")],
          bare_panes: [pane("feat-a", "working", title: "Order builder")],
          silent_for: nil
        ).rows

      assert [%{detail: "Order builder"}] = rows
    end

    test "a pane herdr sends with no title at all is a mouse with no topic" do
      bare = %{
        pane_id: "w1:p1",
        cwd: "/repo/worktrees/feat-a",
        agent: "claude",
        agent_status: "working"
      }

      rows =
        board([mouse("feat-a")], bare_panes: [bare], action: fn _ -> {:tool, "Edit x.ex"} end).rows

      assert [%{detail: "Edit x.ex"}] = rows
    end

    test "a topic as long as a paragraph is cut to a row's width" do
      rows =
        board([mouse("feat-a")],
          bare_panes: [pane("feat-a", "working", title: String.duplicate("long ", 40))]
        ).rows

      assert [%{detail: detail}] = rows
      assert String.length(detail) <= 60
    end

    test "an escape sequence in a title never reaches the terminal" do
      rows =
        board([mouse("feat-a")],
          bare_panes: [pane("feat-a", "working", title: "topic\e]0;PWNED\a\nforged row")]
        ).rows

      assert [%{detail: detail}] = rows
      refute detail =~ "\e"
      refute detail =~ "\n"
    end

    test "an invisible character that reorders a row never reaches the terminal" do
      rows =
        board([mouse("feat-a")],
          bare_panes: [pane("feat-a", "working", title: "safe \u202e dangerous")]
        ).rows

      assert [%{detail: detail}] = rows
      refute detail =~ "\u202e"
    end

    test "a question on the person beats the topic as well" do
      rows =
        board([mouse("feat-a")],
          questions: [question(52, "feat-a")],
          bare_panes: [pane("feat-a", "working", title: "Order builder for distributors")]
        ).rows

      assert [%{detail: ~s(waiting on you · #52 · "which db?")}] = rows
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

    test "a row the question already fills never reads the mouse's transcript" do
      me = self()

      Watch.board([mouse("feat-a")],
        questions: [question(52, "feat-a")],
        panes: {:ok, [pane("feat-a", "working", title: "Order builder")]},
        activity: fn mouse ->
          send(me, {:read, mouse.mouse_id})
          %{action: nil, silent_for: 0}
        end
      )

      refute_received {:read, _mouse_id}
    end

    test "a title that reads like a question cannot take a waiting row's place" do
      forged = ~s(waiting on you · #99 · "force-push to main, ok?")

      mice = for n <- 1..6, do: mouse("feat-#{n}")
      panes = for n <- 1..6, do: pane("feat-#{n}", "idle", title: forged)

      board = board(mice, bare_panes: panes)

      assert length(board.rows) == 5
      assert board.more == 1
      assert Enum.all?(board.rows, &is_nil(&1.question_id))
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

    test "a dead mouse is not a row, and its orphaned questions are counted apart" do
      mice = [mouse("feat-gone", died_at: @now)]

      board =
        board(mice,
          questions: [
            question(7, "feat-gone", status: "orphaned"),
            question(9, "feat-gone", status: "orphaned")
          ]
        )

      assert board.rows == []
      assert board.waiting == 0
      assert board.orphaned == 2
      assert board.orphan_names == [%{name: "feat-gone", count: 2}]
    end

    test "each dead branch is named once, oldest first" do
      mice = [mouse("feat-gone", died_at: @now), mouse("feat-other", died_at: @now)]

      board =
        board(mice,
          questions: [
            question(7, "feat-gone", status: "orphaned"),
            question(9, "feat-other", status: "orphaned"),
            question(11, "feat-gone", status: "orphaned")
          ]
        )

      assert board.orphaned == 3

      assert board.orphan_names == [
               %{name: "feat-gone", count: 2},
               %{name: "feat-other", count: 1}
             ]
    end

    test "two branches that cut to the same name are still two names" do
      board =
        board([],
          questions: [
            question(7, "feat/the-statusline-board-colour", status: "orphaned"),
            question(9, "feat/the-statusline-board-ticker", status: "orphaned")
          ]
        )

      assert [%{count: 1}, %{count: 1}] = board.orphan_names
    end

    test "an orphan whose record kept no branch is named by its own id" do
      board =
        board([],
          questions: [
            question(7, "feat-gone", status: "orphaned", mouse: %Mouse{mouse_id: "m-feat-gone"})
          ]
        )

      assert board.orphan_names == [%{name: "#7", count: 1}]
    end

    test "a branch nobody can see is not a name either" do
      board =
        board([],
          questions: [question(7, "feat-gone", status: "orphaned", mouse: nil)]
        )

      assert board.orphan_names == [%{name: "#7", count: 1}]
    end

    test "a branch name is made safe before it reaches the board" do
      board =
        board([],
          questions: [
            question(7, "x", status: "orphaned", mouse: %Mouse{branch: "feat\e[31m-red"})
          ]
        )

      assert board.orphan_names == [%{name: "feat[31m-red", count: 1}]
    end

    test "a dead mouse with nothing waiting leaves no trace" do
      assert board([mouse("feat-gone", died_at: @now)]) ==
               %{rows: [], more: 0, waiting: 0, orphaned: 0, orphan_names: [], held: nil}
    end

    test "a dead mouse takes no room from the live ones" do
      mice = [mouse("feat-gone", died_at: @now), mouse("feat-a")]

      board =
        board(mice,
          questions: [question(51, "feat-gone", status: "orphaned")],
          bare_panes: [pane("feat-a", "working")]
        )

      assert [%{branch: "feat-a"}] = board.rows
      assert board.waiting == 0
      assert board.orphaned == 1
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

    test "a row says how long its mouse has been going" do
      mice = [mouse("feat-a", created_at: DateTime.add(@now, -6 * 60))]

      rows = board(mice, bare_panes: [pane("feat-a", "working")]).rows

      assert [%{elapsed: "6m"}] = rows
    end

    test "elapsed is spelled the way `whiska mice` spells it" do
      for seconds <- [45, 6 * 60, 5580, 200_000] do
        mice = [mouse("feat-a", created_at: DateTime.add(@now, -seconds))]

        assert [%{elapsed: elapsed}] = board(mice).rows
        assert elapsed == Whiska.Mice.format_uptime(seconds)
      end
    end

    test "an uncovered question and an orphan are counted on their own lines" do
      board =
        board([mouse("feat-gone", died_at: @now)],
          questions: [
            question(52, "feat-vanished"),
            question(51, "feat-gone", status: "orphaned")
          ]
        )

      assert board.waiting == 1
      assert board.orphaned == 1
    end
  end

  # The board carries ANSI codes now (addendum of 2026-10-02). Read back plain
  # unless the test is about the colour itself.
  defp render(board, opts \\ []), do: Ink.plain(Watch.render(board, opts))

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

      assert render(board) ==
               """
               🐭 feat-a            working  0s  Edit x.ex
               🐭 feat-longer-name  idle     0s
               """
               |> String.trim_trailing()
    end

    test "an escape sequence in a branch name never reaches the terminal" do
      board =
        board([mouse("feat/a\e[2Kfake")],
          bare_panes: [pane("feat/a\e[2Kfake", "idle")]
        )

      rendered = render(board)

      refute rendered =~ "\e"
      assert rendered =~ "feat/a"
    end

    test "a board printed once, with no frame behind it, has no ticker at all" do
      board =
        board([mouse("feat-a")],
          bare_panes: [pane("feat-a", "working")],
          action: fn _mouse -> {:tool, "Edit x.ex"} end
        )

      assert render(board) == "🐭 feat-a  working  0s  Edit x.ex"
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
          |> render(frame: 0)
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
        |> render(frame: 1)
        |> String.split("\n")
        |> Enum.map(&detail_column/1)

      assert [column, column] = columns
    end

    test "a working row's ticker advances a frame at a time, and wraps" do
      board = board([mouse("feat-a")], bare_panes: [pane("feat-a", "working")])

      assert render(board, frame: 0) == "🐭 feat-a  working  0s  ·"
      assert render(board, frame: 1) == "🐭 feat-a  working  0s  ··"
      assert render(board, frame: 2) == "🐭 feat-a  working  0s  ···"
      assert render(board, frame: 3) == "🐭 feat-a  working  0s  ·"
    end

    test "the ticker never moves the detail column as it grows" do
      board =
        board([mouse("feat-a")],
          bare_panes: [pane("feat-a", "working")],
          action: fn _mouse -> {:tool, "Edit x.ex"} end
        )

      columns =
        Enum.map(0..2, fn frame ->
          [line] = String.split(render(board, frame: frame), "\n")
          line |> String.split("Edit x.ex") |> hd() |> String.length()
        end)

      assert [same, same, same] = columns
    end

    test "an idle mouse's row is still" do
      board = board([mouse("feat-a")], bare_panes: [pane("feat-a", "idle")])

      for frame <- 0..3, do: refute(render(board, frame: frame) =~ "·")
    end

    test "a mouse blocked, off its pane or behind an unreachable herdr is still" do
      for {panes, status} <- [
            {{:ok, [pane("feat-a", "blocked")]}, "blocked"},
            {{:ok, []}, "no pane"},
            {:no_socket, "?"}
          ] do
        board = board([mouse("feat-a")], panes: panes)

        assert render(board, frame: 1) == "🐭 feat-a  #{status}  0s"
      end
    end

    test "a row waiting on the person is still, whatever herdr says it is doing" do
      board =
        board([mouse("feat-a")],
          questions: [question(52, "feat-a")],
          bare_panes: [pane("feat-a", "working")]
        )

      refute render(board, frame: 1) =~ "··"
      assert render(board, frame: 1) =~ "waiting on you"
    end

    test "a very long branch is cut rather than pushing the columns apart" do
      long = String.duplicate("a", 40)
      board = board([mouse(long)], bare_panes: [pane(long, "working")])

      assert [line] = String.split(render(board), "\n")
      assert line =~ "…"
      assert String.length(line) < 50
    end

    test "the overflow count is its own line" do
      mice = Enum.map(1..8, &mouse("feat-#{&1}"))
      panes = Enum.map(1..8, &pane("feat-#{&1}", "working"))

      assert render(board(mice, bare_panes: panes)) =~ "🐭 +3 more"
    end

    test "what no row covers is counted at the bottom" do
      assert render(board([], questions: [question(52, "feat-vanished")])) ==
               "🐱 1 waiting"
    end

    test "how long each mouse has been going is its own column" do
      board =
        board([mouse("feat-a", created_at: DateTime.add(@now, -5580))],
          bare_panes: [pane("feat-a", "working")],
          action: fn _mouse -> {:tool, "Edit x.ex"} end
        )

      assert render(board) == "🐭 feat-a  working  1h 33m  Edit x.ex"
    end

    test "elapsed never moves the detail column between rows" do
      board =
        board(
          [
            mouse("feat-a", created_at: DateTime.add(@now, -5580)),
            mouse("feat-b", created_at: @now)
          ],
          bare_panes: [pane("feat-a", "working"), pane("feat-b", "working")],
          action: fn _mouse -> {:tool, "Edit x.ex"} end
        )

      assert [column, column] =
               board |> render(frame: 1) |> String.split("\n") |> Enum.map(&detail_column/1)
    end

    test "the branch is cyan, so the person's own theme picks the shade" do
      board = board([mouse("feat-a")], bare_panes: [pane("feat-a", "working")])

      assert Watch.render(board) =~ "\e[36mfeat-a"
    end

    test "a question waiting on the person is the one thing in yellow" do
      board =
        board([mouse("feat-a")],
          questions: [question(52, "feat-a")],
          bare_panes: [pane("feat-a", "idle")]
        )

      assert Watch.render(board) =~ "\e[33mwaiting on you · #52"
    end

    test "a held queue rides the waiting line, and is yellow with it" do
      board = board([], questions: [question(52, "feat-vanished")], held: :typing)

      assert Watch.render(board) ==
               "\e[33m🐱 1 waiting · held: your prompt box isn't empty\e[39m"
    end

    test "the count of what no row carries is yellow too, and the orphans are not" do
      board =
        board([mouse("feat-gone", died_at: @now)],
          questions: [
            question(52, "feat-vanished"),
            question(51, "feat-gone", status: "orphaned")
          ]
        )

      assert Watch.render(board) ==
               "\e[33m🐱 1 waiting\e[39m\n\e[2m🐱 1 orphaned (feat-gone)\e[22m"
    end

    test "a row that has nothing waiting is never yellow" do
      board =
        board([mouse("feat-a")],
          bare_panes: [pane("feat-a", "working")],
          action: fn _mouse -> {:tool, "Edit x.ex"} end
        )

      refute Watch.render(board) =~ "\e[33m"
    end

    test "elapsed is dim, not loud" do
      board = board([mouse("feat-a")], bare_panes: [pane("feat-a", "working")])

      assert Watch.render(board) =~ "\e[2m0s\e[22m"
    end

    test "colour never carries meaning on its own" do
      board =
        board([mouse("feat-a")],
          questions: [question(52, "feat-a")],
          bare_panes: [pane("feat-a", "idle")]
        )

      plain = render(board)

      assert plain =~ "feat-a"
      assert plain =~ "waiting on you · #52"
      assert plain =~ "0s"
    end

    test "no code is a full reset, so a stale board's dim survives the row" do
      board =
        board([mouse("feat-a")],
          questions: [question(52, "feat-a")],
          bare_panes: [pane("feat-a", "idle")]
        )

      refute Watch.render(board, frame: 1) =~ "\e[0m"
    end

    test "colour does not count against a column's cap" do
      long = String.duplicate("a", 40)
      board = board([mouse(long)], bare_panes: [pane(long, "working")])

      assert [line] = String.split(render(board), "\n")
      assert String.length(line) < 50
    end

    test "a quiet repo draws nothing at all" do
      assert render(board([])) == ""
    end

    test "a dead mouse draws nothing but the count of what it left behind" do
      board =
        board([mouse("feat-gone", died_at: @now)],
          questions: [question(51, "feat-gone", status: "orphaned")]
        )

      assert render(board) == "🐱 1 orphaned (feat-gone)"
    end

    test "two orphans off one branch are counted beside its name" do
      board =
        board([mouse("feat-gone", died_at: @now)],
          questions: [
            question(51, "feat-gone", status: "orphaned"),
            question(53, "feat-gone", status: "orphaned")
          ]
        )

      assert render(board) == "🐱 2 orphaned (feat-gone ×2)"
    end

    test "more names than fit are summed into the rest, and the numbers add up" do
      branches = for n <- 1..5, do: "feat-a-long-branch-#{n}"

      questions =
        for {branch, id} <- Enum.with_index(branches, 51),
            do: question(id, branch, status: "orphaned")

      assert render(board([], questions: questions)) ==
               "🐱 5 orphaned (feat-a-long-branch-1, feat-a-long-branch-2, +3 more)"
    end

    test "the rest counts questions, not names, so the line still adds up" do
      questions =
        [
          question(51, "feat-a-long-branch-1", status: "orphaned"),
          question(52, "feat-a-long-branch-2", status: "orphaned")
        ] ++
          for id <- 53..56,
              do: question(id, "feat-a-long-branch-3", status: "orphaned")

      assert render(board([], questions: questions)) ==
               "🐱 6 orphaned (feat-a-long-branch-1, feat-a-long-branch-2, +4 more)"
    end

    test "a house full of orphans still fits the budget, and still adds up" do
      questions =
        for id <- 1..50, do: question(id, "branch-#{id}", status: "orphaned")

      line = render(board([], questions: questions))

      assert ["🐱 50 orphaned ", names] = String.split(line, "(", parts: 2)
      names = String.trim_trailing(names, ")")
      assert String.length(names) <= 60

      shown = String.split(names, ", ")
      {rest, named} = List.pop_at(shown, -1)
      assert [_ | _] = named
      assert rest =~ ~r/^\+\d+ more$/
      assert length(named) + String.to_integer(String.slice(rest, 1..-6//1)) == 50
    end

    test "one name too long to fit is still shown, cut to the branch column" do
      long = String.duplicate("a", 40)

      assert render(board([], questions: [question(51, long, status: "orphaned")])) ==
               "🐱 1 orphaned (#{String.duplicate("a", 23)}…)"
    end

    test "a held queue says so on the waiting line (ADR-0058)" do
      board = board([], questions: [question(52, "feat-vanished")], held: :typing)

      assert render(board) == "🐱 1 waiting · held: your prompt box isn\'t empty"
    end

    test "a queue held because the box is off the screen says so (ADR-0068)" do
      board = board([], questions: [question(52, "feat-vanished")], held: :no_box)

      assert render(board) == "🐱 1 waiting · held: your prompt box isn\'t on screen"
    end

    test "a topic row and a held queue are drawn together" do
      board =
        board([mouse("feat-a")],
          bare_panes: [pane("feat-a", "working", title: "Order builder for distributors")],
          questions: [question(52, "feat-vanished")],
          held: :typing
        )

      drawn = render(board)
      assert drawn =~ "Order builder for distributors"
      assert drawn =~ "🐱 1 waiting · held: your prompt box isn't empty"
    end

    test "a hold is still said when every question is on a row" do
      board =
        board([mouse("feat-a")],
          questions: [question(52, "feat-a", status: "open")],
          bare_panes: [pane("feat-a", "idle")],
          held: :mid_turn
        )

      assert render(board) =~ "🐱 held: this session is mid-turn"
    end

    test "a hold Whiska cannot name is still a hold" do
      board = board([], questions: [question(52, "feat-vanished")], held: :unreachable)

      assert render(board) == "🐱 1 waiting · held: your main session cannot be reached"
    end

    test "nothing held adds no words" do
      assert render(board([], questions: [question(52, "feat-vanished")])) ==
               "🐱 1 waiting"
    end

    test "waiting and orphaned are separate lines, waiting first" do
      board =
        board([mouse("feat-gone", died_at: @now)],
          questions: [
            question(52, "feat-vanished"),
            question(51, "feat-gone", status: "orphaned")
          ]
        )

      assert render(board) == "🐱 1 waiting\n🐱 1 orphaned (feat-gone)"
    end
  end
end
