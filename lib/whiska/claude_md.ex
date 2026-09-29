defmodule Whiska.ClaudeMd do
  @moduledoc """
  The block `whiska init` writes into a project's own `CLAUDE.md`.

  ADR-0017 puts every piece of judgment in `CLAUDE.md` and keeps Whiska dumb, and
  said from the start that `whiska init` writes "a marked block" there. This is
  that block. What it carries is the protocol between herdr, Whiska and Claude:
  how a mouse gets spawned, what marker it ends a turn with, how its question
  reaches the person, and the shape the message it writes takes. Those rules used to
  live in one person's global `~/.claude/CLAUDE.md`, where they applied to every repo
  whether or not Whiska was anywhere near it, and where nothing kept them in step
  with the code that actually parses the marker. Now the one thing that owns the
  protocol ships it.

  ## The block is a nest of named parts

  ADR-0045 is the grammar. One outer `<!-- whiska:start -->` … `<!-- whiska:end
  -->` pair bounds what Whiska will touch at all, and inside it each part carries
  its own named pair — `<!-- whiska:worktrees:start -->` and so on. A part with
  `keep` on its start marker is the person's from then on, and `init` reads
  straight past it.

  Everything here is a pure value except the write itself, so the merge — what
  gets replaced, what gets added, what is left exactly alone — is testable
  without a filesystem, the same way `Whiska.Install` is.
  """

  alias Whiska.Question.Marker

  @outer_start "<!-- whiska:start -->"
  @outer_end "<!-- whiska:end -->"

  # A start marker, with the optional `keep` that makes the part the person's.
  # Anchored to whole lines: a marker is always alone on its own line, so a
  # sentence in prose that happens to mention one is never mistaken for one.
  @part_start ~r/^<!-- whiska:([a-z-]+):start( keep)? -->$/m

  @header """
  <!-- whiska:start -->
  <!-- Whiska wrote this block (`whiska init`). Each part below is replaced in
       place on the next run and nothing outside the markers is touched. To keep
       a part as your own, add `keep` to its start marker — `<!-- whiska:NAME:start
       keep -->` — and Whiska will never rewrite it again. See Whiska ADR-0045. -->\
  """

  @worktrees """
  <!-- whiska:worktrees:start -->
  ## Worktrees

  When the person describes a real feature or fix — one that touches several files or
  takes more than a few minutes — the work goes to a mouse, not to this session.

  1. **Check for an existing worktree first — before anything else, grilling included.**
     Run `herdr worktree list` right away. git cannot have two worktrees on one branch
     anyway, so the real question is whether this idea continues a feature a mouse is
     already building (a sub-part, refinement or follow-up that would ship on the same
     branch and PR) or is a separate, independently-shippable unit of work.
     - Continues an existing worktree → use `send-to-worktree` to route the raw idea
       into that mouse right now. Let it grill the person further if it needs to; do
       not grill here first, and do not read any code here first.
     - A separate unit of work, or nothing running matches → step 2.
     - Unclear which → ask the person directly, do not guess.
  2. **Spawn the worktree immediately** with `spawn-worktree` — before anything else,
     even before reading any code, and even when the brief is still vague. Do not grill
     in the main session first: a thin brief is not a reason to keep this terminal
     busy. Whatever branch name the raw request suggests will do; it need not be final.
  3. **If the brief is thin, grill from inside the worktree.** The mouse does that, not
     this session — what "done" looks like, which part of the app, what data it uses,
     the edge cases — and ends each round with the worktree-status marker, so the
     question reaches the person the way every other one does. All the investigation
     happens there too, not just the eventual edits, so the main session never runs a
     single command for this task and stays free for something else.
  4. **A frontend change gets previewed before it gets built.** That happens in the
     worktree too, and the response body and its marker carry the link to the preview.

  This applies whenever `HERDR_ENV=1`. Outside a herdr session `spawn-worktree`'s own
  preconditions refuse, so grill and work in the current checkout instead. Skip steps 2
  and 3 for a small contained edit — a one-line config tweak, a quick question that
  turns into a quick fix — or when the person says to work in place.

  Once the work is merged, `drop-worktree` cleans up. The next mouse gets a fresh
  worktree off the latest base branch; an old tree is never reused.
  <!-- whiska:worktrees:end -->\
  """

  @marker """
  <!-- whiska:marker:start -->
  ## Worktree status marker

  A mouse — a session running inside a spawned or routed worktree, never the person's
  main session — ends every response with one plain marker line, so what happened is on
  the record rather than guessed from a screen-detected idle state. Whiska reads exactly
  this marker to classify the turn, so the spelling matters:

  - `#{Marker.render(:done)}` — the task is fully finished and nothing is needed from
    the person.
  - `#{Marker.render(:needs_decision)} <a short pointer, in one line>` — stopping
    because only the person can decide something. A single short question goes right
    there. A grilling round with several questions says something like "3 questions
    ready, see above" and leaves the questions themselves in the response body.

  Always the last line, always exactly one of the two. The main session never writes one
  — only a mouse does. A turn that forgets it is delivered anyway, as an unmarked
  question, which is the loud direction on purpose.
  <!-- whiska:marker:end -->\
  """

  @delivery """
  <!-- whiska:delivery:start -->
  ## How a mouse's question reaches the person

  A mouse leaves its whole final message on this house's doorstep. The owl collects it
  and delivers a one-line pointer into the main session — once the repo has been
  `whiska init`-ed, the owl is running, and a main session is recorded; `whiska doctor`
  says which of those is missing. The person reads the message with
  `whiska questions <id>` and answers it with `whiska reply <id>`.

  So the whole final message is what gets stored, and the person reads it later, from a
  different terminal, with none of this session's scrollback. How to write one that
  survives that is the next part.

  Never ask the main session to read a mouse's pane, and never expect it to. Claude Code
  runs on the terminal's alternate screen, so `herdr pane read` comes back with a
  truncated tail no matter what `--lines` it is given. Storing the whole message is what
  makes that irrelevant.

  And one rule for the main session: the answer to a delivered question leaves it as
  `whiska reply <id>` and no other way. Never type it into the mouse's pane with
  `herdr agent prompt`, and never send it with `send-to-worktree` — that is for a new
  idea, not for something a mouse is already waiting on. The mouse would read it either
  way, but the question would stay `sent` and keep holding the one delivery slot, so the
  next mouse's question sits unread behind it. Only `whiska reply` closes the question
  and frees the slot. Talking it over with the person first is fine; when that talk
  produces something for the mouse, it goes out as the reply.
  <!-- whiska:delivery:end -->\
  """

  @report """
  <!-- whiska:report:start -->
  ## How a mouse writes its message

  The final message is a report to the person, not a status dump. It is the only thing
  they see of the whole turn, and they see it later and somewhere else, so it carries
  every fact that matters and assumes nothing they could only get from the scrollback.

  Write it in this order, dropping any line that has nothing to say:

  1. **One line saying what is true now.** The outcome, not the activity — "the search
     box filters as you type", not "implemented filtering".
  2. **Where it lives** — the branch, the files — but only when the person has to go
     there to look or to carry on.
  3. **What it does, or what changed**, in their terms: what the thing can do now that
     it could not before.
  4. **Verified, not assumed.** What was run and what came back — the tests, the app,
     the command end to end. If it was not run, say so plainly and say why. Never call
     something working on the strength of having written it.
  5. **One thing worth knowing**, and only if there is one: a surprise, a constraint, a
     choice they would want to know was made.
  6. **Either "Nothing is waiting on you"** or the one decision — spelled out with its
     options, the trade-off, and a recommendation.

  Every question, every option, every recommendation goes in that body, in full. The
  marker line is only the pointer to it.

  Rules that hold throughout:

  - **Outcomes, not mechanics.** What the person can now do, not what the session did
    to get there. No retries, no routine progress, no fix that fixed itself.
  - **Never paste tool output or a status line.** Read it as evidence and send what it
    means: "31 tests pass, no failures", not the runner's tail.
  - **Their words, not Whiska's.** Whiska's own vocabulary — mouse, owl, house,
    doorstep, collection, delivery slot, and the status labels themselves — never
    appears in the message. Say "this branch" or "the isolated copy", not "the mouse";
    name the concrete decision, not "needs-decision". The marker line is the one
    exception, and it is stripped out before the person reads the message.
  - **Ask for their word only** when the next step really needs a review, approval,
    merge or design pick. Otherwise say nothing is waiting, and stop.
  - **Short sentences. No headers unless the message is long.** Do not restate the task
    and do not narrate the steps taken.

  Where this repo's other instructions already say to open with a recap, keep a
  question self-contained, or raise one decision at a time, they still hold — this part
  does not repeat them.
  <!-- whiska:report:end -->\
  """

  @finish """
  <!-- whiska:finish:start -->
  ## Before a turn is done

  A turn about to end on `#{Marker.render(:done)}` has one more piece of work in it:
  showing that it is done. These five steps, in order, in the mouse's own session,
  before the marker goes down. A turn ending on a decision for the person skips all of
  it — that turn is waiting on them, not claiming to be finished — and the person's main
  session never runs it at all.

  1. **Read the work back against what was asked.** The brief that started the turn, the
     ticket it names, and whatever this repo writes down: its specs, its glossary, its
     recorded decisions. Three different outcomes come out of that reading. Something
     contradicts a written decision, or the brief asked for a piece that is not there →
     fix it now. The work is right and the written decision is the thing that is out of
     date → change the decision too, in this same piece of work, if the repo's own rules
     say that is how it goes. The scope itself is wrong — what was asked turns out to be
     the wrong thing, or larger than the brief admits → stop and end the turn on a
     decision for the person. Scope is the one judgment not to make alone.
  2. **Run this repo's checks, and fix what fails.** Tests, linter, type checker,
     formatter — whatever this repo names; the last section says where that is written
     down. Fix the failures without asking, because they are this turn's own mess. Two
     limits on that, and they matter more than the fixing. **Only inside this change**:
     something already red before the turn started is the person's to hear about, not
     the mouse's to quietly rewrite. And **never a fix that contradicts step 1**: a check
     made to pass by deleting an assertion, loosening a type or skipping a case is a
     check that was not passed.
  3. **Send reviewers over the change.** Subagents in parallel, one per axis, each
     reading the real diff and reporting what it finds rather than changing anything:
     - **correctness** — against the brief, the specs and the recorded decisions.
     - **security** — this change's own surface: input it trusts, secrets, access it
       widens, what it writes to a log.
     - **performance** — what it makes slower or heavier, at the scale this repo
       actually runs at.
     - **frontend** — only when the change touches something a person sees: keyboard
       and screen-reader access, empty and error states, small screens, and whatever
       design language the repo already has.

     A reviewer's finding is a claim, not a verdict. Verify each one against the code
     before acting on it and drop the ones that do not survive, because a confident
     subagent is still a subagent. Fix what is real, under step 2's two limits.
  4. **Round two, then stop.** Every fix made in step 2 or 3 sends the turn back to
     step 2, so the checks see it. Two rounds is the ceiling. Still red after the
     second → end the turn on a decision for the person, naming what is failing, what
     was tried, and what is left.
  5. **Then the marker.** The message says what each step found: the checks that ran and
     what came back, what the reviewers raised and what became of it, anything left
     deliberately undone. The part above already teaches the shape that message takes and
     this one does not repeat it — except to say that "verified, not assumed" is the
     whole point of these five steps. Never write the done marker on the strength of
     having written the code.

  ### What this repo calls green

  The facts that differ from repo to repo live under a `## Finish` heading in this file,
  outside Whiska's block, one `name: value` line each:

      ## Finish

      checks: <the commands that must pass>
      specs: <where the written decisions live>
      ticket: <the prefix a ticket id carries here>

  `checks:` is what step 2 runs. `specs:` is what step 1 reads. `ticket:` is how the
  brief's ticket id is recognised — when there is tooling for the tracker, read the
  ticket and check the work against it; when there is not, say in the message that it
  was not checked rather than assuming it matched.

  No `## Finish` heading at all, or a line missing from it: do not stop, and do not
  invent ceremony. Run what this repo's tooling plainly offers — the test task its build
  file defines, the scripts in its package manifest, the commands its own instructions
  already name — read the decisions where they plainly live, and then say in the done
  message what was assumed. One line is enough; it is how the person finds out the
  heading is worth writing.
  <!-- whiska:finish:end -->\
  """

  @parts [
    %{name: "worktrees", body: @worktrees},
    %{name: "marker", body: @marker},
    %{name: "delivery", body: @delivery},
    %{name: "report", body: @report},
    %{name: "finish", body: @finish}
  ]

  @doc """
  The parts the block is made of, in the order they are written, each as
  `%{name: name, body: body}` with its own markers already around it.
  """
  @spec parts() :: [%{name: String.t(), body: String.t()}]
  def parts, do: @parts

  @doc "The whole block, outer markers included, as a fresh install writes it."
  @spec render() :: String.t()
  def render do
    bodies = Enum.map_join(@parts, "\n\n", & &1.body)
    @header <> "\n\n" <> bodies <> "\n" <> @outer_end
  end

  @doc """
  Merge the block into a `CLAUDE.md`'s contents, per part (ADR-0045).

  Idempotent, and surgical in the same sense `Whiska.Install.merge/1` is: text
  outside the outer markers is returned byte for byte, a part whose markers are
  present is replaced where it stands, a part whose markers are missing is added
  at the end of the block, a part whose start marker says `keep` is left exactly
  alone, and a part from an older Whiska that is no longer shipped stays where it
  is rather than being tidied away.
  """
  @spec merge(String.t()) :: String.t()
  def merge(contents) when is_binary(contents) do
    case split_outer(contents) do
      :none -> append_block(contents)
      {before_block, inside, after_block} -> before_block <> rebuild(inside) <> after_block
    end
  end

  # No block yet: the whole thing goes on the end, leaving what is already there
  # untouched. One trailing newline, whatever the file ended with.
  defp append_block(contents) do
    case String.trim_trailing(contents) do
      "" -> render() <> "\n"
      trimmed -> trimmed <> "\n\n" <> render() <> "\n"
    end
  end

  # The outer markers bound everything Whiska is allowed to rewrite. Only the
  # first pair counts: a second one would mean two blocks, which merge/1 never
  # writes, and guessing which was meant would be worse than leaving it be.
  defp split_outer(contents) do
    with [before_block, rest] <- String.split(contents, @outer_start, parts: 2),
         [inside, after_block] <- String.split(rest, @outer_end, parts: 2) do
      {before_block <> @outer_start, inside, @outer_end <> after_block}
    else
      _ -> :none
    end
  end

  # Walk what is inside the block once, replacing the parts that are ours to
  # replace and copying everything else through, then add whatever never showed
  # up at all.
  defp rebuild(inside) do
    segments = segments(inside)

    seen =
      for {:part, name, _keep, _raw} <- segments, into: MapSet.new() do
        name
      end

    rewritten = Enum.map_join(segments, &render_segment/1)

    missing =
      @parts
      |> Enum.reject(&MapSet.member?(seen, &1.name))
      |> Enum.map_join("", &("\n" <> &1.body <> "\n"))

    case missing do
      "" -> rewritten
      _ -> String.trim_trailing(rewritten) <> "\n" <> missing
    end
  end

  defp render_segment({:other, text}), do: text
  defp render_segment({:part, _name, true, raw}), do: raw

  defp render_segment({:part, name, false, raw}) do
    case Enum.find(@parts, &(&1.name == name)) do
      # A part from an older Whiska that is no longer shipped. Left alone rather
      # than deleted: it is text a person has been reading, and ADR-0007's
      # instinct — nothing is ever thrown away quietly — applies to their file
      # at least as much as to Whiska's own rows.
      nil -> raw
      part -> part.body
    end
  end

  # Inside the block, in order: the parts, and the text between them. A start
  # marker with no matching end is not a part at all — it is text, and copying
  # it through unchanged is the only safe reading of a half-written marker.
  defp segments(inside) do
    case Regex.run(@part_start, inside, return: :index) do
      nil ->
        [{:other, inside}]

      [{start_at, start_len}, {name_at, name_len} | rest] ->
        name = binary_part(inside, name_at, name_len)
        keep = rest != [] and match?({_, _}, hd(rest)) and elem(hd(rest), 0) >= 0
        before_part = binary_part(inside, 0, start_at)
        after_start = binary_part(inside, start_at, byte_size(inside) - start_at)

        case close(after_start, name, start_len) do
          nil ->
            [{:other, inside}]

          {raw, remainder} ->
            [{:other, before_part}, {:part, name, keep, raw} | segments(remainder)]
        end
    end
  end

  # The part ends at its own name's end marker. A different name's end marker in
  # between means the file is malformed; matching only on the name keeps the
  # damage to that one part rather than swallowing its neighbours.
  defp close(text, name, start_len) do
    ending = "<!-- whiska:#{name}:end -->"

    case String.split(text, ending, parts: 2) do
      [body, remainder] when byte_size(body) >= start_len ->
        {body <> ending, remainder}

      _ ->
        nil
    end
  end
end
