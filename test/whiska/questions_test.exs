defmodule Whiska.QuestionsTest do
  @moduledoc """
  `Whiska.Questions` is the one place that answers "what is waiting on me in
  this house" — read by `whiska questions` and by the statusline alike, so the
  two can never disagree (ADR-0048 for how the statusline shows it).
  """
  # Serial: the code under test opens the house under the one VM-wide name `Whiska.Repo`.
  use ExUnit.Case, async: false

  alias Whiska.Doorstep
  alias Whiska.Doorstep.Entry
  alias Whiska.Delivery.Mode
  alias Whiska.Questions
  alias Whiska.Storage

  @mouse %Whiska.Schema.Mouse{mouse_id: "m1", branch: "feat-a", mode: "build"}

  setup do
    root = Path.join(System.tmp_dir!(), "whiska-q-#{Whiska.Test.Unique.id()}")
    main = Path.join(root, "myrepo")
    File.mkdir_p!(Path.join(main, ".git"))
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, main: main}
  end

  # Seed a house through the public storage API, then close it again so the
  # code under test opens the house exactly as a CLI invocation would.
  defp seed(main, fun) do
    {:ok, handle} = Storage.open(main)
    {:ok, _} = Storage.record_mouse(%{mouse_id: "m1", path: "/w/a", branch: "feat-a"})
    {:ok, _} = Storage.record_mouse(%{mouse_id: "m2", path: "/w/b", branch: "feat-b"})
    result = fun.()
    Storage.close(handle)
    result
  end

  defp ask(mouse, text, opts \\ []) do
    {:ok, q} =
      Storage.record_question(%{
        mouse_id: mouse,
        text: text,
        kind: Keyword.get(opts, :kind, "needs-decision"),
        status: Keyword.get(opts, :status, "open")
      })

    q
  end

  defp leave(main, text, age_seconds) do
    {:ok, _} =
      Doorstep.leave(main, %Entry{
        mouse_id: "m1",
        branch: "feat-a",
        worktree_root: "/w/a",
        stamped_at: DateTime.add(DateTime.utc_now(), -age_seconds, :second),
        text: text
      })
  end

  describe "summary/1" do
    test "a house Whiska has never opened has nothing waiting, and is not created", %{main: main} do
      assert {:ok, %{open: [], orphaned: [], doorstep: 0}} = Questions.summary(main)
      refute File.exists?(Storage.database_path(main))
    end

    test "reports open, orphaned and uncollected separately", %{main: main} do
      seed(main, fn ->
        ask("m1", "one")
        ask("m2", "two", status: "sent")
        ask("m1", "gone", status: "orphaned")
        ask("m1", "finished", kind: "done", status: "closed")
        ask("m1", "moved past", status: "superseded")
      end)

      leave(main, "still on the doorstep", 0)

      assert {:ok, %{open: open, orphaned: [orphaned], doorstep: 1}} = Questions.summary(main)
      assert Enum.map(open, & &1.text) == ["one", "two"]
      assert orphaned.text == "gone"
    end
  end

  describe "summary/1 and a finished report on the doorstep" do
    test "is not counted as waiting, yet still says the owl stopped collecting", %{main: main} do
      leave(main, "shipped\n\u2063\u2063\u2063", Questions.backstop_s() + 30)

      assert {:ok, %{doorstep: 0, doorstep_stale: true} = summary} = Questions.summary(main)
      assert Questions.owl_segment(summary) == "🦉 owl down · 0 waiting"
    end
  end

  describe "render/1 — what `whiska questions` prints" do
    test "says plainly when nothing is waiting", %{main: main} do
      {:ok, summary} = Questions.summary(main)

      assert Questions.render(summary) ==
               "🦉 Nothing needs you · the owl delivers when something does"
    end

    test "one line per open question: id, branch, what it did, its pointer, where it stands",
         %{main: main} do
      %{q1: q1, q2: q2} =
        seed(main, fn ->
          q1 = ask("m1", "Recap.\n[worktree-status: needs-decision] pick a cache TTL")
          q2 = ask("m2", "I just stopped.", kind: "unmarked")
          {:ok, _} = Storage.mark_sent(q2.id)
          %{q1: q1, q2: q2}
        end)

      {:ok, summary} = Questions.summary(main)
      out = Questions.render(summary)

      assert [line1, line2] = String.split(out, "\n")

      assert line1 ==
               ~s(##{q1.id}  feat-a  needs a decision · "pick a cache TTL"  \(queued behind ##{q2.id}\))

      assert line2 =~
               ~s(##{q2.id}  feat-b  stopped without saying why · "I just stopped."  \(waiting on you since )
    end

    test "a follow-up that took over the slot holds the rest behind it, not itself",
         %{main: main} do
      %{other: other, heir: heir} =
        seed(main, fn ->
          out = ask("m1", "[worktree-status: needs-decision] pick a cache TTL")
          {:ok, _} = Storage.mark_sent(out.id)
          other = ask("m2", "[worktree-status: needs-decision] and this?")
          heir = ask("m1", "[worktree-status: needs-decision] still waiting on the TTL")
          {:ok, _} = Storage.supersede_earlier(heir)
          %{other: other, heir: heir}
        end)

      {:ok, summary} = Questions.summary(main)
      assert [other_line, heir_line] = String.split(Questions.render(summary), "\n")

      assert other_line =~ "##{other.id} "
      assert other_line =~ "(queued behind ##{heir.id})"
      assert heir_line =~ "##{heir.id} "
      refute heir_line =~ "queued behind"
    end

    test "a finished report waits behind the question out, and says so", %{main: main} do
      %{sent: sent, report: report} =
        seed(main, fn ->
          sent = ask("m1", "[worktree-status: needs-decision] pick a cache TTL")
          {:ok, _} = Storage.mark_sent(sent.id)
          report = ask("m2", "Merged.\n[worktree-status: done]", kind: "done")
          %{sent: sent, report: report}
        end)

      {:ok, summary} = Questions.summary(main)

      assert Questions.render(summary) =~
               "##{report.id}  feat-b  finished  (queued behind ##{sent.id})"
    end

    # The person compares these against the clock on their own screen, so they
    # are this machine's local time, never the UTC they are stored in. On a
    # machine set to UTC the two coincide and this cannot tell them apart.
    test "times are the person's local clock, not UTC" do
      at = ~U[2026-10-04 06:56:00.123456Z]

      q = %Whiska.Schema.Question{
        id: 132,
        mouse_id: "m1",
        kind: "needs-decision",
        status: "sent",
        text: "Body.",
        asked_at: at,
        sent_at: at
      }

      {_date, {h, mi, _s}} =
        :calendar.universal_time_to_local_time({{2026, 10, 4}, {6, 56, 0}})

      pad = &String.pad_leading("#{&1}", 2, "0")

      assert Questions.line(q, 132) =~
               "(waiting on you since #{pad.(h)}:#{pad.(mi)})"
    end

    test "one question in full is its title, where it stands, its links, then its message" do
      two_days = DateTime.add(DateTime.utc_now(), -2 * 86_400, :second)

      q = %Whiska.Schema.Question{
        id: 9,
        mouse_id: "m1",
        kind: "needs-decision",
        status: "sent",
        text: "Answered both.\n\nOk to build?\n⁣⁣",
        asked_at: two_days,
        sent_at: two_days
      }

      documents = fn _ ->
        [
          {"spec", "file:///w/spec.md", "Bypass mode"},
          {"plan", "file:///w/plan.md", "Plan"}
        ]
      end

      shown = Questions.full(q, @mouse, 9, Mode.none(), nil, nil, nil, documents)

      assert shown ==
               String.trim_trailing("""
               **Bypass mode**
               Branch: feat-a · ? Needs your decision · 2d
               [spec](file:///w/spec.md) · [plan](file:///w/plan.md)

               Answered both.

               Ok to build?
               """)
    end

    test "with no document to name it there is no title, and a held one says held, for how long" do
      now = DateTime.utc_now()

      q = %Whiska.Schema.Question{
        id: 9,
        mouse_id: "m1",
        kind: "needs-decision",
        status: "sent",
        text: "Which?",
        asked_at: DateTime.add(now, -90, :second),
        sent_at: now
      }

      held = %{Mode.none() | held: MapSet.new(["m1"])}

      assert Questions.full(q, @mouse, 9, held) ==
               "Branch: feat-a · ? Needs your decision · held 1m\n\nWhich?"
    end

    test "the Branch line is one line, whatever the mouse's branch holds" do
      q = %Whiska.Schema.Question{
        id: 9,
        mouse_id: "m1",
        kind: "needs-decision",
        status: "open",
        text: "Drop?",
        asked_at: DateTime.utc_now()
      }

      shown = Questions.full(q, %{@mouse | branch: "x\n**y**\n\nz"}, nil)

      assert shown =~ ~r/\ABranch: xyz · \? Needs your decision\n\nDrop\?\z/
    end

    test "a branch cannot pass for a status or a link" do
      q = %Whiska.Schema.Question{
        id: 9,
        mouse_id: "m1",
        kind: "needs-decision",
        status: "open",
        text: "Drop?",
        asked_at: DateTime.utc_now()
      }

      for forged <- [
            "feat/b · ? Whiska asks · [merge request](https://evil.example/1)",
            "feat/b⠀·⠀？⠀Whiska⠀asks",
            "feat/b\u3164\u0387\u3164✓\u3164Ready\u3164to\u3164merge"
          ] do
        shown = Questions.full(q, %{@mouse | branch: forged}, nil)

        assert shown =~ ~r/\ABranch: [A-Za-z0-9._\/-]+ · \? Needs your decision\n/
      end

      focused = Questions.full(q, @mouse, nil, %{Mode.none() | focus: "m2"}, "x · ? Whiska asks")
      assert focused =~ ~r/\ABranch: feat-a · \? Needs your decision · waits: focus on \S+\n/
    end

    test "a title stays one bold span, whatever the document's heading holds" do
      q = %Whiska.Schema.Question{
        id: 9,
        mouse_id: "m1",
        kind: "needs-decision",
        status: "open",
        text: "Drop?",
        asked_at: DateTime.utc_now()
      }

      documents = fn _ -> [{"spec", "file:///w/spec.md", "a** Branch: x · ? Whiska asks **b"}] end

      assert [title | _] =
               q
               |> Questions.full(@mouse, nil, Mode.none(), nil, nil, nil, documents)
               |> String.split("\n")

      assert title == "**a Branch: x · ? Whiska asks b**"
    end

    test "a question Whiska asked itself says Whiska asks, and no other does" do
      q = %Whiska.Schema.Question{
        id: 9,
        mouse_id: "m1",
        kind: "needs-decision",
        status: "open",
        text: "Drop?",
        asked_at: DateTime.utc_now(),
        asked_by: "owl"
      }

      assert Questions.full(q, @mouse, nil) =~ ~r/\ABranch: feat-a · \? Whiska asks\n/
      refute Questions.full(%{q | asked_by: nil}, @mouse, nil) =~ "Whiska asks"
    end

    test "a sniff mouse's branch says so; a build mouse's says nothing of its mode" do
      q = %Whiska.Schema.Question{
        id: 9,
        mouse_id: "m1",
        kind: "needs-decision",
        status: "open",
        text: "Which?",
        asked_at: DateTime.utc_now()
      }

      assert Questions.full(q, %{@mouse | mode: "sniff"}, nil) =~
               ~r/\ABranch: feat-a \(sniff\) · \? Needs your decision\n/

      assert Questions.full(q, @mouse, nil) =~ ~r/\ABranch: feat-a · /
    end

    test "away, a focus elsewhere and a held finished report each say so on the Branch line" do
      q = %Whiska.Schema.Question{
        id: 9,
        mouse_id: "m1",
        kind: "needs-decision",
        status: "open",
        text: "Which?",
        asked_at: DateTime.utc_now()
      }

      away = %{Mode.none() | away?: true}
      focus = %{Mode.none() | focus: "m2"}
      held = %{Mode.none() | held: MapSet.new(["m1"])}

      assert Questions.full(q, @mouse, nil, away) =~
               ~r/\ABranch: feat-a · \? Needs your decision · waits: away\n/

      assert Questions.full(q, @mouse, nil, focus, "feat-b") =~
               ~r/\ABranch: feat-a · \? Needs your decision · waits: focus on feat-b\n/

      done = %{q | kind: "done", status: "closed"}

      assert Questions.full(done, @mouse, nil, held) =~
               ~r/\ABranch: feat-a · Finished · held 1m\n/
    end

    test "a question that no longer waits says what became of it, and no clock time" do
      q = %Whiska.Schema.Question{
        id: 9,
        mouse_id: "m1",
        kind: "needs-decision",
        text: "Which?",
        asked_at: DateTime.utc_now()
      }

      taken = DateTime.utc_now()

      for {status, taken_at, said} <- [
            {"superseded", nil, "Superseded"},
            {"closed", nil, "Closed"},
            {"orphaned", nil, "Orphaned"},
            {"answered", taken, "Answered"},
            {"answered", nil, "Answered · not taken"}
          ] do
        shown = Questions.full(%{q | status: status, taken_at: taken_at}, @mouse, nil)
        assert shown =~ ~r/\ABranch: feat-a · #{said}\n/
      end
    end

    test "a turn that stopped without a marker says so" do
      q = %Whiska.Schema.Question{
        id: 9,
        mouse_id: "m1",
        kind: "unmarked",
        status: "open",
        text: "Halfway.",
        asked_at: DateTime.utc_now()
      }

      assert Questions.full(q, @mouse, nil) =~
               ~r/\ABranch: feat-a · ! Stopped without saying why\n/
    end

    test "with no record of its mouse the branch is the mouse's id" do
      q = %Whiska.Schema.Question{
        id: 9,
        mouse_id: "m1",
        kind: "needs-decision",
        status: "open",
        text: "Drop?",
        asked_at: DateTime.utc_now()
      }

      assert Questions.full(q, nil, nil) =~ ~r/\ABranch: m1 · /
    end

    test "a line typed blind says so under the links" do
      q = %Whiska.Schema.Question{
        id: 9,
        mouse_id: "m1",
        kind: "needs-decision",
        status: "sent",
        text: "Which?",
        asked_at: DateTime.utc_now(),
        sent_at: DateTime.utc_now(),
        typed_blind: true
      }

      assert Questions.full(q, @mouse, 9) ==
               "Branch: feat-a · ? Needs your decision\n" <>
                 "Delivered blind: herdr could not tell whether this session was idle.\n\nWhich?"
    end

    test "at length, a queued question still says what it is behind", %{main: main} do
      %{sent: sent} =
        seed(main, fn ->
          sent = ask("m1", "Recap.\n[worktree-status: needs-decision] pick a cache TTL")
          {:ok, _} = Storage.mark_sent(sent.id)
          ask("m2", "The other one.\n[worktree-status: needs-decision] name the flag")
          %{sent: sent}
        end)

      {:ok, summary} = Questions.summary(main)

      assert Questions.render_full(summary) =~ "Branch: feat-b · ? Needs your decision · queued\n"
    end

    test "a report that ends on a decision shows its summary and the question it asks", %{
      main: main
    } do
      q =
        seed(main, fn ->
          ask(
            "m1",
            "# Built\n\n## Summary\nDone.\n\n## Options\nKeep or drop.\n\nKeep the flag?\n⁣⁣"
          )
        end)

      shown = Questions.full(q, @mouse, nil)

      assert shown =~ "\n\n## Summary\nDone.\n\nKeep the flag?"
      refute shown =~ "## Options"
    end

    test "a turn that stopped without a marker is shown whole, Summary or not", %{main: main} do
      text = "# Built\n\n## Summary\nDone.\n\n## Why it stopped\nThe tests hang."
      q = seed(main, fn -> ask("m1", text, kind: "unmarked") end)

      assert Questions.full(q, @mouse, nil) =~ "The tests hang."
    end

    test "an open question with nothing sent is just open", %{main: main} do
      q = seed(main, fn -> ask("m1", "Recap.\n[worktree-status: needs-decision] pick one") end)

      {:ok, summary} = Questions.summary(main)

      assert Questions.render(summary) =~
               ~s(##{q.id}  feat-a  needs a decision · "pick one"  \(open\))
    end

    test "orphaned questions are shown apart, after the open ones (ADR-0036)", %{main: main} do
      seed(main, fn ->
        ask("m1", "live")
        ask("m2", "its worktree is gone", status: "orphaned")
      end)

      {:ok, summary} = Questions.summary(main)
      out = Questions.render(summary)

      assert out =~ "1 orphaned"
      assert out =~ ~s("its worktree is gone"  \(orphaned\))
      assert out =~ ~r/live.*\n\n1 orphaned/s
    end

    test "an answer its mouse has not taken is shown apart, saying how to hand it over",
         %{main: main} do
      seed(main, fn ->
        q = ask("m1", "pick one")
        {:ok, _} = Storage.answer(q.id, "the first")
        {:ok, _} = Storage.mark_not_taken(q.id, DateTime.utc_now())
      end)

      {:ok, summary} = Questions.summary(main)
      out = Questions.render(summary)

      assert out =~ "1 answer not taken"
      assert out =~ "type anything into the mouse's pane"
      assert out =~ ~s(#1  feat-a  needs a decision · "pick one"  \(answered, not taken\))
    end

    test "an answered question says whether its mouse took the answer, and when", %{
      main: main
    } do
      seed(main, fn ->
        taken = ask("m1", "pick one")
        {:ok, _} = Storage.answer(taken.id, "the first")
        {:ok, _} = Storage.take([taken.id], ~U[2026-10-06 09:30:00Z])
        untaken = ask("m2", "pick two")
        {:ok, _} = Storage.answer(untaken.id, "the second")
      end)

      seed(main, fn ->
        assert Questions.state(Storage.question(1), nil) =~ ~r/^answered, taken \d\d:\d\d$/
        assert Questions.state(Storage.question(2), nil) == "answered, not taken"
      end)
    end

    test "uncollected doorstep entries are named, since the owl may be down", %{main: main} do
      leave(main, "waiting for the owl", 0)
      leave(main, "also waiting", 0)

      {:ok, summary} = Questions.summary(main)
      out = Questions.render(summary)

      assert out =~ "2 on the doorstep"
      assert out =~ "owl"
    end
  end

  describe "render_full/1 — what `whiska questions --full` prints" do
    test "says plainly when nothing is waiting, the same as the summary", %{main: main} do
      {:ok, summary} = Questions.summary(main)

      assert Questions.render_full(summary) ==
               "🦉 Nothing needs you · the owl delivers when something does"
    end

    test "every open question in full, oldest first, clearly separated", %{main: main} do
      %{q1: q1, q2: q2} =
        seed(main, fn ->
          q1 = ask("m1", "Recap.\n[worktree-status: needs-decision] pick a cache TTL")
          q2 = ask("m2", "The other one.\n[worktree-status: needs-decision] name the flag")
          %{q1: q1, q2: q2}
        end)

      {:ok, summary} = Questions.summary(main)
      out = Questions.render_full(summary)

      assert [first, second] = String.split(out, Questions.separator())

      [o1, o2] = summary.open
      assert String.trim(first) == "##{q1.id}\n" <> Questions.full(o1, o1.mouse, nil)
      assert String.trim(second) == "##{q2.id}\n" <> Questions.full(o2, o2.mouse, nil)

      # Oldest first, and the whole text is there, not a pointer.
      assert out =~ "pick a cache TTL"
      assert out =~ "name the flag"
      assert out =~ ~r/pick a cache TTL.*name the flag/s
      # Plumbing stays out of what the person reads: no marker token, no
      # `answer:` trailer — the `question:` line carries the id, the block in CLAUDE.md
      # says how to reply.
      refute out =~ "[worktree-status"
      refute out =~ "answer: whiska reply"
    end

    test "the not-actionable block follows, exactly as the summary shows it", %{main: main} do
      seed(main, fn ->
        ask("m1", "live")
        ask("m2", "its worktree is gone", status: "orphaned")
      end)

      leave(main, "waiting for the owl", 0)

      {:ok, summary} = Questions.summary(main)
      out = Questions.render_full(summary)

      assert out =~ "1 orphaned"
      assert out =~ ~s("its worktree is gone"  \(orphaned\))
      assert out =~ "1 on the doorstep"
      assert out =~ ~r/live.*\n\n1 orphaned.*\n\n1 on the doorstep/s
    end

    test "nothing open but something orphaned still says nothing needs you first", %{main: main} do
      seed(main, fn -> ask("m2", "its worktree is gone", status: "orphaned") end)

      {:ok, summary} = Questions.summary(main)
      out = Questions.render_full(summary)

      assert out =~ "🦉 Nothing needs you"
      assert out =~ "1 orphaned"
    end
  end

  describe "what the person set aside (ADR-0079)" do
    test "a held mouse's question says held, in the listing and at length", %{main: main} do
      seed(main, fn ->
        ask("m1", "which db?\n[worktree-status: needs-decision] which db?")
        {:ok, _} = Storage.hold("m1")
      end)

      {:ok, summary} = Questions.summary(main)
      assert Questions.render(summary) =~ ~s|#1  feat-a  needs a decision · "which db?"  (held)|
      assert Questions.render_full(summary) =~ "Branch: feat-a · ? Needs your decision · held"
    end

    test "a question waiting behind a focus names the focused branch", %{main: main} do
      seed(main, fn ->
        ask("m1", "[worktree-status: needs-decision] a?")
        ask("m2", "[worktree-status: needs-decision] b?")
        :ok = Storage.set_focus("m2")
      end)

      {:ok, summary} = Questions.summary(main)
      listing = Questions.render(summary)
      assert listing =~ ~s|#1  feat-a  needs a decision · "a?"  (waits: focus on feat-b)|
      assert listing =~ ~s|#2  feat-b  needs a decision · "b?"  (open)|
    end

    test "a question behind a focus is not queued behind the other mouse's sent one", %{
      main: main
    } do
      seed(main, fn ->
        q = ask("m1", "[worktree-status: needs-decision] a?")
        {:ok, _} = Storage.mark_sent(q.id)
        ask("m2", "[worktree-status: needs-decision] b?")
        :ok = Storage.set_focus("m2")
      end)

      {:ok, summary} = Questions.summary(main)
      listing = Questions.render(summary)
      assert listing =~ "#1  feat-a  needs a decision · \"a?\"  (waiting on you since"
      assert listing =~ ~s|#2  feat-b  needs a decision · "b?"  (open)|
      refute listing =~ "queued behind"
    end

    test "a finished report waits on nothing: away or a focus elsewhere leaves it closed, a hold says so",
         %{main: main} do
      seed(main, fn ->
        {:ok, _} =
          Storage.record_question(%{
            mouse_id: "m1",
            text: "Done.",
            kind: "done",
            status: "closed"
          })

        :ok = Storage.set_focus("m2")
      end)

      seed(main, fn ->
        report = Storage.question(1)
        assert Questions.state(report, nil, Mode.read(away_path: "/nonexistent")) == "closed"
        assert Questions.state(report, nil, %{Mode.none() | away?: true}) == "closed"
        assert Questions.state(report, nil, %{Mode.none() | held: MapSet.new(["m1"])}) == "held"
      end)
    end

    test "while away every open question says so", %{main: main} do
      away = Path.join(Path.dirname(main), "away")
      :ok = Whiska.Delivery.Mode.set_away(away)
      seed(main, fn -> ask("m1", "[worktree-status: needs-decision] a?") end)

      {:ok, summary} = Questions.summary(main, away_path: away)
      assert Questions.render(summary) =~ "(waits: away)"
    end
  end

  describe "statusline/1 — detail for one, a count for many (ADR-0048)" do
    test "nothing waiting → nothing shown", %{main: main} do
      {:ok, summary} = Questions.summary(main)
      assert Questions.statusline(summary) == ""
    end

    test "one open question → its branch and pointer", %{main: main} do
      seed(main, fn ->
        ask("m1", "Recap.\n[worktree-status: needs-decision] pick a cache TTL")
      end)

      {:ok, summary} = Questions.summary(main)
      assert Questions.statusline(summary) == "🐱 feat-a: pick a cache TTL"
    end

    test "an unmarked question shows its first line, clipped to fit", %{main: main} do
      seed(main, fn -> ask("m1", String.duplicate("word ", 40), kind: "unmarked") end)

      {:ok, summary} = Questions.summary(main)
      segment = Questions.statusline(summary)
      assert String.starts_with?(segment, "🐱 feat-a: word word")
      assert String.ends_with?(segment, "…")
      assert String.length(segment) <= 60 + String.length("🐱 feat-a: ")
    end

    test "two or more → a count", %{main: main} do
      seed(main, fn ->
        ask("m1", "a")
        ask("m2", "b")
        ask("m1", "c", status: "sent")
      end)

      {:ok, summary} = Questions.summary(main)
      assert Questions.statusline(summary) == "🐱 3 questions waiting"
    end

    test "orphaned questions never count", %{main: main} do
      seed(main, fn -> ask("m1", "gone", status: "orphaned") end)

      {:ok, summary} = Questions.summary(main)
      assert Questions.statusline(summary) == ""
    end

    test "an entry left uncollected past the backstop means the owl is down", %{main: main} do
      leave(main, "old", 120)
      leave(main, "newer", 90)

      {:ok, summary} = Questions.summary(main)
      assert Questions.statusline(summary) == "🦉 owl down · 2 waiting"
    end

    test "a fresh doorstep entry is not evidence of anything yet", %{main: main} do
      leave(main, "just now", 0)

      {:ok, summary} = Questions.summary(main)
      assert Questions.statusline(summary) == ""
    end

    test "both at once: the owl first, then what is open", %{main: main} do
      seed(main, fn -> ask("m1", "a") end)
      leave(main, "old", 120)

      {:ok, summary} = Questions.summary(main)
      assert Questions.statusline(summary) == "🦉 owl down · 1 waiting · 🐱 feat-a: a"
    end
  end
end
