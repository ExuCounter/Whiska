defmodule Whiska.Delivery.TextTest do
  @moduledoc """
  The one line typed into the main session: a cat, and the question's id in
  blank space characters the person does not read, for the main session's
  hook to read back.
  """
  use ExUnit.Case, async: true

  alias Whiska.Delivery.Text

  test "the person sees a cat and nothing else they can read" do
    line = Text.line(644)

    assert String.starts_with?(line, "🐱")
    assert String.trim(String.replace(line, "⠀", ""), "🐱") |> String.trim() == ""
    refute line =~ "644"
    refute line =~ "\n"
  end

  test "the hook reads the id back from the line, with or without its trailing newline" do
    for id <- [1, 9, 10, 644, 90_210] do
      assert Text.id_in(Text.line(id)) == id
      assert Text.id_in(Text.line(id) <> "\n") == id
    end
  end

  test "anything else the person types carries no id" do
    for prompt <- [
          "🐱",
          "🐱 #644",
          "land 644",
          "",
          Text.line(644) <> " and land it",
          "x" <> Text.line(7)
        ] do
      assert Text.id_in(prompt) == nil
    end
  end

  test "a run of blanks longer than any id is read as none" do
    assert Text.id_in(Text.line(999_999_999_999)) == 999_999_999_999
    assert Text.id_in(Text.line(1_000_000_000_000)) == nil
  end

  test "the blanks survive Claude Code trimming the prompt: a non-space blank closes them" do
    assert String.trim(Text.line(644)) == Text.line(644)
  end

  test "a pointer that runs long is cut, and never carries a newline" do
    long = String.duplicate("word ", 60)
    pointer = Text.pointer("\n" <> long <> "\nline two")
    refute pointer =~ "\n"
    assert String.length(pointer) < 200
    assert pointer =~ "…"
  end

  describe "a letter from another house's main session (ADR-0044)" do
    test "names the sending repo and the file, and nothing it wrote" do
      assert Text.letter("platform", "/r/.git/whiska/letters/1.md") ==
               {:ok, "📨 platform's Whiska sent you a letter: /r/.git/whiska/letters/1.md"}
    end

    test "cuts the repo name to plain characters" do
      assert {:ok, "📨 evil-repo.x's Whiska" <> _} = Text.letter("evil\n-repo`$(.x)`", "/r/1.md")
    end

    test "refuses a path that holds a control character" do
      assert Text.letter("platform", "/r/a\nb.md") == :error
    end

    test "keeps a repo name in any script, and names one cut to nothing another repo" do
      assert {:ok, "📨 café-app's Whiska" <> _} = Text.letter("café-app", "/r/a.md")
      assert {:ok, "📨 another repo's Whiska" <> _} = Text.letter("$( )", "/r/a.md")
    end

    test "refuses a path that is not UTF-8" do
      assert Text.letter("platform", "/r/\xFF.md") == :error
    end
  end
end
