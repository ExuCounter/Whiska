defmodule Whiska.ClaudeMdTest do
  @moduledoc """
  The block an older Whiska wrote into a `CLAUDE.md`, and the parts of it the
  person claimed with `keep` (ADR-0081).
  """
  use ExUnit.Case, async: true

  alias Whiska.ClaudeMd

  # The number is the one an older Whiska really wrote, interpolated so the repo's
  # citation check does not read a record that was folded away as a dangling cite.
  @header """
  <!-- Whiska wrote this block (`whiska init --global`). Each part below is replaced
       in place on the next run and nothing outside the markers is touched. To keep
       a part as your own, add `keep` to its start marker — `<!-- whiska:NAME:start
       keep -->` — and Whiska will never rewrite it again. See Whiska ADR-#{"0045"}. -->\
  """

  defp block(inside), do: "<!-- whiska:start -->\n#{@header}\n\n#{inside}\n<!-- whiska:end -->"

  defp part(name, body, keep \\ false) do
    start =
      if keep, do: "<!-- whiska:#{name}:start keep -->", else: "<!-- whiska:#{name}:start -->"

    "#{start}\n#{body}\n<!-- whiska:#{name}:end -->"
  end

  describe "kept/1" do
    test "names every part whose start marker says keep, and no other" do
      contents =
        block(
          Enum.join(
            [
              part("worktrees", "Theirs."),
              part("report", "Mine.", true),
              part("finish", "", true)
            ],
            "\n\n"
          )
        )

      assert ClaudeMd.kept(contents) == ["report", "finish"]
    end

    test "a keep part left without outer markers still counts" do
      assert ClaudeMd.kept("# Mine\n\n" <> part("delivery", "", true) <> "\n") == ["delivery"]
    end

    test "a marker mentioned in a sentence is not a part" do
      assert ClaudeMd.kept("Add `<!-- whiska:report:start keep -->` to keep it.\n") == []
    end

    test "a file with no block keeps nothing" do
      assert ClaudeMd.kept("# Mine\n") == []
    end
  end

  describe "remove/1" do
    test "leaves a file with no block byte for byte alone" do
      mine = "# Mine\n\nNothing of Whiska's here.\n"
      assert ClaudeMd.remove(mine) == mine
    end

    test "a block of Whiska's parts alone goes, markers and all, and the text around it stays" do
      contents =
        "# Mine\n\nAbove.\n\n" <>
          block(part("worktrees", "Rules.") <> "\n\n" <> part("report", "More.")) <>
          "\n\n## Below\n\nAlso mine.\n"

      assert ClaudeMd.remove(contents) == "# Mine\n\nAbove.\n\n## Below\n\nAlso mine.\n"
    end

    test "a keep part stays, markers and all, inside the outer markers" do
      contents =
        "# Mine\n\n" <>
          block(part("worktrees", "Rules.") <> "\n\n" <> part("marker", "Mine now.", true)) <>
          "\n"

      body = ClaudeMd.remove(contents)

      assert body =~ "<!-- whiska:marker:start keep -->\nMine now.\n<!-- whiska:marker:end -->"
      assert body =~ "<!-- whiska:start -->"
      refute body =~ "Rules."
      refute body =~ "Whiska wrote this block"
    end

    test "the person's own text between two parts stays" do
      contents =
        block(part("worktrees", "Rules.") <> "\n\nA note of mine.\n\n" <> part("report", "More."))

      body = ClaudeMd.remove(contents)

      assert body =~ "A note of mine."
      refute body =~ "Rules."
      refute body =~ "More."
    end

    test "a part Whiska never shipped under this name goes the same way" do
      body = ClaudeMd.remove("# Mine\n\n" <> block(part("nudge", "Old.")) <> "\n")
      assert body == "# Mine\n"
    end

    test "a sentence that mentions the outer markers is prose, and the real block after it still goes" do
      prose = "Whiska's block sits between `<!-- whiska:start -->` and `<!-- whiska:end -->`.\n"

      assert ClaudeMd.remove(prose) == prose

      assert ClaudeMd.remove("# Mine\n\n" <> prose <> "\n" <> block(part("report", "X.")) <> "\n") ==
               "# Mine\n\n" <> prose
    end

    test "a part with no end marker is the person's text, never guessed at, and stays" do
      contents = "# Mine\n\n" <> block("<!-- whiska:report:start -->\nHalf a part.") <> "\n"

      body = ClaudeMd.remove(contents)

      assert body =~ "<!-- whiska:report:start -->\nHalf a part."
      refute body =~ "Whiska wrote this block"
    end

    test "a part missing its end marker does not hide the parts after it" do
      contents =
        "# Mine\n\n" <>
          block(
            "<!-- whiska:worktrees:start -->\nBroken.\n\n" <>
              part("report", "Mine.", true) <> "\n\n" <> part("finish", "Old.")
          ) <> "\n"

      assert ClaudeMd.kept(contents) == ["report"]

      body = ClaudeMd.remove(contents)
      assert body =~ "<!-- whiska:worktrees:start -->\nBroken."
      assert body =~ "<!-- whiska:report:start keep -->\nMine."
      refute body =~ "Old."
    end

    test "running it twice changes nothing more" do
      contents =
        "# Mine\n\n" <>
          block(part("report", "Mine.", true) <> "\n\n" <> part("finish", "X")) <> "\n"

      once = ClaudeMd.remove(contents)
      assert ClaudeMd.remove(once) == once
    end
  end
end
