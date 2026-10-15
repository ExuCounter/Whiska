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
      mode: Keyword.get(opts, :mode, "build"),
      model: Keyword.get(opts, :model),
      ran_on: Keyword.get(opts, :ran_on),
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
      passed_over:
        Keyword.get(opts, :passed_over_reader, fn _mouse -> Keyword.get(opts, :passed_over) end),
      held: Keyword.get(opts, :held),
      mode: Keyword.get(opts, :mode, Mode.none()),
      picked_up: Keyword.get(opts, :picked_up, %{}),
      stalls: Keyword.get(opts, :stalls, %{}),
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
    |> Sidebar.mice(now: Keyword.get(opts, :now, @now))
  end

  # The one mouse's tokens, the way herdr would be handed them.
  defp tokens(mice, opts) do
    [%{tokens: tokens}] = lines(mice, opts)
    tokens
  end

  defp said(mice, opts \\ []), do: tokens(mice, opts)["whiska"]

  # A working mouse says no state of its own, only its topic.
  defp topic(mice, opts) do
    tokens = tokens(mice, opts)
    refute Map.has_key?(tokens, "whiska")
    tokens["whiska_topic"]
  end

  defp mode(attrs), do: Map.merge(Mode.none(), Map.new(attrs))

  describe "a question waiting on the person" do
    test "sent, it says so and for how long, and carries no excerpt of the question" do
      sent_at = DateTime.add(@now, -14 * 60, :second)

      assert tokens([mouse("feat-a")],
               questions: [question(13, "feat-a", sent_at: sent_at)],
               bare_panes: [pane("feat-a", "idle")]
             ) == %{"whiska" => "❓ waiting on you · 14m"}
    end

    test "next to go and not sent yet, it is waiting on the person without an age" do
      assert tokens([mouse("feat-a")],
               questions: [question(12, "feat-a", status: "open")],
               bare_panes: [pane("feat-a", "idle")]
             ) == %{"whiska" => "❓ waiting on you"}
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

    test "an answer its mouse never took is the person's again" do
      assert tokens([mouse("feat-a")],
               questions: [question(7, "feat-a", status: "answered")],
               bare_panes: [pane("feat-a", "idle")],
               picked_up: %{"m-feat-a" => DateTime.add(@now, -180, :second)}
             ) == %{"whiska" => "❓ answer not taken"}
    end
  end

  describe "a finished report" do
    test "it says finished, and carries nothing of the report" do
      text = "Merged the importer.\n\nAll 31 tests pass.\n\u2063\u2063\u2063"

      assert tokens([mouse("feat-a")],
               finished: [report(14, "feat-a", text)],
               bare_panes: [pane("feat-a", "idle")],
               context: 236_000
             ) == %{"whiska" => "✓ finished", "whiska_ctx_warn" => "236K"}
    end

    test "while another branch's question is out, it still says finished, never queued" do
      [_sent, %{tokens: tokens}] =
        lines([mouse("feat-a"), mouse("feat-b")],
          questions: [question(12, "feat-a")],
          finished: [report(15, "feat-b", "Merged.\n\u2063\u2063\u2063")],
          bare_panes: [pane("feat-a", "idle"), pane("feat-b", "idle")]
        )

      assert tokens == %{"whiska" => "✓ finished"}
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
    test "says it is queued, and carries nothing of its question" do
      [sent, queued] =
        lines([mouse("feat-a"), mouse("feat-b")],
          questions: [question(12, "feat-a"), question(16, "feat-b", status: "open")],
          bare_panes: [pane("feat-a", "idle"), pane("feat-b", "idle")]
        )

      assert sent.tokens["whiska"] =~ "❓ waiting on you"
      assert queued.tokens == %{"whiska" => "⏳ queued"}
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
    test "working, it says its topic and no state: herdr's icon says working" do
      assert tokens([mouse("feat-a")],
               bare_panes: [pane("feat-a", "working", title: "Order builder for distributors")],
               action: fn _ -> {:tool, "Bash python3 - <<'PY'"} end
             ) == %{"whiska_topic" => "Order builder for distributors"}
    end

    test "with no topic, it says what it is doing" do
      assert topic([mouse("feat-a")],
               bare_panes: [pane("feat-a", "working")],
               action: fn _ -> {:tool, "Edit lib/auth.ex"} end
             ) == "Edit lib/auth.ex"
    end

    test "with no topic and no transcript, it still says it is working" do
      assert topic([mouse("feat-a")], bare_panes: [pane("feat-a", "working")]) == "working"
    end

    test "the agent glyph on the front of a title is not the topic" do
      for title <- ["✳ Order builder", "✳Order builder"] do
        assert topic([mouse("feat-a")], bare_panes: [pane("feat-a", "working", title: title)]) ==
                 "Order builder"
      end
    end

    test "an escape sequence or a newline in a title never reaches herdr" do
      topic =
        topic([mouse("feat-a")],
          bare_panes: [pane("feat-a", "working", title: "topic\e]0;PWNED\a\nforged line")]
        )

      refute topic =~ "\e"
      refute topic =~ "\n"
    end

    test "a title that reads like a question is never the state, so never coloured as one" do
      forged = "❓ waiting on you"

      refute [mouse("feat-a")]
             |> tokens(bare_panes: [pane("feat-a", "working", title: forged)])
             |> Map.has_key?("whiska")
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

    test "waiting out an API error, it says when the next pickup is due" do
      assert said([mouse("feat-a")],
               bare_panes: [pane("feat-a", "done")],
               picked_up: %{"m-feat-a" => DateTime.add(@now, -60, :second)},
               stalls: %{
                 "m-feat-a" => %{kind: "server_error", retry_at: DateTime.add(@now, 240, :second)}
               }
             ) == "↻ API error · retry in 4m"
    end

    test "waiting out an expired login, it says what the person has to do" do
      assert said([mouse("feat-a")],
               bare_panes: [pane("feat-a", "idle")],
               stalls: %{"m-feat-a" => %{kind: "authentication_failed", retry_at: @now}}
             ) == "🔑 login expired · run /login"
    end

    test "waiting out a rate limit, it says when the limit resets" do
      reset = DateTime.add(@now, 3 * 3600, :second)

      assert said([mouse("feat-a")],
               bare_panes: [pane("feat-a", "idle")],
               stalls: %{"m-feat-a" => %{kind: "rate_limit", retry_at: reset}}
             ) =~ ~r/^⏳ limit · resets \d\d:\d\d$/
    end

    test "a rate limit resetting another day names the day" do
      reset = DateTime.add(@now, 5 * 86_400, :second)

      assert said([mouse("feat-a")],
               bare_panes: [pane("feat-a", "idle")],
               stalls: %{"m-feat-a" => %{kind: "rate_limit", retry_at: reset}}
             ) =~ ~r/^⏳ limit · resets Oct \d+ \d\d:\d\d$/
    end

    test "an API error never picked up says so, and sorts with the stuck" do
      [first, _] =
        lines([mouse("feat-a"), mouse("feat-b")],
          bare_panes: [pane("feat-a", "working", title: "Order builder"), pane("feat-b", "idle")],
          stalls: %{"m-feat-b" => %{kind: "invalid_request", retry_at: nil}}
        )

      assert first.branch == "feat-b"
      assert first.tokens["whiska"] == "✖ API error"
    end

    test "while the pickup's own turn runs, it says picked up, not the error it waits out" do
      assert said([mouse("feat-a")],
               bare_panes: [pane("feat-a", "working", title: "Order builder")],
               picked_up: %{"m-feat-a" => DateTime.add(@now, -150, :second)},
               stalls: %{"m-feat-a" => %{kind: "server_error", retry_at: @now}}
             ) == "↩ picked up 2m ago"
    end

    test "idle, it says its size and `○ idle`, which herdr's icon alone does not spell out" do
      assert tokens([mouse("feat-a")],
               bare_panes: [pane("feat-a", "idle", title: "Order builder")],
               action: fn _ -> {:said, "31 tests pass."} end,
               context: 212_000
             ) == %{"whiska" => "○ idle", "whiska_ctx_warn" => "212K"}
    end

    test "herdr's done is idle too" do
      assert tokens([mouse("feat-a")], bare_panes: [pane("feat-a", "done")]) == %{
               "whiska" => "○ idle"
             }
    end
  end

  describe "a mouse that is stuck" do
    test "blocked, it says how long it has been silent, and nothing of what it is stuck in" do
      assert tokens([mouse("feat-a")],
               bare_panes: [pane("feat-a", "blocked", title: "Order builder")],
               action: fn _ -> {:tool, "Bash mix test"} end,
               silent_for: 6 * 60
             ) == %{"whiska" => "✖ stuck 6m"}
    end

    test "working and silent in a tool for two minutes is stuck; a second less is not" do
      opts = [
        bare_panes: [pane("feat-a", "working", title: "Order builder")],
        action: fn _ -> {:tool, "Bash mix test"} end,
        in_tool?: true
      ]

      assert said([mouse("feat-a")], [silent_for: 120] ++ opts) == "✖ stuck 2m"
      assert topic([mouse("feat-a")], [silent_for: 119] ++ opts) == "Order builder"
    end

    test "working and waiting on the model is working until five minutes, then stuck" do
      opts = [
        bare_panes: [pane("feat-a", "working", title: "Order builder")],
        action: fn _ -> {:said, "Waiting on the documentation check."} end,
        in_tool?: false
      ]

      assert topic([mouse("feat-a")], [silent_for: 196] ++ opts) == "Order builder"
      assert topic([mouse("feat-a")], [silent_for: 299] ++ opts) == "Order builder"
      assert said([mouse("feat-a")], [silent_for: 300] ++ opts) == "✖ stuck 5m"
    end

    test "working and silent while a subagent runs is working, not stuck" do
      opts = [
        bare_panes: [pane("feat-a", "working", title: "Order builder")],
        silent_for: 600,
        subagent?: true
      ]

      assert topic([mouse("feat-a")], opts) == "Order builder"
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

    test "an idle pane whose last stop was passed over with work out is working, and says so" do
      assert tokens([mouse("feat-a")],
               bare_panes: [pane("feat-a", "idle", title: "Order builder")],
               passed_over: :in_flight
             ) == %{"whiska" => "◐ background", "whiska_topic" => "Order builder"}
    end

    test "an idle pane whose passed-over work never reported is stuck" do
      assert said([mouse("feat-a")],
               bare_panes: [pane("feat-a", "done", title: "Order builder")],
               silent_for: 40 * 60,
               passed_over: :abandoned
             ) == "✖ stuck 40m"
    end

    test "only an idle mouse with nothing to say is asked about passed-over work" do
      me = self()
      asked = fn _mouse -> send(me, :asked) && :abandoned end

      for opts <- [
            [questions: [question(13, "feat-a", status: "open")]],
            [finished: [report(14, "feat-a", "## Summary\nShipped.")]],
            [bare_panes: [pane("feat-a", "working")]]
          ] do
        said(
          [mouse("feat-a")],
          opts ++ [bare_panes: [pane("feat-a", "idle")], passed_over_reader: asked]
        )

        refute_received :asked, inspect(opts)
      end

      said([mouse("feat-a")], bare_panes: [pane("feat-a", "idle")], passed_over_reader: asked)
      assert_received :asked
    end

    test "blocked is stuck even with a subagent out" do
      assert said([mouse("feat-a")],
               bare_panes: [pane("feat-a", "blocked")],
               silent_for: 600,
               subagent?: true
             ) == "✖ stuck 10m"
    end

    test "working with no transcript at all is not called stuck" do
      assert topic([mouse("feat-a")],
               bare_panes: [pane("feat-a", "working", title: "Order builder")],
               silent_for: nil
             ) == "Order builder"
    end
  end

  describe "the context size" do
    test "a working mouse's line has no spinner, and a near-full context is red" do
      assert tokens([mouse("feat-a")],
               bare_panes: [pane("feat-a", "working", title: "fixing")],
               context: 280_000
             ) == %{"whiska_ctx_full" => "280K", "whiska_topic" => "fixing"}
    end

    test "goes in the token of its band: under two thirds of the window, from there, from 90%" do
      for {context, key} <- [
            {199_000, "whiska_ctx"},
            {200_000, "whiska_ctx_warn"},
            {270_000, "whiska_ctx_full"}
          ] do
        assert Map.keys(
                 tokens([mouse("feat-a")], bare_panes: [pane("feat-a", "done")], context: context)
               ) ==
                 Enum.sort(["whiska", key])
      end
    end

    test "is measured against the window its model was shaped with, a sniff mouse's too" do
      haiku = [model: "haiku", ran_on: "claude-haiku-4-5-20251001", mode: "sniff"]

      assert tokens([mouse("feat-a", haiku)],
               bare_panes: [pane("feat-a", "done")],
               context: 90_000
             ) == %{"whiska" => "○ idle", "whiska_ctx_full" => "90K"}
    end

    test "sits beside every state's own words, which stay as they are" do
      assert tokens([mouse("feat-a")],
               bare_panes: [pane("feat-a", "idle")],
               questions: [question(4, "feat-a")],
               context: 142_000
             ) == %{"whiska" => "❓ waiting on you", "whiska_ctx" => "142K"}

      assert tokens([mouse("feat-a", held_at: @now)],
               bare_panes: [pane("feat-a", "idle")],
               mode: mode(held: MapSet.new(["m-feat-a"])),
               context: 447_000
             ) == %{"whiska" => "⏸ held", "whiska_ctx_full" => "447K"}
    end

    test "a mouse with no pane has none on its line" do
      assert tokens([mouse("feat-a")], context: 142_000) == %{"whiska" => "✖ no pane"}
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
      assert tokens([mouse("feat-a")],
               bare_panes: [pane("feat-a", "working", title: "Order builder")]
             ) == %{"whiska_topic" => "Order builder"}
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

    test "a finished mouse sits last, below a held one, since it waits on nobody" do
      mice = [mouse("done"), mouse("held", held_at: @now), mouse("idle")]

      assert mice
             |> lines(
               finished: [report(14, "done", "Merged.\n\u2063\u2063\u2063")],
               bare_panes: for(m <- mice, do: pane(m.branch, "idle")),
               mode: mode(held: MapSet.new(["m-held"]))
             )
             |> Enum.map(& &1.branch) == ~w(idle held done)
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
      )
      |> then(&for(key <- ~w(whiska_mr whiska_ci whiska_review), &1[key], do: &1[key]))
      |> Enum.join(" | ")
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
      assert mr_row(state: "merged") == "⎇ !123 | merged"
      assert mr_row(state: "closed", pipeline: "failed") == "⎇ !123 | closed"
      assert mr_row(state: "gone") == "⎇ !123 | deleted"
    end

    test "a failing read is said once it has failed for three minutes" do
      since = DateTime.add(@now, -20 * 60)
      assert mr_row(unread_since: since, threads_open: 2) == "⎇ !123 | unread 20m"
      assert mr_row(unread_since: DateTime.add(@now, -120)) == "⎇ !123 | ✓"
    end

    test "the pipeline and the review are tokens of their own, each with its own colour" do
      assert mr_row(pipeline: "failed", threads_open: 2) == "⎇ !123 | ✗ | 2 open"
      assert mr_row(pipeline: "running", threads_open: 1) == "⎇ !123 | ◐ | 1 open"
      assert mr_row(pipeline: "passed", ready: true) == "⎇ !123 | ✓ | ready"
      assert mr_row(pipeline: nil, threads_open: 3) == "⎇ !123 | 3 open"
    end

    test "ready is what the review says, open threads or not" do
      assert mr_row(ready: true, threads_open: 2) == "⎇ !123 | ✓ | ready"
    end

    test "with nothing to say of the review, the row is the name and the pipeline" do
      assert mr_row(pipeline: "passed") == "⎇ !123 | ✓"
      assert mr_row(pipeline: nil) == "⎇ !123"
    end

    test "a read of an older link is not this one's" do
      older = "https://gitlab.example.com/acme/app/-/merge_requests/9"
      assert mr_row(url: older, state: "closed") == "⎇ !123"
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
    test "is the main checkout's lines, then each mouse in order under its branch, as herdr joins its rows" do
      board =
        board([mouse("feat-idle"), mouse("feat-a")],
          questions: [question(12, "feat-a", status: "open")],
          bare_panes: [pane("feat-idle", "idle"), pane("feat-a", "idle")],
          held: :typing,
          context: 142_000
        )

      printed =
        Sidebar.render(Sidebar.house(board, main_pane?: true), Sidebar.mice(board, now: @now))

      assert printed ==
               """
               ⏳ gated: you're typing

               feat-a
                 142K · ❓ waiting on you

               feat-idle
                 142K · ○ idle
               """
               |> String.trim_trailing()
    end

    test "a merge request's row prints under its mouse's lines" do
      board =
        board([mouse("feat-a", merge_request: @mr)],
          bare_panes: [pane("feat-a", "working", title: "Orders")],
          merge_requests: %{
            "m-feat-a" => %Whiska.Schema.MergeRequestRead{
              mouse_id: "m-feat-a",
              url: @mr,
              state: "open",
              pipeline: "failed",
              threads_open: 2,
              ready: false,
              read_at: @now
            }
          }
        )

      assert Sidebar.render(%{}, Sidebar.mice(board, now: @now)) ==
               "feat-a\n  Orders\n  ⎇ !123 · ✗ · 2 open"
    end

    test "a quiet repo prints nothing at all" do
      assert Sidebar.render(%{}, []) == ""
    end
  end

  describe "snippet/0, the herdr config `whiska doctor` prints" do
    test "draws every token Whiska reports, and never colours by a word" do
      snippet = Sidebar.snippet()

      assert snippet =~ "[ui.sidebar.spaces]"

      for key <- Sidebar.keys() do
        assert snippet =~ ~s(token = "$#{key}"), "nothing draws #{key}"
      end

      refute snippet =~ "contains"
    end

    test "colours the state by its first symbol, with none for plain working" do
      [state] = Regex.run(~r/token = "\$whiska",.*?\] \}/su, Sidebar.snippet())
      rules = Regex.scan(~r/starts_with = "([^"]+)"/u, state, capture: :all_but_first)

      assert length(rules) <= 16

      for symbol <- ~w(❓ ✓ ⚠ ✖ ? ⏳ 🎯 💤 ⏸ ↩ ◐ ○) do
        assert [symbol] in rules, "no rule for #{symbol}"
      end

      assert ["◐"] in rules
      for symbol <- ~w(◓ ◑ ◒), do: refute([symbol] in rules)
    end

    test "the size, the pipeline and the review sit beside the state and the name" do
      snippet = Sidebar.snippet()

      assert snippet =~
               ~r/\$whiska_ctx".*\$whiska_ctx_warn".*\$whiska_ctx_full".*\$whiska".*\$whiska_topic"/s

      assert snippet =~ ~r/\$whiska_mr".*\$whiska_ci".*\$whiska_review"/s
    end

    test "colour alone: nothing is bold, and the greens are green, not Solarized's olive" do
      snippet = Sidebar.snippet()

      refute snippet =~ "bold"
      refute snippet =~ "#859900"
      assert snippet =~ ~s(starts_with = "✓", fg = "#3fb950")
      assert snippet =~ "row_gap = 0"
    end
  end
end
