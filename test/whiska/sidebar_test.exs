defmodule Whiska.SidebarTest do
  @moduledoc """
  The lines herdr's sidebar draws for a house: one under each mouse's
  workspace, one under the main checkout's
  (ADR-0082).

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
      held_at: Keyword.get(opts, :held_at),
      merge_request_url: Keyword.get(opts, :merge_request),
      merge_request_at: if(Keyword.has_key?(opts, :merge_request), do: @now)
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

  defp report(id, branch, text) do
    %{question(id, branch, kind: "done", text: text) | status: "closed"}
  end

  defp board(mice, opts) do
    Watch.board(mice,
      questions: Keyword.get(opts, :questions, []),
      finished: Keyword.get(opts, :finished, []),
      panes: Keyword.get(opts, :panes, {:ok, Keyword.get(opts, :bare_panes, [])}),
      activity: activity(opts),
      waiting_on: waiting_on(opts),
      held: Keyword.get(opts, :held),
      mode: Keyword.get(opts, :mode, Mode.none()),
      picked_up: Keyword.get(opts, :picked_up, %{}),
      merge_requests: Keyword.get(opts, :merge_requests, %{}),
      unhoused_merge_requests: Keyword.get(opts, :unhoused_merge_requests, 0)
    )
  end

  # The board asks one question of a mouse's transcript: what it is doing, and
  # how long since it did anything. A test pins either half.
  defp activity(opts) do
    action = Keyword.get(opts, :action, fn _mouse -> nil end)
    silent_for = Keyword.get(opts, :silent_for, 0)
    context = Keyword.get(opts, :context)

    fn mouse ->
      %{action: action.(mouse), silent_for: silent_for, context: context}
    end
  end

  # What a quiet working mouse waits on: a subagent, a tool, else the model.
  defp waiting_on(opts) do
    waiting = %{
      subagent?: Keyword.get(opts, :subagent?, false),
      in_tool?: Keyword.get(opts, :in_tool?, true)
    }

    Keyword.get(opts, :waiting_on, fn _mouse -> waiting end)
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
             ) == %{"whiska" => "❓ waiting on you · 14m", "whiska_q" => "which db?"}
    end

    test "next to go and not sent yet, it is waiting on the person without an age" do
      assert tokens([mouse("feat-a")],
               questions: [question(12, "feat-a", status: "open")],
               bare_panes: [pane("feat-a", "idle")]
             ) == %{"whiska" => "❓ waiting on you", "whiska_q" => "which db?"}
    end

    test "an age under a minute is still an age, and an hour is spelled like `whiska mice`" do
      for {ago, age} <- [{20, "<1m"}, {59 * 60 + 59, "59m"}, {5580, "1h 33m"}] do
        sent_at = DateTime.add(@now, -ago, :second)

        assert said([mouse("feat-a")],
                 questions: [question(13, "feat-a", sent_at: sent_at)],
                 bare_panes: [pane("feat-a", "idle")]
               ) == "❓ waiting on you · #{age}"
      end
    end

    test "beats whatever the mouse is working on" do
      assert said([mouse("feat-a")],
               questions: [question(52, "feat-a", status: "open")],
               bare_panes: [pane("feat-a", "working", title: "Order builder")],
               action: fn _ -> {:tool, "Edit lib/auth.ex"} end
             ) == "❓ waiting on you"
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
             ) == %{"whiska" => "❓ answer not taken"}
    end
  end

  describe "a finished report" do
    test "it says finished, with its closing line underneath" do
      text = "Merged the importer.\n\nAll 31 tests pass.\n\u2063\u2063\u2063"

      assert tokens([mouse("feat-a")],
               finished: [report(14, "feat-a", text)],
               bare_panes: [pane("feat-a", "idle")]
             ) == %{"whiska" => "✅ finished", "whiska_q" => "All 31 tests pass."}
    end

    test "carries its summary's first line, never the ledger it ends in" do
      text = """
      # Merged the importer
      ## Summary
      Importer merged; 31 tests pass.
      Agent usage this session
      mouse (whole session) · claude-opus-5-5 · xhigh
      ⁣⁣⁣
      """

      assert tokens([mouse("feat-a")],
               finished: [report(14, "feat-a", text)],
               bare_panes: [pane("feat-a", "idle")],
               context: 236_000
             ) == %{
               "whiska" => "✅ 236K · finished",
               "whiska_q" => "Importer merged; 31 tests pass."
             }
    end

    test "with no summary, carries the last line before the ledger" do
      text =
        "Merged.\n\nAll 31 tests pass.\n\nAgent usage this session\nmouse (whole session)\n⁣⁣⁣"

      assert tokens([mouse("feat-a")],
               finished: [report(14, "feat-a", text)],
               bare_panes: [pane("feat-a", "idle")]
             )["whiska_q"] == "All 31 tests pass."
    end

    test "while another branch's question is out, it still says finished, never queued" do
      [_sent, %{tokens: tokens}] =
        lines([mouse("feat-a"), mouse("feat-b")],
          questions: [question(12, "feat-a")],
          finished: [report(15, "feat-b", "Merged.\n\u2063\u2063\u2063")],
          bare_panes: [pane("feat-a", "idle"), pane("feat-b", "idle")]
        )

      assert tokens == %{"whiska" => "✅ finished", "whiska_q" => "Merged."}
    end

    test "a question its mouse asked since stands for the row instead" do
      assert tokens([mouse("feat-a")],
               questions: [question(16, "feat-a", status: "open")],
               finished: [report(14, "feat-a", "Merged.\n\u2063\u2063\u2063")],
               bare_panes: [pane("feat-a", "idle")]
             )["whiska"] =~ "waiting on you"
    end

    test "with no workspace of its own, it is not counted as waiting on the main checkout's line" do
      board =
        board([mouse("feat-a")],
          finished: [report(14, "feat-a", "Merged.\n\u2063\u2063\u2063")],
          bare_panes: [pane("feat-a", "idle")]
        )

      assert Sidebar.house(board, main_pane?: true, no_workspace: MapSet.new(["m-feat-a"])) ==
               %{}
    end
  end

  describe "a question waiting behind another" do
    test "names the one it is behind, and keeps its question" do
      [sent, queued] =
        lines([mouse("feat-a"), mouse("feat-b")],
          questions: [question(12, "feat-a"), question(16, "feat-b", status: "open")],
          bare_panes: [pane("feat-a", "idle"), pane("feat-b", "idle")]
        )

      assert sent.tokens["whiska"] =~ "❓ waiting on you"
      assert queued.tokens == %{"whiska" => "⏳ queued", "whiska_q" => "which db?"}
    end
  end

  describe "what the person set aside (ADR-0079)" do
    test "a question behind away says so" do
      assert tokens([mouse("feat-a")],
               questions: [question(15, "feat-a", status: "open")],
               bare_panes: [pane("feat-a", "idle")],
               mode: mode(away?: true)
             ) == %{"whiska" => "💤 waits: away"}
    end

    test "a question behind a focus names the focused branch" do
      [_working, %{tokens: tokens}] =
        lines([mouse("feat-a"), mouse("feat-b")],
          questions: [question(16, "feat-a", status: "open")],
          bare_panes: [pane("feat-a", "idle"), pane("feat-b", "working")],
          mode: mode(focus: "m-feat-b")
        )

      assert tokens == %{"whiska" => "🎯 waits: focus on feat-b"}
    end

    test "the focused branch is made safe before it reaches herdr" do
      focused = %{mouse("feat-b") | branch: "feat\e]0;x\a-b"}

      [_working, %{tokens: tokens}] =
        lines([mouse("feat-a"), focused],
          questions: [question(16, "feat-a", status: "open")],
          bare_panes: [pane("feat-a", "idle"), pane("feat-b", "working")],
          mode: mode(focus: "m-feat-b")
        )

      refute tokens["whiska"] =~ "\e"
      refute tokens["whiska"] =~ "\a"
    end

    test "a held mouse with a question says held" do
      held = mouse("feat-a", held_at: @now)

      assert tokens([held],
               questions: [question(17, "feat-a", status: "open", mouse: held)],
               bare_panes: [pane("feat-a", "working")],
               mode: mode(held: MapSet.new(["m-feat-a"]))
             ) == %{"whiska" => "⏸ held"}
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
      forged = "❓ waiting on you"

      [line] = lines([mouse("feat-a")], bare_panes: [pane("feat-a", "working", title: forged)])

      assert String.starts_with?(line.tokens["whiska"], "◐ ")
    end

    test "picked up by the owl and then stuck, it says it is stuck" do
      assert said([mouse("feat-a")],
               bare_panes: [pane("feat-a", "blocked", title: "Order builder")],
               action: fn _ -> {:tool, "Bash mix test"} end,
               silent_for: 180,
               picked_up: %{"m-feat-a" => DateTime.add(@now, -300, :second)}
             ) == "✖ stuck 3m"
    end

    test "picked up by the owl, it says so while the turn it started runs" do
      assert said([mouse("feat-a")],
               bare_panes: [pane("feat-a", "working", title: "Order builder")],
               picked_up: %{"m-feat-a" => DateTime.add(@now, -150, :second)}
             ) == "↩ picked up 2m ago"
    end

    test "idle with nothing to report, it says so" do
      assert tokens([mouse("feat-a")],
               bare_panes: [pane("feat-a", "idle", title: "Order builder")],
               action: fn _ -> {:said, "31 tests pass."} end
             ) == %{"whiska" => "○ idle"}
    end

    test "herdr's done is idle too" do
      assert tokens([mouse("feat-a")], bare_panes: [pane("feat-a", "done")]) ==
               %{"whiska" => "○ idle"}
    end
  end

  describe "a mouse that is stuck" do
    test "blocked, it says how long it has been silent, and what it is stuck in" do
      assert tokens([mouse("feat-a")],
               bare_panes: [pane("feat-a", "blocked", title: "Order builder")],
               action: fn _ -> {:tool, "Bash mix test"} end,
               silent_for: 6 * 60
             ) == %{"whiska" => "✖ stuck 6m", "whiska_q" => "Bash mix test"}
    end

    test "working and silent in a tool for two minutes is stuck; a second less is not" do
      opts = [
        bare_panes: [pane("feat-a", "working", title: "Order builder")],
        action: fn _ -> {:tool, "Bash mix test"} end,
        in_tool?: true
      ]

      assert said([mouse("feat-a")], [silent_for: 120] ++ opts) == "✖ stuck 2m"
      assert said([mouse("feat-a")], [silent_for: 119] ++ opts) == "◐ Order builder"
    end

    test "working and waiting on the model is working until five minutes, then stuck" do
      opts = [
        bare_panes: [pane("feat-a", "working", title: "Order builder")],
        action: fn _ -> {:said, "Waiting on the documentation check."} end,
        in_tool?: false
      ]

      assert said([mouse("feat-a")], [silent_for: 196] ++ opts) == "◐ Order builder"
      assert said([mouse("feat-a")], [silent_for: 299] ++ opts) == "◐ Order builder"
      assert said([mouse("feat-a")], [silent_for: 300] ++ opts) == "✖ stuck 5m"
    end

    test "working and silent while a subagent runs is working, not stuck" do
      opts = [
        bare_panes: [pane("feat-a", "working", title: "Order builder")],
        silent_for: 600,
        subagent?: true
      ]

      assert said([mouse("feat-a")], opts) == "◐ Order builder"
    end

    test "only a working mouse quiet for two minutes is looked back on" do
      me = self()
      looked_back = fn _mouse -> send(me, :looked_back) && %{subagent?: false, in_tool?: true} end

      for {status, silent_for} <- [{"idle", 3600}, {"blocked", 3600}, {"working", 119}] do
        said([mouse("feat-a")],
          bare_panes: [pane("feat-a", status)],
          silent_for: silent_for,
          waiting_on: looked_back
        )

        refute_received :looked_back, "#{status}, silent #{silent_for}s"
      end

      said([mouse("feat-a")],
        bare_panes: [pane("feat-a", "working")],
        silent_for: 120,
        waiting_on: looked_back
      )

      assert_received :looked_back
    end

    test "blocked is stuck even with a subagent out" do
      assert said([mouse("feat-a")],
               bare_panes: [pane("feat-a", "blocked")],
               silent_for: 600,
               subagent?: true
             ) == "✖ stuck 10m"
    end

    test "blocked with a transcript that says nothing, its topic is what it is stuck in" do
      assert tokens([mouse("feat-a")],
               bare_panes: [pane("feat-a", "blocked", title: "Order builder")],
               silent_for: nil
             ) == %{"whiska" => "✖ stuck", "whiska_q" => "Order builder"}
    end

    test "working with no transcript at all is not called stuck" do
      assert said([mouse("feat-a")],
               bare_panes: [pane("feat-a", "working", title: "Order builder")],
               silent_for: nil
             ) == "◐ Order builder"
    end
  end

  describe "the context gauge" do
    test "a working mouse's line says how full it is, before its free text" do
      assert said([mouse("feat-a")],
               bare_panes: [pane("feat-a", "working", title: "Order builder")],
               context: 142_000
             ) == "◐ 142K · Order builder"
    end

    test "a mouse waiting on the person carries it after the state" do
      assert said([mouse("feat-a")],
               bare_panes: [pane("feat-a", "idle")],
               questions: [question(4, "feat-a")],
               context: 142_000
             ) == "❓ 142K · waiting on you"
    end

    test "a stuck mouse carries it after how long it has been silent" do
      assert said([mouse("feat-a")],
               bare_panes: [pane("feat-a", "blocked")],
               silent_for: 6 * 60,
               context: 142_000
             ) == "✖ 142K · stuck 6m"
    end

    test "an idle mouse carries it after saying idle" do
      assert said([mouse("feat-a")], bare_panes: [pane("feat-a", "idle")], context: 142_000) ==
               "○ 142K · idle"
    end

    test "a held mouse carries it right after the symbol" do
      assert said([mouse("feat-a", held_at: @now)],
               bare_panes: [pane("feat-a", "idle")],
               mode: mode(held: MapSet.new(["m-feat-a"])),
               context: 447_000
             ) == "⏸ 447K · held"
    end

    test "a queued mouse carries it right after the symbol" do
      [_sent, %{tokens: tokens}] =
        lines([mouse("feat-a"), mouse("feat-b")],
          questions: [question(12, "feat-a"), question(13, "feat-b", status: "open")],
          bare_panes: [pane("feat-a", "idle"), pane("feat-b", "idle")],
          context: 12_000
        )

      assert tokens["whiska"] == "⏳ 12K · queued"
    end

    test "a mouse with no pane has no gauge on its line" do
      assert said([mouse("feat-a")], context: 142_000) == "✖ no pane"
    end

    test "every live mouse's transcript is read, one with a question too" do
      me = self()

      board =
        Watch.board([mouse("feat-a"), mouse("feat-b")],
          questions: [question(52, "feat-a")],
          panes: {:ok, [pane("feat-a", "idle"), pane("feat-b", "working")]},
          activity: fn mouse ->
            send(me, {:read, mouse.mouse_id})
            %{action: nil, silent_for: 0, context: 142_000}
          end
        )

      assert_received {:read, "m-feat-a"}
      assert_received {:read, "m-feat-b"}
      assert Enum.all?(board.rows, &(&1.context == 142_000))
    end

    test "a transcript that says nothing adds nothing" do
      assert said([mouse("feat-a")],
               bare_panes: [pane("feat-a", "working", title: "Order builder")]
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

      # The queued and the finished-and-queued follow the mouse holding #1, and
      # a hold sits below every active mouse (ADR-0082).
      assert order ==
               ~w(sent queued finished-later stuck picked working no-pane idle idle-too held)
    end

    test "a mouse queued behind a question sits right under the mouse that holds it" do
      order =
        [mouse("working"), mouse("queued"), mouse("holder"), mouse("other-queued")]
        |> lines(
          questions: [
            question(7, "holder", sent_at: @now),
            question(9, "other-queued", status: "open"),
            question(8, "queued", status: "open")
          ],
          bare_panes: for(b <- ~w(working queued holder other-queued), do: pane(b, "working"))
        )
        |> Enum.map(& &1.branch)

      assert order == ~w(holder queued other-queued working)
    end

    test "a sniff mouse sorts below a build mouse in the same state, and by state otherwise" do
      sniff = fn branch -> %{mouse(branch) | mode: "sniff"} end

      order =
        [sniff.("research-working"), mouse("build-working"), sniff.("research-asks")]
        |> lines(
          questions: [question(1, "research-asks", mouse: sniff.("research-asks"))],
          bare_panes:
            for(b <- ~w(research-working build-working research-asks), do: pane(b, "working"))
        )
        |> Enum.map(& &1.branch)

      assert order == ~w(research-asks build-working research-working)
    end

    test "a held, focused or away mouse sits below an idle one" do
      held = [mouse("held", held_at: @now), mouse("idle")]
      away = [mouse("away"), mouse("idle")]
      focus = [mouse("asks"), mouse("target")]

      branches = fn mice, opts -> mice |> lines(opts) |> Enum.map(& &1.branch) end
      panes = fn mice -> for(m <- mice, do: pane(m.branch, "idle")) end

      assert branches.(held,
               bare_panes: panes.(held),
               mode: mode(held: MapSet.new(["m-held"]))
             ) == ~w(idle held)

      assert branches.(away,
               questions: [question(1, "away", status: "open")],
               bare_panes: panes.(away),
               mode: mode(away?: true)
             ) == ~w(idle away)

      assert branches.(focus,
               questions: [question(2, "asks", status: "open")],
               bare_panes: [pane("asks", "idle"), pane("target", "working")],
               mode: mode(focus: "m-target")
             ) == ~w(target asks)
    end

    test "a held mouse with a question behind the slot stays among the held, not under the holder" do
      order =
        [mouse("held", held_at: @now), mouse("holder"), mouse("idle")]
        |> lines(
          questions: [
            question(1, "holder", sent_at: @now),
            question(2, "held", status: "open")
          ],
          bare_panes: for(b <- ~w(held holder idle), do: pane(b, "idle")),
          mode: mode(held: MapSet.new(["m-held"]))
        )
        |> Enum.map(& &1.branch)

      assert order == ~w(holder idle held)
    end
  end

  describe "a merge request's row" do
    @mr "https://gitlab.example.com/acme/app/-/merge_requests/123"

    defp read(fields) do
      struct(
        %Whiska.Schema.MergeRequestRead{
          mouse_id: "m-feat-a",
          url: @mr,
          state: "open",
          pipeline: "passed",
          threads_open: 0,
          ready: false,
          read_at: @now
        },
        fields
      )
    end

    defp mr_row(fields, opts \\ []) do
      merge_request = Keyword.get(opts, :url, @mr)

      reads =
        if fields == :unread,
          do: %{},
          else: %{"m-feat-a" => read(Keyword.put_new(fields, :url, merge_request))}

      tokens([mouse("feat-a", merge_request: merge_request)],
        bare_panes: [pane("feat-a", "idle")],
        merge_requests: reads,
        now: Keyword.get(opts, :now, @now)
      )["whiska_mr"]
    end

    test "a mouse with no merge request has no row for one" do
      refute Map.has_key?(
               tokens([mouse("feat-a")], bare_panes: [pane("feat-a", "idle")]),
               "whiska_mr"
             )
    end

    test "is named the way its forge names it, alone until it is read" do
      assert mr_row(:unread) == "⎇ !123"
      assert mr_row(:unread, url: "https://github.com/acme/app/pull/12") == "⎇ #12"
    end

    test "merged, closed or gone is all it says" do
      assert mr_row(state: "merged") == "⎇ !123 · merged"
      assert mr_row(state: "closed", pipeline: "failed") == "⎇ !123 · closed"
      assert mr_row(state: "gone") == "⎇ !123 · deleted"
    end

    test "a failing read is said once it has failed for three minutes" do
      since = DateTime.add(@now, -20 * 60)
      assert mr_row(unread_since: since, threads_open: 2) == "⎇ !123 · unread 20m"
      assert mr_row(unread_since: DateTime.add(@now, -120)) == "⎇ !123 · ✓"
    end

    test "a failed pipeline comes first, with the open threads when they fit" do
      assert mr_row(pipeline: "failed", threads_open: 2) == "⎇ !123 · pipeline ✗ · 2 threads"
      assert mr_row(pipeline: "failed", threads_open: 1) == "⎇ !123 · pipeline ✗ · 1 thread"
      assert mr_row(pipeline: "failed") == "⎇ !123 · pipeline ✗"

      long = "https://gitlab.example.com/acme/app/-/merge_requests/1234567"
      row = mr_row([pipeline: "failed", threads_open: 2], url: long)
      assert row == "⎇ !1234567 · pipeline ✗"
    end

    test "ready to merge, then open threads with the pipeline after them" do
      assert mr_row(ready: true, threads_open: 2) == "⎇ !123 · ready to merge"
      assert mr_row(threads_open: 2) == "⎇ !123 · 2 threads open · ✓"
      assert mr_row(threads_open: 1, pipeline: "running") == "⎇ !123 · 1 thread open · ◐"
      assert mr_row(threads_open: 3, pipeline: nil) == "⎇ !123 · 3 threads open"
    end

    test "with nothing open, the pipeline" do
      assert mr_row(pipeline: "running") == "⎇ !123 · pipeline ◐"
      assert mr_row(pipeline: "passed") == "⎇ !123 · ✓"
      assert mr_row(pipeline: nil) == "⎇ !123 · open"
    end

    test "a read of an older link is not this one's" do
      older = "https://gitlab.example.com/acme/app/-/merge_requests/9"
      assert mr_row(url: older, state: "closed") == "⎇ !123"
    end

    test "every row fits the sidebar" do
      for fields <- [
            [pipeline: "failed", threads_open: 99],
            [threads_open: 99, pipeline: "running"],
            [unread_since: DateTime.add(@now, -99 * 3600)]
          ] do
        assert String.length(mr_row(fields)) <= 31
      end
    end
  end

  describe "the main checkout's line" do
    defp house(board_opts, opts \\ []) do
      [] |> board(board_opts) |> Sidebar.house(Keyword.merge([main_pane?: true], opts))
    end

    test "is empty when nothing about the repo needs saying" do
      assert house([]) == %{}
    end

    test "counts merge requests still read for branches whose worktree was dropped" do
      assert house(unhoused_merge_requests: 1) == %{"whiska" => "⎇ 1 merge request, no worktree"}
      assert house(unhoused_merge_requests: 2) == %{"whiska" => "⎇ 2 merge requests, no worktree"}
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

    test "says why delivery is gated (ADR-0082)" do
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
               %{"whiska" => "❓ 2 more: whiska questions"}

      assert Sidebar.house(board, main_pane?: true, no_workspace: MapSet.new()) ==
               %{"whiska" => "❓ 1 more: whiska questions"}
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
               "whiska_q2" => "❓ 1 more: whiska questions"
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
                 ❓ waiting on you
                 which db?

               feat-idle
                 ○ idle
               """
               |> String.trim_trailing()
    end

    test "a merge request's row prints under its mouse's lines" do
      board =
        board([mouse("feat-a", merge_request: "https://github.com/acme/app/pull/12")],
          bare_panes: [pane("feat-a", "idle")]
        )

      assert Sidebar.render(%{}, Sidebar.mice(board, now: @now)) == "feat-a\n  ○ idle\n  ⎇ #12"
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
      assert snippet =~ ~s(token = "$whiska_mr")
      refute snippet =~ "contains"

      rules = Regex.scan(~r/starts_with = "([^"]+)"/u, snippet, capture: :all_but_first)
      assert length(rules) <= 16

      for symbol <- ~w(❓ ✅ ⚠ ✖ ? ⏳ 🎯 💤 ⏸ ↩ ◐ ◓ ◑ ◒) do
        assert [symbol] in rules, "no rule for #{symbol}"
      end
    end
  end
end
