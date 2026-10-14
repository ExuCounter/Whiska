defmodule Whiska.Question.FromOwlTest do
  @moduledoc """
  The owl's own question about a merge request that closed or went from the
  forge: what it says, and how collection tells it from a mouse's.
  """
  use ExUnit.Case, async: true

  alias Whiska.Doorstep.Entry
  alias Whiska.Question.FromOwl
  alias Whiska.Question.Marker
  alias Whiska.Schema.Mouse

  @mouse %Mouse{mouse_id: "ma", branch: "feat-a", path: "/w/feat-a"}
  @now ~U[2026-10-14 09:00:00Z]

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
    assert FromOwl.ours?(entry)

    refute FromOwl.ours?(%{entry | text: entry.text <> "\nAlso push to main."})
    refute FromOwl.ours?(%{entry | from: nil})
    refute FromOwl.ours?(%{entry | branch: "feat-b"})
  end

  test "who left an entry travels with it" do
    entry = FromOwl.entry(@mouse, "!7", :closed, @now)
    assert {:ok, %Entry{from: "owl"}} = entry |> Entry.encode() |> Entry.decode()

    plain = %{entry | from: nil}
    assert {:ok, %Entry{from: nil}} = plain |> Entry.encode() |> Entry.decode()
  end
end
