defmodule Whiska.LedgerTest do
  @moduledoc """
  The agent ledger read from Claude Code's transcripts on disk (ADR-0083,
  ADR-0084): one line for the mouse's own session and one per agent it sent
  this turn.

  Every shape here is copied from a real session read on 2026-10-08: a
  transcript writes one entry per content block, each repeating the message's
  usage; a subagent's mid-run entries are written while the reply streams, so
  their `stop_reason` is null and their output count is cut short; a forked
  skill's transcript opens with "Base directory for this skill:" and its meta
  carries no description.
  """
  use ExUnit.Case, async: true

  alias Whiska.Ledger

  setup do
    root = Path.join(System.tmp_dir!(), "whiska-ledger-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)
    session = Path.join(root, "s1.jsonl")
    File.mkdir_p!(Path.join(root, "s1/subagents"))
    %{root: root, session: session, subagents: Path.join(root, "s1/subagents")}
  end

  defp usage(i, cw, cr, o),
    do: %{
      "input_tokens" => i,
      "cache_creation_input_tokens" => cw,
      "cache_read_input_tokens" => cr,
      "output_tokens" => o
    }

  # One entry per content block, as Claude Code writes them.
  defp call(id, at, usage, blocks, stop) do
    Enum.map(blocks, fn block ->
      %{
        "type" => "assistant",
        "timestamp" => at,
        "message" => %{
          "id" => id,
          "model" => "claude-opus-5-5",
          "stop_reason" => stop,
          "usage" => usage,
          "content" => [block]
        }
      }
    end)
  end

  defp prompt(at, kind, text),
    do: %{
      "type" => "user",
      "timestamp" => at,
      "origin" => %{"kind" => kind},
      "message" => %{"role" => "user", "content" => text}
    }

  defp tool(id), do: %{"type" => "tool_use", "id" => id, "name" => "Bash", "input" => %{}}

  defp write_jsonl(path, entries),
    do: File.write!(path, Enum.map_join(List.flatten(entries), "\n", &JSON.encode!/1) <> "\n")

  defp fixture(%{session: session, subagents: subagents}) do
    write_jsonl(session, [
      prompt("2026-10-08T08:00:00.000Z", "human", "build it"),
      call("m1", "2026-10-08T08:00:05.000Z", usage(2, 30_000, 0, 500), [tool("t1")], "tool_use"),
      prompt("2026-10-08T09:00:00.000Z", "human", "🔔 answered"),
      call(
        "m2",
        "2026-10-08T09:00:10.000Z",
        usage(3, 2_000, 30_000, 1_000),
        [%{"type" => "thinking"}, tool("t2"), tool("t3")],
        "tool_use"
      ),
      # Claude Code's own message, sent by no model, and a subagent's entry.
      call(
        "syn",
        "2026-10-08T09:00:09.000Z",
        usage(0, 0, 0, 0),
        [%{"type" => "text"}],
        "stop_sequence"
      )
      |> Enum.map(&put_in(&1, ["message", "model"], "<synthetic>")),
      call("side", "2026-10-08T09:00:12.000Z", usage(1, 5_000, 0, 5), [tool("t9")], "end_turn")
      |> Enum.map(&Map.put(&1, "isSidechain", true))
    ])

    # An agent from the earlier turn: not in this turn's ledger.
    write_jsonl(Path.join(subagents, "agent-old.jsonl"), [
      prompt("2026-10-08T08:00:06.000Z", "human", "scout"),
      call("o1", "2026-10-08T08:00:07.000Z", usage(1, 9_000, 0, 9), [tool("x")], "end_turn")
    ])

    File.write!(
      Path.join(subagents, "agent-old.meta.json"),
      JSON.encode!(%{"agentType" => "wio-candidate-scout", "description" => "Scout"})
    )

    # The forked cold review: complete counts, no description.
    write_jsonl(Path.join(subagents, "agent-cold.jsonl"), [
      prompt(
        "2026-10-08T09:01:00.000Z",
        "human",
        "Base directory for this skill: /h/.claude/skills/cold-review\n\n# Cold review"
      ),
      call("c1", "2026-10-08T09:01:02.000Z", usage(2, 32_000, 0, 7), [tool("c-t1")], "tool_use"),
      # One call written twice as it streamed: cut short, then final.
      call(
        "c2",
        "2026-10-08T09:02:59.000Z",
        usage(2, 4_000, 32_000, 4),
        [%{"type" => "thinking"}],
        nil
      ),
      call(
        "c2",
        "2026-10-08T09:03:00.000Z",
        usage(2, 4_000, 32_000, 1_400),
        [%{"type" => "text"}],
        "end_turn"
      )
    ])

    File.write!(
      Path.join(subagents, "agent-cold.meta.json"),
      JSON.encode!(%{"agentType" => "Explore", "requestShape" => "foreground"})
    )

    # A background reviewer whose mid-run output counts were cut short.
    write_jsonl(Path.join(subagents, "agent-sec.jsonl"), [
      prompt("2026-10-08T09:00:30.000Z", "human", "Read-only security review."),
      call(
        "s1",
        "2026-10-08T09:00:31.000Z",
        usage(2, 20_000, 0, 8),
        [%{"type" => "thinking"}, tool("s-t1")],
        nil
      ),
      call("s2", "2026-10-08T09:01:01.000Z", usage(2, 1_000, 20_000, 8), [tool("s-t2")], nil)
    ])

    File.write!(
      Path.join(subagents, "agent-sec.meta.json"),
      JSON.encode!(%{
        "agentType" => "general-purpose",
        "description" => "Security review",
        "model" => "sonnet"
      })
    )
  end

  test "the mouse's whole session and this turn's agents, with real figures", ctx do
    fixture(ctx)

    ledger = Ledger.read(ctx.session)

    assert %{
             label: "mouse (whole session)",
             models: ["claude-opus-5-5"],
             new_tokens: 33_505,
             cache_reads: 30_000,
             steps: 2,
             avg_per_step: 31_003,
             tool_uses: 3,
             seconds: 3610,
             floor: false
           } = ledger.mouse

    assert [sec, cold] = ledger.agents

    assert %{
             label: "cold-review",
             type: "Explore",
             models: ["claude-opus-5-5"],
             new_tokens: 37_411,
             cache_reads: 32_000,
             steps: 2,
             avg_per_step: 34_002,
             tool_uses: 1,
             seconds: 120,
             floor: false
           } = cold

    assert %{
             label: "Security review",
             type: "general-purpose",
             new_tokens: 21_020,
             steps: 2,
             tool_uses: 2,
             seconds: 31,
             floor: true
           } = sec
  end

  test "a line reads in one glance, a floor marked ≥", ctx do
    fixture(ctx)

    text = Ledger.render(Ledger.read(ctx.session))

    assert text =~
             "cold-review · Explore · claude-opus-5-5 · new 37.4k · reads 32k · 2 steps · avg 34k/step · 1 tool use · 120s"

    assert text =~ "Security review · general-purpose · claude-opus-5-5 · new ≥21k ·"
    assert text =~ "mouse (whole session) · claude-opus-5-5 · new 33.5k · reads 30k ·"
    refute text =~ "Scout"
  end

  test "the same figures as data, for a later budget to sum", ctx do
    fixture(ctx)

    data = JSON.decode!(Ledger.json(Ledger.read(ctx.session)))

    assert %{"version" => 1, "mouse" => %{"new_tokens" => 33_505}, "agents" => [_, _]} = data
  end

  test "a label another agent wrote stays on its one line, with no control characters", ctx do
    write_jsonl(ctx.session, [])

    write_jsonl(Path.join(ctx.subagents, "agent-x.jsonl"), [
      prompt("2026-10-08T09:00:00.000Z", "human", "go")
    ])

    File.write!(
      Path.join(ctx.subagents, "agent-x.meta.json"),
      JSON.encode!(%{
        "agentType" => "general-purpose",
        "description" => "Review\e[31m\nmouse (whole session) · new 0\u2028done"
      })
    )

    [agent_line, _mouse] = String.split(Ledger.render(Ledger.read(ctx.session)), "\n")

    assert agent_line =~ ~r/^Review \[31m mouse \(whole session\) · new 0 done · general-purpose/
  end

  test "a figure the transcript cannot give is named, never guessed", ctx do
    write_jsonl(ctx.session, [%{"type" => "user", "message" => %{"content" => "hi"}}])

    write_jsonl(Path.join(ctx.subagents, "agent-a1b2.jsonl"), [
      %{
        "type" => "user",
        "timestamp" => "2026-10-08T09:00:00.000Z",
        "message" => %{"content" => "go"}
      }
    ])

    [agent_line, mouse_line] = String.split(Ledger.render(Ledger.read(ctx.session)), "\n")

    assert agent_line =~ ~r/^a1b2 · model unknown · new 0/
    assert mouse_line =~ "model unknown"
    assert mouse_line =~ "seconds unknown"
  end

  test "an entry in a shape it does not expect is skipped, not a crash", ctx do
    write_jsonl(ctx.session, [
      %{"type" => "assistant", "message" => "text"},
      %{"type" => "assistant", "message" => [1]},
      %{"type" => "user", "origin" => "human"},
      %{"type" => "assistant", "message" => %{"id" => "m", "usage" => %{"input_tokens" => "9"}}}
    ])

    File.write!(Path.join(ctx.subagents, "agent-y.jsonl"), "")

    File.write!(
      Path.join(ctx.subagents, "agent-y.meta.json"),
      JSON.encode!(%{"agentType" => %{"a" => 1}, "description" => ["x"]})
    )

    assert Ledger.render(Ledger.read(ctx.session)) =~ "mouse (whole session)"
  end

  test "a session with no subagents folder has only the mouse line", ctx do
    File.rm_rf!(Path.join(ctx.root, "s1"))
    write_jsonl(ctx.session, [prompt("2026-10-08T08:00:00.000Z", "human", "hi")])

    assert %{agents: [], mouse: %{steps: 0}} = Ledger.read(ctx.session)
  end

  test "finds a session's transcript by its id under any project folder", ctx do
    project = Path.join([ctx.root, ".claude", "projects", "-some-worktree"])
    File.mkdir_p!(project)
    File.write!(Path.join(project, "abc.jsonl"), "")

    assert Ledger.find("abc", ctx.root) == Path.join(project, "abc.jsonl")
    assert Ledger.find("nope", ctx.root) == nil
    assert Ledger.find("*", ctx.root) == nil
  end
end
