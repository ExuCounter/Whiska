defmodule Whiska.SidebarTest do
  @moduledoc """
  The lines herdr's sidebar draws for a house: one under each mouse's
  workspace, one under the main checkout's
  (ADR-next-a-mouses-state-is-a-line-in-herdrs-sidebar).

  Pure — mouse records, questions and herdr's pane list in, through
  `Whiska.Watch.board/2`, and tokens out — so nothing here needs a house, an
  owl or a transcript on disk.
  """
  use ExUnit.Case, async: true

  alias Whiska.Delivery.Mode
  alias Whiska.Schema.Mouse
  alias Whiska.Schema.Question
  alias Whiska.Sidebar
  alias Whiska.Watch

  @now ~U[2026-09-29 12:00:00Z]

  defp mouse(branch, opts \\ []) do
    %Mouse{
      mouse_id: "m-#{branch}",
      branch: branch,
      path: "/repo/worktrees/#{branch}",
      mode: "build",
      created_at: Keyword.get(opts, :created_at, @now),
      died_at: Keyword.get(opts, :died_at),
      held_at: Keyword.get(opts, :held_at)
    }
  end

  defp pane(branch, status, opts \\ []) do
    %{
      pane_id: "w1:p#{branch}",
      workspace_id: "ws-#{branch}",
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
      asked_at: @now,
      sent_at: Keyword.get(opts, :sent_at)
    }
  end

  defp board(mice, opts) do
    Watch.board(mice,
      questions: Keyword.get(opts, :questions, []),
      panes: Keyword.get(opts, :panes, {:ok, Keyword.get(opts, :bare_panes, [])}),
      activity: activity(opts),
      held: Keyword.get(opts, :held),
      mode: Keyword.get(opts, :mode, Mode.none()),
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

  defp lines(mice, opts) do
    mice
    |> board(opts)
    |> Sidebar.mice(now: Keyword.get(opts, :now, @now), frame: Keyword.get(opts, :frame, 0))
  end

  # The one mouse's tokens, the way herdr would be handed them.
  defp tokens(mice, opts) do
    [%{tokens: tokens}] = lines(mice, opts)
    tokens
  end

  defp said(mice, opts \\ []), do: tokens(mice, opts)["whiska"]

  defp mode(attrs), do: Map.merge(Mode.none(), Map.new(attrs))

  describe "a question waiting on the person" do
    test "sent, it says so and for how long, with the question underneath" do
      sent_at = DateTime.add(@now, -14 * 60, :second)

      assert tokens([mouse("feat-a")],
               questions: [question(13, "feat-a", sent_at: sent_at)],
               bare_panes: [pane("feat-a", "idle")]
             ) == %{"whiska" => "🐭 #13 · waiting on you · 14m", "whiska_q" => "which db?"}
    end

    test "next to go and not sent yet, it is waiting on the person without an age" do
      assert tokens([mouse("feat-a")],
               questions: [question(12, "feat-a", status: "open")],
               bare_panes: [pane("feat-a", "idle")]
             ) == %{"whiska" => "🐭 #12 · waiting on you", "whiska_q" => "which db?"}
    end

    test "an age under a minute is still an age, and an hour is spelled like `whiska mice`" do
      for {ago, age} <- [{20, "<1m"}, {59 * 60 + 59, "59m"}, {5580, "1h 33m"}] do
        sent_at = DateTime.add(@now, -ago, :second)

        assert said([mouse("feat-a")],
                 questions: [question(13, "feat-a", sent_at: sent_at)],
                 bare_panes: [pane("feat-a", "idle")]
               ) == "🐭 #13 · waiting on you · #{age}"
      end
    end

    test "beats whatever the mouse is working on" do
      assert said([mouse("feat-a")],
               questions: [question(52, "feat-a", status: "open")],
               bare_panes: [pane("feat-a", "working", title: "Order builder")],
               action: fn _ -> {:tool, "Edit lib/auth.ex"} end
             ) == "🐭 #52 · waiting on you"
    end

    test "a line the question already fills never reads the mouse's transcript" do
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

    test "the question wraps onto two lines of 31, and the rest is cut" do
      text =
        "Body.\n\nShould the importer keep the legacy CSV columns or drop them " <>
          "for the new schema everyone agreed on?\n\u2063\u2063"

      tokens =
        tokens([mouse("feat-a")],
          questions: [question(12, "feat-a", status: "open", text: text)],
          bare_panes: [pane("feat-a", "idle")]
        )

      assert tokens["whiska_q"] == "Should the importer keep the"
      assert tokens["whiska_q2"] == "legacy CSV columns or drop the…"
      assert String.length(tokens["whiska_q2"]) <= 31
    end

    test "a word longer than a line is broken rather than lost" do
      text = "Body.\n\n#{String.duplicate("x", 40)} ok?\n\u2063\u2063"

      tokens =
        tokens([mouse("feat-a")],
          questions: [question(12, "feat-a", status: "open", text: text)],
          bare_panes: [pane("feat-a", "idle")]
        )

      assert tokens["whiska_q"] == String.duplicate("x", 31)
      assert tokens["whiska_q2"] == String.duplicate("x", 9) <> " ok?"
    end

    test "an escape sequence or a reordering character in the question never reaches herdr" do
      tokens =
        tokens([mouse("feat-a")],
          questions: [
            question(52, "feat-a", text: "body\n\e]0;PWNED\a pick \u202eone\n\u2063\u2063")
          ],
          bare_panes: [pane("feat-a", "idle")]
        )

      refute tokens["whiska_q"] =~ "\e"
      refute tokens["whiska_q"] =~ "\u202e"
    end

    test "an answer its mouse never took is the person's again" do
      assert tokens([mouse("feat-a")],
               questions: [question(7, "feat-a", status: "answered")],
               bare_panes: [pane("feat-a", "idle")],
               picked_up: %{"m-feat-a" => DateTime.add(@now, -180, :second)}
             ) == %{"whiska" => "🐭 #7 · answer not taken"}
    end
  end

  describe "a finished report" do
    test "holding the slot, it says finished, with its closing line underneath" do
      text = "Merged the importer.\n\nAll 31 tests pass.\n\u2063\u2063\u2063"

      assert tokens([mouse("feat-a")],
               questions: [question(14, "feat-a", kind: "done", text: text)],
               bare_panes: [pane("feat-a", "idle")]
             ) == %{"whiska" => "✅ #14 · finished", "whiska_q" => "All 31 tests pass."}

      [line] =
        lines([mouse("feat-a")],
          questions: [question(14, "feat-a", kind: "done", text: text)],
          bare_panes: [pane("feat-a", "idle")]
        )

      assert Sidebar.needs_you?(line)
    end

    test "behind another question, it says so and nothing more" do
      [_sent, %{tokens: tokens}] =
        lines([mouse("feat-a"), mouse("feat-b")],
          questions: [
            question(12, "feat-a"),
            question(15, "feat-b",
              status: "open",
              kind: "done",
              text: "Merged.\n\u2063\u2063\u2063"
            )
          ],
          bare_panes: [pane("feat-a", "idle"), pane("feat-b", "idle")]
        )

      assert tokens == %{"whiska" => "✅ finished · queued behind #12"}
    end
  end

  describe "a question waiting behind another" do
    test "names the one it is behind, and keeps its question" do
      [sent, queued] =
        lines([mouse("feat-a"), mouse("feat-b")],
          questions: [question(12, "feat-a"), question(16, "feat-b", status: "open")],
          bare_panes: [pane("feat-a", "idle"), pane("feat-b", "idle")]
        )

      assert sent.tokens["whiska"] =~ "🐭 #12 · waiting on you"
      assert queued.tokens == %{"whiska" => "⏳ queued behind #12", "whiska_q" => "which db?"}
    end
  end

  describe "what the person set aside (ADR-0079)" do
    test "a question behind away says so" do
      assert tokens([mouse("feat-a")],
               questions: [question(15, "feat-a", status: "open")],
               bare_panes: [pane("feat-a", "idle")],
               mode: mode(away?: true)
             ) == %{"whiska" => "💤 #15 · waits: away"}
    end

    test "a question behind a focus names the focused branch" do
      [%{tokens: tokens}, _focused] =
        lines([mouse("feat-a"), mouse("feat-b")],
          questions: [question(16, "feat-a", status: "open")],
          bare_panes: [pane("feat-a", "idle"), pane("feat-b", "working")],
          mode: mode(focus: "m-feat-b")
        )

      assert tokens == %{"whiska" => "🎯 #16 · waits: focus on feat-b"}
    end

    test "the focused branch is made safe before it reaches herdr" do
      focused = %{mouse("feat-b") | branch: "feat\e]0;x\a-b"}

      [%{tokens: tokens}, _focused] =
        lines([mouse("feat-a"), focused],
          questions: [question(16, "feat-a", status: "open")],
          bare_panes: [pane("feat-a", "idle"), pane("feat-b", "working")],
          mode: mode(focus: "m-feat-b")
        )

      refute tokens["whiska"] =~ "\e"
      refute tokens["whiska"] =~ "\a"
    end

    test "a held mouse says held, with its question's number" do
      held = mouse("feat-a", held_at: @now)

      assert tokens([held],
               questions: [question(17, "feat-a", status: "open", mouse: held)],
               bare_panes: [pane("feat-a", "working")],
               mode: mode(held: MapSet.new(["m-feat-a"]))
             ) == %{"whiska" => "⏸ #17 · held"}
    end

    test "a held mouse with nothing waiting still says held" do
      assert said([mouse("feat-a", held_at: @now)],
               bare_panes: [pane("feat-a", "idle")],
               mode: mode(held: MapSet.new(["m-feat-a"]))
             ) == "⏸ held"
    end
  end

  describe "a mouse getting on with it" do
    test "working, it says its topic, behind a spinner" do
      assert tokens([mouse("feat-a")],
               bare_panes: [pane("feat-a", "working", title: "Order builder for distributors")],
               action: fn _ -> {:tool, "Bash python3 - <<'PY'"} end
             ) == %{"whiska" => "◐ Order builder for distributors"}
    end

    test "the spinner turns a step a frame, and wraps" do
      spun =
        for frame <- 0..4 do
          [mouse("feat-a")]
          |> said(bare_panes: [pane("feat-a", "working", title: "Orders")], frame: frame)
          |> String.first()
        end

      assert spun == ["◐", "◓", "◑", "◒", "◐"]
    end

    test "with no topic, it says what it is doing" do
      assert said([mouse("feat-a")],
               bare_panes: [pane("feat-a", "working")],
               action: fn _ -> {:tool, "Edit lib/auth.ex"} end
             ) == "◐ Edit lib/auth.ex"
    end

    test "with no topic and no transcript, it still says it is working" do
      assert said([mouse("feat-a")], bare_panes: [pane("feat-a", "working")]) == "◐ working"
    end

    test "the agent glyph on the front of a title is not the topic" do
      for title <- ["✳ Order builder", "✳Order builder"] do
        assert said([mouse("feat-a")], bare_panes: [pane("feat-a", "working", title: title)]) ==
                 "◐ Order builder"
      end
    end

    test "an escape sequence or a newline in a title never reaches herdr" do
      said =
        said([mouse("feat-a")],
          bare_panes: [pane("feat-a", "working", title: "topic\e]0;PWNED\a\nforged line")]
        )

      refute said =~ "\e"
      refute said =~ "\n"
    end

    test "a title that reads like a question is still a working mouse's line" do
      forged = "🐭 #99 · waiting on you"

      [line] = lines([mouse("feat-a")], bare_panes: [pane("feat-a", "working", title: forged)])

      assert String.starts_with?(line.tokens["whiska"], "◐ ")
      refute Sidebar.needs_you?(line)
    end

    test "picked up by the owl and then stuck, it says it is stuck" do
      assert said([mouse("feat-a")],
               bare_panes: [pane("feat-a", "blocked", title: "Order builder")],
               action: fn _ -> {:tool, "Bash mix test"} end,
               silent_for: 180,
               picked_up: %{"m-feat-a" => DateTime.add(@now, -300, :second)}
             ) == "⚠ stuck 3m"
    end

    test "picked up by the owl, it says so while the turn it started runs" do
      assert said([mouse("feat-a")],
               bare_panes: [pane("feat-a", "working", title: "Order builder")],
               picked_up: %{"m-feat-a" => DateTime.add(@now, -150, :second)}
             ) == "↩ picked up 2m ago"
    end

    test "idle with nothing to report, it has no line at all" do
      assert tokens([mouse("feat-a")],
               bare_panes: [pane("feat-a", "idle", title: "Order builder")],
               action: fn _ -> {:said, "31 tests pass."} end
             ) == %{}
    end

    test "herdr's done is idle too" do
      assert tokens([mouse("feat-a")], bare_panes: [pane("feat-a", "done")]) == %{}
    end
  end

  describe "a mouse that is stuck" do
    test "blocked, it says how long it has been silent, and what it is stuck in" do
      assert tokens([mouse("feat-a")],
               bare_panes: [pane("feat-a", "blocked", title: "Order builder")],
               action: fn _ -> {:tool, "Bash mix test"} end,
               silent_for: 6 * 60
             ) == %{"whiska" => "⚠ stuck 6m", "whiska_q" => "Bash mix test"}
    end

    test "working and silent for two minutes is stuck; a second less is not" do
      opts = [
        bare_panes: [pane("feat-a", "working", title: "Order builder")],
        action: fn _ -> {:tool, "Bash mix test"} end
      ]

      assert said([mouse("feat-a")], [silent_for: 120] ++ opts) == "⚠ stuck 2m"
      assert said([mouse("feat-a")], [silent_for: 119] ++ opts) == "◐ Order builder"
    end

    test "blocked with a transcript that says nothing, its topic is what it is stuck in" do
      assert tokens([mouse("feat-a")],
               bare_panes: [pane("feat-a", "blocked", title: "Order builder")],
               silent_for: nil
             ) == %{"whiska" => "⚠ stuck", "whiska_q" => "Order builder"}
    end

    test "working with no transcript at all is not called stuck" do
      assert said([mouse("feat-a")],
               bare_panes: [pane("feat-a", "working", title: "Order builder")],
               silent_for: nil
             ) == "◐ Order builder"
    end
  end

  describe "a mouse herdr cannot account for" do
    test "with no pane of its own, it says so" do
      assert said([mouse("feat-a")]) == "✖ no pane"
    end

    test "with two agent panes in its worktree, it says so" do
      second = %{pane("feat-a", "idle") | pane_id: "w1:p9"}

      assert said([mouse("feat-a")], bare_panes: [pane("feat-a", "working"), second]) ==
               "⚠ many panes"
    end

    test "an agent herdr cannot classify, or herdr unreachable, is said, not guessed" do
      assert said([mouse("feat-a")], bare_panes: [pane("feat-a", "unknown")]) ==
               "? herdr can't say"

      assert said([mouse("feat-a")], panes: {:error, :closed}) == "? herdr can't say"
    end
  end

  describe "the order" do
    test "follows how much each mouse wants the person, and keeps ties as they came" do
      sent_at = DateTime.add(@now, -60, :second)
      done = "Done.\n\u2063\u2063\u2063"

      mice = [
        mouse("idle"),
        mouse("working"),
        mouse("no-pane"),
        mouse("picked"),
        mouse("held", held_at: @now),
        mouse("queued"),
        mouse("stuck"),
        mouse("finished-later"),
        mouse("idle-too"),
        mouse("sent")
      ]

      working = ~w(working picked held)

      order =
        mice
        |> lines(
          questions: [
            question(1, "sent", sent_at: sent_at),
            question(2, "queued", status: "open"),
            question(3, "finished-later", status: "open", kind: "done", text: done)
          ],
          bare_panes:
            for(
              b <- ~w(idle working picked held queued finished-later idle-too sent),
              do: pane(b, if(b in working, do: "working", else: "idle"))
            ) ++ [pane("stuck", "blocked")],
          picked_up: %{"m-picked" => @now},
          mode: mode(held: MapSet.new(["m-held"]))
        )
        |> Enum.map(& &1.branch)

      assert order ==
               ~w(sent stuck queued finished-later held picked working no-pane idle idle-too)
    end

    test "with nothing sent, every open question is next to go, ahead of a stuck mouse" do
      done = "Done.\n\u2063\u2063\u2063"

      order =
        [mouse("stuck"), mouse("next"), mouse("finished")]
        |> lines(
          questions: [
            question(3, "finished", status: "open", kind: "done", text: done),
            question(4, "next", status: "open")
          ],
          bare_panes: [pane("stuck", "blocked"), pane("next", "idle"), pane("finished", "idle")]
        )
        |> Enum.map(& &1.branch)

      # Nothing holds the slot, so neither waits behind the other: the question
      # is waiting on the person and the report is finished, both above stuck.
      assert order == ~w(next finished stuck)
    end

    test "the person is needed by a waiting or finished mouse, and by nobody else" do
      [sent, queued, finished, working] =
        lines([mouse("a"), mouse("b"), mouse("c"), mouse("d")],
          questions: [
            question(1, "a"),
            question(2, "b", status: "open", kind: "done", text: "Done.\n\u2063\u2063\u2063"),
            question(3, "c", status: "open")
          ],
          bare_panes: [
            pane("a", "idle"),
            pane("b", "idle"),
            pane("c", "idle"),
            pane("d", "working")
          ]
        )

      assert Sidebar.needs_you?(sent)
      assert finished.branch == "b"
      refute Sidebar.needs_you?(queued)
      refute Sidebar.needs_you?(working)
      # Two questions open and one sent: the finished report is behind the sent one.
      refute Sidebar.needs_you?(finished)
    end
  end

  describe "the main checkout's line" do
    defp house(board_opts, opts \\ []) do
      [] |> board(board_opts) |> Sidebar.house(Keyword.merge([main_pane?: true], opts))
    end

    test "is empty when nothing about the repo needs saying" do
      assert house([]) == %{}
    end

    test "says no main session is recorded, first, while anything runs or waits" do
      board = board([mouse("feat-a")], bare_panes: [pane("feat-a", "working")], held: :typing)

      assert Sidebar.house(board, main_pane?: false) == %{
               "whiska" => "✖ no main session: whiska start",
               "whiska_q" => "⏳ gated: you're typing"
             }
    end

    test "a repo with nothing running and nothing waiting needs no main session" do
      assert house([], main_pane?: false) == %{}
    end

    test "says why delivery is gated (ADR-0058)" do
      for {held, reason} <- [
            typing: "you're typing",
            no_box: "no prompt box",
            mid_turn: "main is mid-turn",
            unreachable: "main unreachable"
          ] do
        assert house(held: held) == %{"whiska" => "⏳ gated: #{reason}"}
      end
    end

    test "away gives way to nothing: the gate's reason is not said beside it" do
      assert house(held: :typing, mode: mode(away?: true)) == %{}
    end

    test "counts what waits with no line of its own to show it" do
      board =
        board([mouse("feat-a")],
          questions: [question(52, "feat-gone-record"), question(53, "feat-a")],
          bare_panes: [pane("feat-a", "idle")]
        )

      assert Sidebar.house(board, main_pane?: true, no_workspace: MapSet.new(["m-feat-a"])) ==
               %{"whiska" => "🐭 2 more: whiska questions"}

      assert Sidebar.house(board, main_pane?: true, no_workspace: MapSet.new()) ==
               %{"whiska" => "🐭 1 more: whiska questions"}
    end

    test "names the branches orphans came off, and the names add up" do
      questions =
        [
          question(51, "feat-gone", status: "orphaned"),
          question(53, "feat-gone", status: "orphaned")
        ] ++
          for(n <- 1..5, do: question(60 + n, "feat-a-long-branch-#{n}", status: "orphaned"))

      assert house(questions: questions) == %{
               "whiska" => "◌ 7 orphaned (feat-gone ×2, feat-a-long-branch-1, +4 more)"
             }
    end

    test "two branches that cut to the same name are still two names" do
      questions = [
        question(7, "feat/the-statusline-board-colour", status: "orphaned"),
        question(9, "feat/the-statusline-board-ticker", status: "orphaned")
      ]

      assert %{"whiska" => "◌ 2 orphaned (" <> names} = house(questions: questions)
      refute names =~ "×"
      assert [_, _] = String.split(names, ", ")
    end

    test "a branch name is made safe before it reaches herdr" do
      orphan = question(7, "x", status: "orphaned", mouse: %Mouse{branch: "feat\e[31m-red"})

      assert house(questions: [orphan]) == %{"whiska" => "◌ 1 orphaned (feat[31m-red)"}
    end

    test "an orphan whose record kept no branch is named by its own id" do
      orphan = question(7, "x", status: "orphaned", mouse: %Mouse{mouse_id: "m-x"})

      assert house(questions: [orphan]) == %{"whiska" => "◌ 1 orphaned (#7)"}
    end

    test "every line fits the sidebar, so the command at its end is never cut off" do
      board =
        board([mouse("feat-a")],
          questions: [question(52, "feat-vanished")],
          bare_panes: [pane("feat-a", "working")]
        )

      for held <- [:typing, :no_box, :mid_turn, :unreachable] do
        tokens =
          Sidebar.house(%{board | held: held},
            main_pane?: false,
            no_workspace: MapSet.new(["m-x"])
          )

        for {_key, line} <- tokens, do: assert(String.length(line) <= 31, line)
      end
    end

    test "says the three most urgent things, in order, and drops the rest" do
      tokens =
        house(
          [
            held: :mid_turn,
            questions: [question(52, "feat-vanished"), question(7, "x", status: "orphaned")]
          ],
          main_pane?: false
        )

      assert tokens == %{
               "whiska" => "✖ no main session: whiska start",
               "whiska_q" => "⏳ gated: main is mid-turn",
               "whiska_q2" => "🐭 1 more: whiska questions"
             }
    end
  end

  describe "place/3, which workspace a mouse's line goes under" do
    defp ws(id, path), do: %{workspace_id: id, number: 1, path: path, linked?: nil, tokens: %{}}

    test "the one open on its worktree, else the checkout-less one holding its agent pane" do
      board =
        board([mouse("feat-a"), mouse("feat-b")],
          bare_panes: [
            pane("feat-a", "working"),
            %{pane("feat-b", "working") | workspace_id: "w9"}
          ]
        )

      workspaces = [ws("w1", "/repo"), ws("w2", "/repo/worktrees/feat-a"), ws("w9", nil)]

      assert Sidebar.place(board, workspaces) == %{"m-feat-a" => "w2", "m-feat-b" => "w9"}
    end

    test "never a workspace open on another checkout, however its pane got there" do
      board =
        board([mouse("feat-a")],
          bare_panes: [%{pane("feat-a", "working") | workspace_id: "w1"}]
        )

      for other <- ["/repo", "/elsewhere/repo"] do
        assert Sidebar.place(board, [ws("w1", other)]) == %{}
      end
    end

    test "two mice sharing one workspace: the one that wants the person more has it" do
      board =
        board([mouse("feat-idle"), mouse("feat-ask")],
          questions: [question(12, "feat-ask", status: "open")],
          bare_panes: [
            %{pane("feat-idle", "working") | workspace_id: "w9"},
            %{pane("feat-ask", "idle") | workspace_id: "w9"}
          ]
        )

      assert Sidebar.place(board, [ws("w9", nil)]) == %{"m-feat-ask" => "w9"}
    end

    test "never the main checkout's workspace, which carries the repo's own line" do
      board =
        board([mouse("feat-a")], bare_panes: [%{pane("feat-a", "working") | workspace_id: "w9"}])

      assert Sidebar.place(board, [ws("w9", nil)], "w9") == %{}
    end
  end

  describe "render/2, what `whiska watch` prints" do
    test "is the main checkout's lines, then each mouse in order under its branch" do
      board =
        board([mouse("feat-idle"), mouse("feat-a")],
          questions: [question(12, "feat-a", status: "open")],
          bare_panes: [pane("feat-idle", "idle"), pane("feat-a", "idle")],
          held: :typing
        )

      printed =
        Sidebar.render(
          Sidebar.house(board, main_pane?: true),
          Sidebar.mice(board, now: @now, frame: 0)
        )

      assert printed ==
               """
               ⏳ gated: you're typing

               feat-a
                 🐭 #12 · waiting on you
                 which db?

               feat-idle
               """
               |> String.trim_trailing()
    end

    test "a quiet repo prints nothing at all" do
      assert Sidebar.render(%{}, []) == ""
    end
  end

  describe "snippet/0, the herdr config `whiska doctor` prints" do
    test "colours every line by its first symbol, and only by that" do
      snippet = Sidebar.snippet()

      assert snippet =~ "[ui.sidebar.spaces]"
      assert snippet =~ ~s(token = "$whiska")
      assert snippet =~ ~s(token = "$whiska_q")
      assert snippet =~ ~s(token = "$whiska_q2")
      refute snippet =~ "contains"

      rules = Regex.scan(~r/starts_with = "([^"]+)"/u, snippet, capture: :all_but_first)
      assert length(rules) <= 16

      for symbol <- ~w(🐭 ✅ ⚠ ✖ ? ⏳ 🎯 💤 ⏸ ↩ ◐ ◓ ◑ ◒) do
        assert [symbol] in rules, "no rule for #{symbol}"
      end
    end
  end
end
