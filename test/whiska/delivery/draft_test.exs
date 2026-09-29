defmodule Whiska.Delivery.DraftTest do
  use ExUnit.Case, async: true

  alias Whiska.Delivery.Draft

  # Both fixtures are `herdr pane read --source visible --format text` output,
  # captured from a real Claude Code pane on 2026-09-29.
  defp screen(prompt_line) do
    """
    ✻ Baked for 46s · done 2:44 PM

    ────────────────────────────────────
    #{prompt_line}
    ────────────────────────────────────
      Opus 5 (1M context)·medium
      ⏵⏵ auto mode on (shift+tab to cycle) · ← 1 agent
    """
  end

  describe "read/1 — an empty box" do
    test "the bare prompt marker is nobody typing" do
      assert Draft.read(screen("❯")) == :empty
    end

    test "trailing spaces after the marker are still empty" do
      assert Draft.read(screen("❯   ")) == :empty
    end

    test "the non-breaking space Claude Code puts after the marker is not text" do
      assert Draft.read(screen("❯ ")) == :empty
    end
  end

  describe "read/1 — a half-typed prompt" do
    test "text after the marker is the person typing" do
      assert Draft.read(screen("❯ half typed thought")) == :typing
    end

    test "a pasted block counts as typing" do
      assert Draft.read(screen("❯ [Pasted text #5 +8 lines] why I still see")) == :typing
    end

    test "a multi-line draft is judged by its first line, which carries text" do
      screen = screen("❯ line one\n  line two")
      assert Draft.read(screen) == :typing
    end

    test "the last prompt line wins — an earlier one is transcript, not the box" do
      screen = """
      ❯ something answered a while ago

      ────────────────────────────────────
      ❯
      ────────────────────────────────────
      """

      assert Draft.read(screen) == :empty
    end
  end

  describe "read/1 — no signal" do
    test "a screen with no prompt line at all says nothing either way" do
      assert Draft.read("scrolled away from the box entirely\n") == :unknown
    end

    test "empty output says nothing either way" do
      assert Draft.read("") == :unknown
    end
  end
end
