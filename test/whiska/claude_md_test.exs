defmodule Whiska.ClaudeMdTest do
  use ExUnit.Case, async: true

  alias Whiska.ClaudeMd

  describe "parts/0 — the block is a nest of named parts (ADR-0045)" do
    test "ships the worktree protocol in four separately-replaceable parts" do
      assert Enum.map(ClaudeMd.parts(), & &1.name) == ~w(worktrees marker delivery report)
    end

    test "every part is wrapped in its own named markers" do
      for part <- ClaudeMd.parts() do
        assert part.body =~ "<!-- whiska:#{part.name}:start -->", part.name
        assert part.body =~ "<!-- whiska:#{part.name}:end -->", part.name
      end
    end

    test "a marker sits alone on its line, so a whole line can be matched" do
      for part <- ClaudeMd.parts(),
          line <- String.split(part.body, "\n"),
          line =~ "whiska:" do
        assert line =~ ~r/\A<!-- whiska:[a-z-]+:(start|end)( keep)? -->\z/, line
      end
    end
  end

  describe "render/0 — the whole block" do
    test "wraps every part in the outer markers" do
      rendered = ClaudeMd.render()

      assert rendered =~ "<!-- whiska:start -->"
      assert rendered =~ "<!-- whiska:end -->"

      for part <- ClaudeMd.parts() do
        assert rendered =~ part.body, part.name
      end
    end

    test "the outer markers really do enclose every part" do
      rendered = ClaudeMd.render()
      [_, inside] = String.split(rendered, "<!-- whiska:start -->", parts: 2)
      [inside, _] = String.split(inside, "<!-- whiska:end -->", parts: 2)

      for part <- ClaudeMd.parts(), do: assert(inside =~ part.body, part.name)
    end
  end

  describe "the worktrees part" do
    test "checks for an existing worktree before anything else, grilling included" do
      body = body_of("worktrees")

      assert body =~ "herdr worktree list"
      assert body =~ "send-to-worktree"
      assert body =~ "spawn-worktree"
      assert body =~ "drop-worktree"
      # The whole point of the decision tree: the main session neither grills nor
      # reads code before the mouse exists.
      assert body =~ ~r/before anything else/i
      assert body =~ "HERDR_ENV=1"
    end

    test "sends the grilling into the worktree, not the main session" do
      body = body_of("worktrees")

      assert body =~ "grill"
      assert body =~ ~r/frontend/i
    end
  end

  describe "the marker part" do
    test "spells both values exactly as Whiska parses them" do
      body = body_of("marker")

      assert body =~ "[worktree-status: done]"
      assert body =~ "[worktree-status: needs-decision]"
      assert body =~ "last line"
    end

    test "says the main session never writes one" do
      assert body_of("marker") =~ ~r/main session never/i
    end

    test "agrees with the marker Whiska actually parses" do
      body = body_of("marker")

      for status <- [:done, :needs_decision] do
        assert body =~ Whiska.Question.Marker.render(status), inspect(status)
      end
    end
  end

  describe "the delivery part" do
    test "names the commands the person actually types" do
      body = body_of("delivery")

      assert body =~ "whiska questions <id>"
      assert body =~ "whiska reply <id>"
      assert body =~ "whiska doctor"
    end

    test "forbids reading a mouse's pane, and says why" do
      body = body_of("delivery")

      assert body =~ "herdr pane read"
      assert body =~ "alternate screen"
    end

    test "uses the repo's own words for what is going on" do
      body = body_of("delivery")

      for word <- ~w(mouse doorstep owl) do
        assert body =~ word, word
      end
    end

    test "the answer goes through whiska reply and nothing else" do
      body = body_of("delivery")

      # Typing the answer straight into a mouse's pane leaves the question
      # `sent`, so it holds ADR-0008's one delivery slot and the next mouse
      # waits behind a question nobody is going to close.
      assert body =~ "herdr agent prompt"
      assert body =~ "send-to-worktree"
      assert body =~ "frees the slot"
    end
  end

  describe "the report part" do
    test "teaches the shape of the message, step by step" do
      body = body_of("report")

      assert body =~ ~r/what is true now/i
      assert body =~ ~r/where it lives/i
      assert body =~ ~r/verified, not assumed/i
      assert body =~ ~r/one thing worth knowing/i
      assert body =~ "Nothing is waiting on you"
    end

    test "says the message is a report, in outcomes, not a status dump" do
      body = body_of("report")

      assert body =~ ~r/outcomes, not mechanics/i
      assert body =~ ~r/short sentences/i
      # Never paste the runner's tail; read it and send what it means.
      assert body =~ ~r/tool output/i
    end

    test "keeps every question and option in the body, where delivery stores it" do
      report = body_of("report")

      assert report =~ "every option"
      assert report =~ "recommendation"
      # Said once, in the part that teaches the shape — not twice (ADR-0045).
      refute body_of("delivery") =~ "every option"
    end

    test "forbids Whiska's own words in the message, and excepts the marker" do
      body = prose_of("report")

      for word <- ["mouse", "owl", "house", "doorstep", "delivery slot"] do
        assert body =~ word, word
      end

      assert body =~ ~r/never appears/i
      assert body =~ ~r/marker line is the one exception/i
    end

    test "asks for the person's word only when a decision is genuinely needed" do
      assert prose_of("report") =~ ~r/review, approval, merge or design pick/i
    end
  end

  describe "merge/1 — idempotent per part (ADR-0045)" do
    test "an empty file gets the whole block, and one trailing newline" do
      assert ClaudeMd.merge("") == ClaudeMd.render() <> "\n"
    end

    test "a file with no block keeps its own text and gains the block" do
      existing = "# My project\n\nSome rules of my own.\n"
      merged = ClaudeMd.merge(existing)

      assert String.starts_with?(merged, existing)
      assert merged =~ ClaudeMd.render()
    end

    test "re-running changes nothing" do
      once = ClaudeMd.merge("# My project\n")
      assert ClaudeMd.merge(once) == once
    end

    test "replaces one stale part in place and touches no other" do
      stale =
        ClaudeMd.render()
        |> String.replace(body_of("marker"), """
        <!-- whiska:marker:start -->
        ## Worktree status marker

        Something old and wrong.
        <!-- whiska:marker:end -->\
        """)

      merged = ClaudeMd.merge(stale)

      refute merged =~ "Something old and wrong."
      assert merged =~ body_of("marker")
      assert merged =~ body_of("worktrees")
      assert merged =~ body_of("delivery")
    end

    test "preserves the person's own text outside the block, before and after" do
      before_text = "# My project\n\nMine, above.\n\n"
      after_text = "\n\n## Mine, below\n\nAlso mine.\n"
      merged = ClaudeMd.merge(before_text <> ClaudeMd.render() <> after_text)

      assert String.starts_with?(merged, before_text)
      assert String.ends_with?(merged, after_text)
    end

    test "preserves a person's own prose sitting between two parts" do
      theirs = "\n\nA note of mine, inside the block.\n\n"

      merged =
        ClaudeMd.render()
        |> String.replace(
          body_of("marker") <> "\n\n",
          body_of("marker") <> theirs
        )
        |> ClaudeMd.merge()

      assert merged =~ "A note of mine, inside the block."
    end

    test "a file with only the older parts gains the newest one, untouched neighbours" do
      # What a person's CLAUDE.md looks like the run before a new part ships.
      older = Enum.reject(ClaudeMd.parts(), &(&1.name == "report"))

      before_report =
        ClaudeMd.render() |> String.replace("\n\n" <> body_of("report"), "")

      refute before_report =~ "whiska:report:start"

      merged = ClaudeMd.merge(before_report)

      assert merged =~ body_of("report")
      for part <- older, do: assert(merged =~ part.body, part.name)
      # And in the order Whiska ships, with the new part last inside the block.
      assert String.split(merged, "<!-- whiska:end -->") |> hd() =~ body_of("report")
    end

    test "adds a part whose markers are missing entirely" do
      # Delivery is not the last part, so its own trailing blank line goes with it.
      without_delivery =
        ClaudeMd.render() |> String.replace(body_of("delivery") <> "\n\n", "")

      refute without_delivery =~ "whiska:delivery:start"

      merged = ClaudeMd.merge(without_delivery)
      assert merged =~ body_of("delivery")
      # And still inside the outer block, not trailing off the end of the file.
      [_, inside] = String.split(merged, "<!-- whiska:start -->", parts: 2)
      [inside, _] = String.split(inside, "<!-- whiska:end -->", parts: 2)
      assert inside =~ body_of("delivery")
    end

    test "a part marked keep is left exactly alone" do
      kept =
        ClaudeMd.render()
        |> String.replace(body_of("worktrees"), """
        <!-- whiska:worktrees:start keep -->
        ## My own worktree rules

        Mine, and Whiska does not get to rewrite them.
        <!-- whiska:worktrees:end -->\
        """)

      merged = ClaudeMd.merge(kept)

      assert merged =~ "Mine, and Whiska does not get to rewrite them."
      refute merged =~ "herdr worktree list"
      # The other parts still update.
      assert merged =~ body_of("marker")
    end

    test "a part dropped to nothing but keeping its markers stays dropped when kept" do
      dropped =
        ClaudeMd.render()
        |> String.replace(
          body_of("delivery"),
          "<!-- whiska:delivery:start keep -->\n<!-- whiska:delivery:end -->"
        )

      merged = ClaudeMd.merge(dropped)

      refute merged =~ "whiska reply <id>"
      assert merged =~ "<!-- whiska:delivery:start keep -->"
    end

    test "leaves a part Whiska no longer ships exactly where it is" do
      retired = """
      <!-- whiska:nudge:start -->
      ## Nudges

      A part from an older Whiska.
      <!-- whiska:nudge:end -->\
      """

      merged =
        ClaudeMd.render()
        |> String.replace("<!-- whiska:end -->", retired <> "\n<!-- whiska:end -->")
        |> ClaudeMd.merge()

      assert merged =~ retired
    end

    test "never writes a second outer block" do
      merged = ClaudeMd.merge(ClaudeMd.merge("# Mine\n"))
      assert length(String.split(merged, "<!-- whiska:start -->")) == 2
    end

    test "ends with exactly one newline" do
      for input <- ["", "# Mine", "# Mine\n", "# Mine\n\n\n"] do
        assert String.ends_with?(ClaudeMd.merge(input), "\n")
        refute String.ends_with?(ClaudeMd.merge(input), "\n\n")
      end
    end
  end

  defp body_of(name) do
    Enum.find(ClaudeMd.parts(), &(&1.name == name)).body
  end

  # A phrase the part teaches can fall across a line break, and where it wraps is
  # not the behaviour under test.
  defp prose_of(name) do
    name |> body_of() |> String.replace(~r/\s+/, " ")
  end
end
