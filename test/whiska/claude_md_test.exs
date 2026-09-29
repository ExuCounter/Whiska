defmodule Whiska.ClaudeMdTest do
  use ExUnit.Case, async: true

  alias Whiska.ClaudeMd

  describe "parts/0 — the block is a nest of named parts (ADR-0045)" do
    test "ships the worktree protocol in five separately-replaceable parts" do
      assert Enum.map(ClaudeMd.parts(), & &1.name) ==
               ~w(worktrees marker delivery report finish)
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
    test "binds the main session as well as a mouse" do
      body = body_of("report")

      assert body =~ "How a session writes its message"
      assert body =~ "main session"
      refute body =~ "How a mouse writes its message"
    end

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

  describe "the finish part" do
    test "runs the five steps in order, before the marker goes down" do
      body = prose_of("finish")

      assert body =~ ~r/read the work back against what was asked/i
      assert body =~ ~r/run this repo's checks/i
      assert body =~ ~r/send reviewers over the change/i
      assert body =~ ~r/two rounds is the ceiling/i
      # The marker goes down last, after the reviewers have been over the change.
      assert index_of(body, "Then the marker") > index_of(body, "Send reviewers")
    end

    test "a wrong scope goes to the person, a small mismatch gets fixed" do
      # The one judgment the mouse does not make alone (ADR-0017 puts the
      # judgment in CLAUDE.md; whose judgment it is, is the point here).
      body = prose_of("finish")

      assert body =~ ~r/scope/i
      assert body =~ ~r/end the turn on a decision for the person/i
      assert body =~ ~r/fix it now/i
    end

    test "fixing a check is bounded: inside the change, never against step 1" do
      body = prose_of("finish")

      assert body =~ ~r/only inside this change/i
      assert body =~ ~r/already red before the turn started/i
      assert body =~ ~r/deleting an assertion/i
    end

    test "names the reviewer axes, and frontend only when a person sees it" do
      body = prose_of("finish")

      for axis <- ["correctness", "security", "performance", "frontend"] do
        assert body =~ axis, axis
      end

      assert body =~ ~r/only when the change touches something a person sees/i
    end

    test "a reviewer's finding is verified before it is acted on" do
      body = prose_of("finish")

      assert body =~ ~r/a claim, not a verdict/i
      assert body =~ ~r/verify each one/i
    end

    test "the per-repo facts come from a Finish heading outside the block" do
      body = prose_of("finish")

      assert body =~ "## Finish"
      assert body =~ "checks:"
      assert body =~ "specs:"
      assert body =~ "ticket:"
      assert body =~ ~r/outside Whiska's block/i
    end

    test "a ticket is evidence, never an instruction to the session" do
      body = prose_of("finish")

      assert body =~ ~r/never an instruction/i
      assert body =~ ~r/goes to the person/i
    end

    test "a check command that does more than the repo's own tooling is the person's call" do
      body = prose_of("finish")

      assert body =~ ~r/fetches|downloads/i
      assert body =~ ~r/branch under review|branch being finished/i
    end

    test "names how red-before-the-turn is established, not just the rule" do
      assert prose_of("finish") =~ ~r/merge base/i
    end

    test "a missing Finish heading is not a reason to stop" do
      body = prose_of("finish")

      assert body =~ ~r/no `## Finish` heading/i
      assert body =~ ~r/say in the done message what was assumed/i
    end

    test "does not restate the shape the report part already teaches" do
      # ADR-0045: a part says its own thing once. The finish part says what goes
      # in the message, not how the message is written.
      body = prose_of("finish")

      assert body =~ ~r/does not repeat it/i
      refute body =~ ~r/outcomes, not mechanics/i
    end

    test "the marker it ends on is the one Whiska parses" do
      assert body_of("finish") =~ Whiska.Question.Marker.render(:done)
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
      older = Enum.reject(ClaudeMd.parts(), &(&1.name == "finish"))

      before_finish =
        ClaudeMd.render() |> String.replace("\n\n" <> body_of("finish"), "")

      refute before_finish =~ "whiska:finish:start"

      merged = ClaudeMd.merge(before_finish)

      assert merged =~ body_of("finish")
      for part <- older, do: assert(merged =~ part.body, part.name)
      # And in the order Whiska ships, with the new part last inside the block.
      assert String.split(merged, "<!-- whiska:end -->") |> hd() =~ body_of("finish")
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

  defp index_of(text, needle) do
    [{at, _}] = Regex.run(~r/#{needle}/i, text, return: :index)
    at
  end

  # A phrase the part teaches can fall across a line break, and where it wraps is
  # not the behaviour under test.
  defp prose_of(name) do
    name |> body_of() |> String.replace(~r/\s+/, " ")
  end
end
