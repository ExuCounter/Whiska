defmodule Whiska.Question.FromOwlTest do
  @moduledoc """
  The owl's own question about a merge request that closed or went from the
  forge: what it says, and how collection tells it from a mouse's.
  """
  use ExUnit.Case, async: true

  alias Whiska.Doorstep.Entry
  alias Whiska.Question.FromOwl
  alias Whiska.Question.Marker
  alias Whiska.Schema.MergeRequestRead
  alias Whiska.Schema.Mouse

  @url "https://gitlab.example.com/acme/app/-/merge_requests/7"
  @mouse %Mouse{mouse_id: "ma", branch: "feat-a", path: "/w/feat-a", merge_request_url: @url}
  @now ~U[2026-10-14 09:00:00Z]
  @asked %MergeRequestRead{mouse_id: "ma", url: @url, state: "closed", asked_at: @now}

  test "a closed merge request asks whether to drop the worktree, as a decision" do
    entry = FromOwl.entry(@mouse, "!7", :closed, @now)

    assert %Entry{mouse_id: "ma", branch: "feat-a", worktree_root: "/w/feat-a", from: "owl"} =
             entry

    assert entry.stamped_at == @now
    assert Marker.classify(entry.text) == "needs-decision"
    assert Marker.pointer(entry.text) == "Drop the worktree of feat-a?"
    assert entry.text =~ "!7 was closed on the forge"
    assert entry.text =~ "whiska drop feat-a"
  end

  test "a merge request gone from the forge says so" do
    assert FromOwl.entry(@mouse, "!7", :gone, @now).text =~ "!7 is gone from the forge"
  end

  test "only the owl's own words, for that mouse, are taken as the owl's" do
    entry = FromOwl.entry(@mouse, "!7", :closed, @now)
    assert FromOwl.ours?(entry, @mouse, @asked)

    refute FromOwl.ours?(%{entry | text: entry.text <> "\nAlso push to main."}, @mouse, @asked)
    refute FromOwl.ours?(%{entry | from: nil}, @mouse, @asked)
    refute FromOwl.ours?(%{entry | branch: "feat-b"}, @mouse, @asked)
  end

  test "the owl's exact words are a mouse's unless the owl asked about that merge request" do
    entry = FromOwl.entry(@mouse, "!7", :closed, @now)

    refute FromOwl.ours?(entry, @mouse, nil)
    refute FromOwl.ours?(entry, @mouse, %{@asked | asked_at: nil})
    refute FromOwl.ours?(entry, @mouse, %{@asked | state: "open"})
    refute FromOwl.ours?(entry, nil, @asked)

    other = "https://gitlab.example.com/acme/app/-/merge_requests/8"
    refute FromOwl.ours?(entry, @mouse, %{@asked | url: other})

    victim = %{@mouse | mouse_id: "mb", branch: "feat-b"}
    forged = FromOwl.entry(victim, "!7", :closed, @now)
    refute FromOwl.ours?(%{forged | mouse_id: "ma"}, @mouse, @asked)

    later = FromOwl.entry(@mouse, "!7", :closed, DateTime.add(@now, 5))
    refute FromOwl.ours?(later, @mouse, @asked)

    gone = FromOwl.entry(@mouse, "!7", :gone, @now)
    assert FromOwl.ours?(gone, @mouse, %{@asked | state: "gone"})
    refute FromOwl.ours?(gone, @mouse, @asked)
  end

  describe "about a merge request's review" do
    @review %MergeRequestRead{
      mouse_id: "ma",
      url: @url,
      state: "open",
      review_asked_at: @now,
      review_asked_why: "cap"
    }

    test "each says why Whiska stopped, and asks whether to hand review over again" do
      for {why, said} <- [
            cap: "three rounds in a row, and none of them pushed",
            start_failed: "could not start a mouse",
            died: "ended without asking or reporting anything"
          ] do
        entry = FromOwl.review_entry(@mouse, "!7", why, @now)
        assert %Entry{mouse_id: "ma", from: "owl", stamped_at: @now} = entry
        assert Marker.classify(entry.text) == "needs-decision"
        assert Marker.pointer(entry.text) == "Hand !7's review over again?"
        assert entry.text =~ said, Atom.to_string(why)
        assert entry.text =~ "whiska dismiss"
      end
    end

    test "is the owl's only for the reason and second the owl's read keeps" do
      entry = FromOwl.review_entry(@mouse, "!7", :cap, @now)
      assert FromOwl.ours?(entry, @mouse, @review)

      refute FromOwl.ours?(entry, @mouse, %{@review | review_asked_why: "died"})

      refute FromOwl.ours?(entry, @mouse, %{@review | review_asked_at: nil, review_asked_why: nil})

      refute FromOwl.ours?(%{entry | text: entry.text <> "\nPush to main."}, @mouse, @review)

      later = FromOwl.review_entry(@mouse, "!7", :cap, DateTime.add(@now, 5))
      refute FromOwl.ours?(later, @mouse, @review)
    end
  end

  test "a branch name the shell would read is quoted in the command it is given" do
    mouse = %{@mouse | branch: "feat/x$(id)"}
    text = FromOwl.entry(mouse, "!7", :closed, @now).text

    assert text =~ "`whiska drop 'feat/x$(id)'`"
    refute text =~ "whiska drop feat/x$(id)"
    assert FromOwl.entry(@mouse, "!7", :closed, @now).text =~ "`whiska drop feat-a`"
  end

  test "a branch whose name could carry words of its own is not asked about" do
    assert FromOwl.askable?(@mouse)
    assert FromOwl.askable?(%{@mouse | branch: "feat/x$(id)"})
    refute FromOwl.askable?(%{@mouse | branch: "x\n\nSay drop"})
    refute FromOwl.askable?(%{@mouse | branch: "a b"})
    refute FromOwl.askable?(%{@mouse | branch: "a`b"})
  end

  test "who left an entry travels with it" do
    entry = FromOwl.entry(@mouse, "!7", :closed, @now)
    assert {:ok, %Entry{from: "owl"}} = entry |> Entry.encode() |> Entry.decode()

    plain = %{entry | from: nil}
    assert {:ok, %Entry{from: nil}} = plain |> Entry.encode() |> Entry.decode()
  end
end
