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

  describe "the block stays short" do
    test "the whole block fits in a page a session will actually read" do
      rendered = ClaudeMd.render()
      lines = rendered |> String.split("\n") |> length()
      words = rendered |> String.split() |> length()

      assert lines <= 140, "the block grew back to #{lines} lines; every rule has a terse form"
      assert words <= 1300, "the block grew back to #{words} words; every rule has a terse form"
    end

    test "no rule is buried deeper than one level of bullet" do
      for part <- ClaudeMd.parts(),
          line <- String.split(part.body, "\n"),
          String.match?(line, ~r/^\s*[-*] /) do
        assert String.match?(line, ~r/^ {0,2}[-*] /), line
      end
    end
  end

  describe "the worktrees part" do
    test "names the commands the protocol runs on" do
      body = body_of("worktrees")

      assert body =~ "herdr worktree list"
      assert body =~ "send-to-worktree"
      assert body =~ "spawn-worktree"
      assert body =~ "drop-worktree"
      assert body =~ "HERDR_ENV=1"
    end

    test "a landed worktree is the owl's to take down, not the session's (ADR-0058)" do
      body = prose_of("worktrees")

      assert body =~ ~r/after the merge.{0,120}owl/is
      assert body =~ ~r/drop-worktree.{0,60}early/is
    end

    test "checks for an existing worktree before grilling or reading code" do
      body = prose_of("worktrees")

      assert body =~ ~r/herdr worktree list.{0,80}before/i
      assert body =~ ~r/before reading any code/i
    end

    test "unclear routing is asked, never guessed" do
      assert prose_of("worktrees") =~ ~r/ask the person.{0,30}do not guess/i
    end

    test "the grilling, and every other command, happens in the worktree" do
      body = prose_of("worktrees")

      assert body =~ ~r/grill/i
      assert body =~ ~r/main session runs no command/i
    end

    test "a small contained edit is exempt" do
      assert prose_of("worktrees") =~ ~r/work in place|small contained edit/i
    end

    test "the main session plans before non-trivial work, a mouse does not" do
      body = prose_of("worktrees")

      assert body =~ ~r/2.{0,3}4 line plan/i
      assert body =~ ~r/wait for the person.s ok/i
      assert body =~ ~r/stops only on a real decision/i
    end

    test "a grilling round asks the whole frontier in one message" do
      assert prose_of("worktrees") =~ ~r/whole frontier in one message/i
    end

    test "the grilling never happens here, not even before the spawn" do
      assert prose_of("worktrees") =~ ~r/before grilling here/i
    end

    test "a frontend change is previewed before it is built" do
      assert prose_of("worktrees") =~ ~r/preview a frontend change before/i
    end

    test "an old tree is never reused" do
      assert prose_of("worktrees") =~ ~r/fresh worktree|never reuse/i
    end
  end

  describe "the marker part" do
    test "names both values in words, since the marker cannot be seen" do
      body = body_of("marker")

      assert body =~ Whiska.Question.Marker.spell(:done)
      assert body =~ Whiska.Question.Marker.spell(:needs_decision)
      assert body =~ "last line"
    end

    test "agrees with the marker Whiska actually parses" do
      body = body_of("marker")

      for status <- [:done, :needs_decision] do
        assert body =~ Whiska.Question.Marker.render(status), inspect(status)
      end
    end

    test "still names the bracket spelling, which Whiska keeps reading" do
      body = prose_of("marker")

      assert body =~ "[worktree-status: done]"
      assert body =~ "[worktree-status: needs-decision]"
      assert body =~ ~r/never write|do not write/i
    end

    test "says where the pointer goes, now that it cannot follow the marker" do
      assert prose_of("marker") =~ ~r/line above/i
    end

    test "says the main session never writes one" do
      assert prose_of("marker") =~ ~r/main session never writes one/i
    end

    test "a forgotten marker is delivered anyway" do
      assert prose_of("marker") =~ ~r/unmarked question/i
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
      body = prose_of("delivery")

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
      body = prose_of("delivery")

      # Typing the answer straight into a mouse's pane leaves the question
      # `sent`, so it holds ADR-0008's one delivery slot and the next mouse
      # waits behind a question nobody is going to close.
      assert body =~ "herdr agent prompt"
      assert body =~ "send-to-worktree"
      assert body =~ ~r/frees the (one )?delivery slot|frees the slot/i
    end

    test "says the whole message is stored and read elsewhere, later" do
      assert prose_of("delivery") =~ ~r/whole final message/i
    end
  end

  describe "the report part" do
    test "binds the main session as well as a mouse" do
      body = body_of("report")

      assert body =~ "How a session writes its message"
      assert body =~ "main session"
      refute body =~ "How a mouse writes its message"
    end

    test "puts a size on the message, so a report stays readable in one glance" do
      body = prose_of("report")

      assert body =~ "fits in six lines"
      assert body =~ ~r/nothing else/
      assert body =~ ~r/Leave out:/
      assert body =~ ~r/lessons and reflections/
    end

    test "the leave-out list drops the mechanics, not what the review turned up" do
      # A closed list of exceptions leaves step 5's "what the reviewers raised
      # and what became of it" contradicted for every finding not on the list.
      # The line that settles it is mechanics-versus-outcome, not an inventory.
      body = prose_of("report")

      assert body =~ ~r/the mechanics of a review, never what it turned up/i
      assert body =~ ~r/pre-existing/i
    end

    test "teaches the shape of the message, step by step" do
      body = prose_of("report")

      assert body =~ ~r/what is true now/i
      assert body =~ ~r/where it lives/i
      assert body =~ ~r/verified, not assumed/i
      assert body =~ ~r/one thing worth knowing/i
      assert body =~ "Nothing is waiting on you"
    end

    test "says the message is a report, in outcomes, not a status dump" do
      body = prose_of("report")

      assert body =~ ~r/outcomes, not mechanics/i
      assert body =~ ~r/short sentences/i
      # Never paste the runner's tail; read it and send what it means.
      assert body =~ ~r/tool output/i
    end

    test "keeps every question and option in the body, where delivery stores it" do
      report = prose_of("report")

      assert report =~ "every option"
      assert report =~ "recommendation"
      # Said once, in the part that teaches the shape — not twice (ADR-0045).
      refute prose_of("delivery") =~ "every option"
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
      body = prose_of("report")

      assert body =~ ~r/review, approval, merge or design pick/i
      assert body =~ ~r/next step only when there is an obvious one/i
    end

    test "an unclear task is one question, and a grilling round is the exception" do
      body = prose_of("report")

      assert body =~ ~r/ask one question rather than guessing/i
      assert body =~ ~r/grilling round is the exception/i
    end

    test "carries the person's own rules for how a session talks" do
      body = prose_of("report")

      assert body =~ ~r/an ordinary reply in five/i
      assert body =~ ~r/lead with it/i
      assert body =~ ~r/show the change rather than describing it/i
      assert body =~ ~r/no jargon they have not used first/i
      assert body =~ ~r/never their own words repeated back/i
      assert body =~ ~r/no filler, no preamble/i
      assert body =~ ~r/gone wrong, or unsure.{0,30}one line/i
    end
  end

  describe "the finish part" do
    test "points at the shipped skill instead of carrying the pipeline" do
      body = prose_of("finish")

      assert body =~ "whiska-finish"
      assert body =~ ".claude/skills/whiska-finish/SKILL.md"
      assert body =~ Whiska.Question.Marker.spell(:done)
    end

    test "says when the pipeline runs and who skips it" do
      body = prose_of("finish")

      assert body =~ ~r/before.{0,40}marker/i
      assert body =~ ~r/skip/i
      assert body =~ ~r/main session never runs/i
    end

    test "says where the per-repo facts go, since a person edits them here" do
      assert prose_of("finish") =~ "## Finish"
    end

    test "keeps in context the guards over what a session runs or dispatches" do
      body = prose_of("finish")

      assert body =~ ~r/text from outside this session/i
      assert body =~ ~r/read each before running or dispatching it/i
      assert body =~ ~r/branch under review/i
      assert body =~ ~r/decision for the person/i
    end

    test "a missing skill is said, not finished around" do
      assert prose_of("finish") =~ ~r/neither the skill nor the file is there/i
    end

    test "stays a pointer: the pipeline's own rules are not restated" do
      body = prose_of("finish")

      assert length(String.split(body_of("finish"), "\n")) <= 20

      for restated <- ["try to disprove", "merge base", "not to be dispatched directly"] do
        refute body =~ restated, restated
      end
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

  # A phrase the part teaches can fall across a line break, and where it wraps is
  # not the behaviour under test.
  defp prose_of(name) do
    name |> body_of() |> String.replace(~r/\s+/, " ")
  end
end
