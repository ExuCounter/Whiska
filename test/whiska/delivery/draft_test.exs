defmodule Whiska.Delivery.DraftTest do
  use ExUnit.Case, async: true

  alias Whiska.Delivery.Draft

  @screens Path.expand("../../support/screens", __DIR__)

  # Every `.txt` fixture is `herdr pane read <pane> --source visible --format
  # text`, captured from a live Claude Code pane on 2026-10-03. Two are a
  # captured screen with one edit, and each says in its test what was edited and
  # why no camera could take that picture.
  defp screen(name), do: File.read!(Path.join(@screens, name <> ".txt"))

  # Every `.ansi` fixture is the same read with `--format ansi`, captured
  # untouched on 2026-10-04: the styling is what tells Claude Code's own grey
  # text from the person's.
  defp styled(name), do: File.read!(Path.join(@screens, name <> ".ansi"))

  # A box drawn the way Claude Code drew it on the day: two full-width rules at
  # column 0 with the prompt line between them.
  defp framed(prompt_line) do
    rule = String.duplicate("─", 80)

    """
    ✻ Baked for 46s · done 2:44 PM

    #{rule}
    #{prompt_line}
    #{rule}
      Opus 5 (1M context)·medium
      ⏵⏵ auto mode on (shift+tab to cycle) · ← 1 agent
    """
  end

  describe "read/1 — the box is there and empty" do
    test "the bare prompt marker is nobody typing" do
      assert Draft.read(framed("❯")) == :empty
    end

    test "trailing spaces after the marker are still empty" do
      assert Draft.read(framed("❯   ")) == :empty
    end

    test "the non-breaking space Claude Code puts after the marker is not text" do
      assert Draft.read(framed("❯\u00a0")) == :empty
    end

    test "a box opened onto a second line is still empty" do
      assert Draft.read(framed("❯\u00a0\n  ")) == :empty
    end

    test "a real main session whose box is empty" do
      assert Draft.read(screen("main-session-empty-box-under-a-past-message")) == :empty
    end

    test "an empty box with herdr's agent list drawn under it" do
      assert Draft.read(screen("empty-box-with-agents-below")) == :empty
    end
  end

  describe "read/1 — the box is there and holds a draft" do
    test "text after the marker is the person typing" do
      assert Draft.read(framed("❯ half typed thought")) == :typing
    end

    test "a pasted block counts as typing" do
      assert Draft.read(framed("❯ [Pasted text #5 +8 lines] why I still see")) == :typing
    end

    test "a multi-line draft carrying text on its first line" do
      assert Draft.read(framed("❯ line one\n  line two")) == :typing
    end

    # A draft begun with shift+enter leaves the marker line bare and the words
    # on the line under it. Judging the box by its first line alone called that
    # empty and typed into it.
    test "a multi-line draft whose first line is bare" do
      assert Draft.read(framed("❯\u00a0\n  the thought itself")) == :typing
    end

    test "a real screen with a half-typed line in the box" do
      assert Draft.read(screen("box-holds-a-draft")) == :typing
    end

    # The only fixture that is drawn rather than captured: the live screen it
    # copies was split with a `git diff` view of an unrelated private project.
    # Its shape is what matters — the panel's own rules are indented, inside the
    # right-hand column, and only a rule at column 0 frames the box.
    test "rules drawn inside a side panel do not frame a box" do
      assert Draft.read(screen("draft-with-a-side-panel")) == :typing
    end

    # The lowest rule on the screen is taken for the box's bottom, so a stray
    # one underneath would make the box's own bottom rule the top of a frame
    # around the status lines. The frames are walked until one holds a prompt
    # line, so the real box is still found under it.
    test "a stray rule under the box does not turn the status lines into one" do
      for width <- [20, 167] do
        screen = screen("box-holds-a-draft") <> String.duplicate("─", width) <> "\n"

        assert Draft.read(screen) == :typing
      end
    end
  end

  describe "read/1 — Claude Code's own dim text in the box is not a draft" do
    # The bug this was written for. After a reply Claude Code offers the next
    # prompt as dim text in the empty box, cursor still at the start. Read
    # without its styling it is a line of words, and delivery held on it.
    test "a suggested next prompt is an empty box" do
      screen = styled("suggestion-in-an-empty-box")

      assert screen =~ "❯ \e[0m\e[2mpush and open a PR"
      assert Draft.read(screen) == :empty
    end

    test "the placeholder in a fresh session is an empty box" do
      assert Draft.read(styled("placeholder-in-a-fresh-session")) == :empty
    end

    test "an empty box read with its styling is still empty" do
      assert Draft.read(styled("styled-empty-box-under-a-past-message")) == :empty
    end

    test "what the person typed is drawn plain, and is a draft" do
      assert Draft.read(styled("styled-box-holds-a-draft")) == :typing
    end

    test "a pasted chip is drawn plain, and is a draft" do
      assert Draft.read(styled("styled-box-holds-a-paste")) == :typing
    end

    # Never captured: no Claude Code seen draws typed text next to dim text.
    # Built from the captured line's own escapes, so that one plain character
    # anywhere in the box is enough to hold.
    test "typed text beside dim text is a draft" do
      assert Draft.read(framed("❯ \e[0mhi \e[2mthere\e[0m")) == :typing
      assert Draft.read(framed("❯ \e[0m\e[2msuggested\e[0m\n  \e[0mtyped")) == :typing
    end

    test "dim switched off mid-line makes the rest plain" do
      assert Draft.read(framed("❯ \e[2mdim \e[22mplain")) == :typing
      assert Draft.read(framed("❯ \e[2mdim \e[0mplain")) == :typing
      assert Draft.read(framed("❯ \e[2mdim \e[mplain")) == :typing
    end

    test "dim set together with a colour still counts as dim" do
      assert Draft.read(framed("❯ \e[2;38;5;240mghost\e[0m")) == :empty
    end

    # A theme that draws its ghost in a grey rather than faint is a style
    # Whiska does not recognise, and that falls to holding, never to typing
    # into the box. A `2` inside a colour is a colour, not faint.
    test "grey that is a colour rather than faint is a draft" do
      assert Draft.read(framed("❯ \e[38;2;102;102;102mghost\e[0m")) == :typing
      assert Draft.read(framed("❯ \e[38;2;2;2;2mghost\e[0m")) == :typing
      assert Draft.read(framed("❯ \e[38;5;2mghost\e[0m")) == :typing
    end

    test "a reset written with extra zeros is still a reset" do
      assert Draft.read(framed("❯\u00a0\e[2m\e[00mhello")) == :typing
    end

    test "a colour cut short is a style Whiska cannot read, so what follows is text" do
      assert Draft.read(framed("❯\u00a0\e[38;2;1mhello")) == :typing
      assert Draft.read(framed("❯\u00a0\e[2;38;5mhello")) == :typing
    end

    test "faint left open on a line above does not reach into the box" do
      assert Draft.read("\e[2mx\n" <> framed("❯\u00a0draft")) == :typing
    end

    test "another style laid over faint text makes it text" do
      assert Draft.read(framed("❯\u00a0\e[2mg\e[7mdraft")) == :typing
      assert Draft.read(framed("❯\u00a0\e[2mg\e[1mdraft")) == :typing
    end

    # Taken for no prompt line, the box would read `:unknown`, which delivers.
    test "an escape in front of the marker still finds the box, and holds" do
      assert Draft.read(framed("\e[K❯\u00a0draft")) == :typing
      assert Draft.read(framed("\e]8;;https://x\e\\❯\u00a0\e[2mghost")) == :typing
    end

    test "an escape that is not a style is text, not nothing" do
      assert Draft.read(framed("❯ \e[2m\e[5Cghost")) == :typing
    end
  end

  describe "hold/1 — what delivery and pickup both do with a reading" do
    test "a draft and a missing box hold; an empty box and an unreadable frame go" do
      assert Draft.hold(:typing) == {:hold, :typing}
      assert Draft.hold(:no_box) == {:hold, :no_box}
      assert Draft.hold(:empty) == :go
      assert Draft.hold(:unknown) == :go
    end
  end

  describe "read/1 — a past message is not the box" do
    # The bug this module was rewritten for. Claude Code redraws the person's
    # own past messages with the same `❯`, at column 0, in the scrollback. The
    # last such line is almost never the box.
    test "an earlier message carrying the marker loses to the framed box" do
      screen = """
      ❯ 🐱 held: your prompt box isn't empty

      ────────────────────────────────────
      ❯
      ────────────────────────────────────
      """

      assert Draft.read(screen) == :empty
    end

    test "the real main session has three past messages above an empty box" do
      screen = screen("main-session-empty-box-under-a-past-message")

      assert screen |> String.split("\n") |> Enum.count(&String.starts_with?(&1, "❯")) > 1
      assert Draft.read(screen) == :empty
    end
  end

  describe "read/1 — no box on the screen" do
    # Claude Code takes the box off the screen while a picker is open, and the
    # highlighted row carries a `❯` of its own, three columns in. The picker
    # draws its own rule with `▔` rather than `─`, so this capture proves the
    # reading only down to there being no frame on it: what it pins is the
    # screen the old rule called a half-typed draft.
    test "a model picker is not a prompt box" do
      screen = screen("model-picker-no-box")

      assert screen =~ "❯ 2. Opus"
      assert Draft.read(screen) == :no_box
    end

    # The same capture, cut off at row 30 — which is what the viewport returns
    # when the person has scrolled up past the box. Its last line is a past
    # message, and under the old rule that read as a half-typed draft.
    test "a pane scrolled away from the box" do
      screen = screen("box-scrolled-off-screen")

      assert String.ends_with?(String.trim_trailing(screen), "#108")
      assert Draft.read(screen) == :no_box
    end

    test "empty output has no box on it" do
      assert Draft.read("") == :no_box
    end

    test "one rule with nothing under it is a box cut in half, not a box" do
      assert Draft.read("────────────────\n❯ typed\n") == :no_box
    end
  end

  describe "read/1 — a frame that is not the box we know" do
    # No camera can photograph the next version of Claude Code, so this is the
    # real main session capture with the one character the reading turns on
    # replaced. The frame is where it always was and the line inside it is not
    # a prompt line: that is a signal Whiska cannot read, not a signal that the
    # person is typing (ADR-0008 — an unavailable signal delivers anyway).
    test "a framed line with an unfamiliar marker says nothing either way" do
      assert Draft.read(screen("frame-with-an-unfamiliar-marker")) == :unknown
    end

    test "an empty frame says nothing either way" do
      assert Draft.read("────────────\n────────────\n") == :unknown
    end

    # The marker only counts at column 0, where Claude Code puts it. Indented,
    # it is some other thing that borrowed the character.
    test "an indented marker inside the frame is not the prompt line" do
      assert Draft.read(framed("   ❯ 2. Opus (1M context) ✔")) == :unknown
    end

    test "a frame that holds nothing but blank lines is not the box" do
      assert Draft.read("────────\n\n   \n────────\n") == :unknown
    end
  end
end
