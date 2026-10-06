defmodule Whiska.QuestionsTest do
  @moduledoc """
  `Whiska.Questions` is the one place that answers "what is waiting on me in
  this house" — read by `whiska questions` and by the statusline alike, so the
  two can never disagree (ADR-0027 for how the statusline shows it).
  """
  # Serial: the code under test opens the house under the one VM-wide name `Whiska.Repo`.
  use ExUnit.Case, async: false

  alias Whiska.Doorstep
  alias Whiska.Doorstep.Entry
  alias Whiska.Questions
  alias Whiska.Storage

  setup do
    root = Path.join(System.tmp_dir!(), "whiska-q-#{System.unique_integer([:positive])}")
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

      {{y, mo, d}, {h, mi, _s}} =
        :calendar.universal_time_to_local_time({{2026, 10, 4}, {6, 56, 0}})

      pad = &String.pad_leading("#{&1}", 2, "0")

      assert Questions.line(q, 132) =~
               "(waiting on you since #{pad.(h)}:#{pad.(mi)})"

      assert Questions.full(q, "feat-a", 132) =~
               "asked #{y}-#{pad.(mo)}-#{pad.(d)} #{pad.(h)}:#{pad.(mi)})"
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

      assert Questions.render_full(summary) =~ "(queued behind ##{sent.id}, asked"
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

      # Each block is exactly what `whiska questions <id>` prints today.
      assert String.trim(first) == Questions.full(q1, "feat-a", nil)
      assert String.trim(second) == Questions.full(q2, "feat-b", nil)

      # Oldest first, and the whole text is there, not a pointer.
      assert out =~ "pick a cache TTL"
      assert out =~ "name the flag"
      assert out =~ ~r/pick a cache TTL.*name the flag/s
      # Plumbing stays out of what the person reads: no marker token, no
      # `answer:` trailer — the heading carries the id, the block in CLAUDE.md
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
      assert Questions.render_full(summary) =~ "(held, asked"
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

    test "while away every open question says so", %{main: main} do
      away = Path.join(Path.dirname(main), "away")
      :ok = Whiska.Delivery.Mode.set_away(away)
      seed(main, fn -> ask("m1", "[worktree-status: needs-decision] a?") end)

      {:ok, summary} = Questions.summary(main, away_path: away)
      assert Questions.render(summary) =~ "(waits: away)"
    end
  end

  describe "statusline/1 — detail for one, a count for many (ADR-0027)" do
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
