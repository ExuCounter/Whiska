defmodule Whiska.CLIMetricsTest do
  @moduledoc """
  `whiska metrics`: four views read from the house — cost by shape, waits,
  spec timing and reviewer cost (ADR-0086).
  """
  # Serial: the command opens the house under the one VM-wide name `Whiska.Repo`.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Whiska.CLI
  alias Whiska.Repo
  alias Whiska.Storage

  setup do
    root = Path.join(System.tmp_dir!(), "whiska-metrics-#{System.unique_integer([:positive])}")
    main = Path.join(root, "myrepo")
    File.mkdir_p!(Path.join(main, ".git"))
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, main: main}
  end

  defp seed(main, fun) do
    {:ok, handle} = Storage.open(main)
    fun.()
    Storage.close(handle)
  end

  defp at(time), do: DateTime.new!(~D[2026-10-11], time, "Etc/UTC")

  defp change!(record, attrs), do: record |> Ecto.Changeset.change(attrs) |> Repo.update!()

  defp ask(mouse_id, kind, attrs) do
    {:ok, q} =
      Storage.record_question(%{mouse_id: mouse_id, text: "…", kind: kind, status: "open"})

    change!(q, attrs)
  end

  defp line(attrs) do
    Map.merge(
      %{
        label: "mouse (this turn)",
        type: nil,
        models: ["claude-opus-5-5"],
        efforts: ["xhigh"],
        input: 0,
        cache_writes: 0,
        cache_reads: 0,
        output: 0,
        steps: 1,
        tool_uses: 0,
        seconds: 60,
        floor: false,
        api_errors: 0
      },
      Map.new(attrs)
    )
  end

  defp turn(q, mouse, agents \\ []) do
    {:ok, _} =
      Storage.record_usage(q.id, %{mouse: line(mouse), agents: Enum.map(agents, &line/1)})
  end

  defp mouse(id, mode, created_at) do
    {:ok, _} = Storage.record_mouse(%{mouse_id: id, path: "/w/#{id}", branch: "feat-#{id}"})
    {:ok, _} = Storage.shape(id, mode, "opus", "xhigh")
    change!(Storage.mouse(id), created_at: at(created_at))
  end

  # Three build mice of one shape whose own turns cost 100, 250 and 900 cost
  # units, so a median, a mean and a sum all differ, and one sniff mouse of
  # another. m1 grilled once, revised its spec, and got the ok four minutes
  # after the second; m2's spec was asked twice for one turn, so the ok landed
  # on the copy that carried no new spec (ADR-0036).
  defp four_mice(main) do
    seed(main, fn ->
      mouse("m1", "build", ~T[10:00:00])
      mouse("m2", "build", ~T[10:50:00])
      mouse("m3", "build", ~T[12:00:00])
      mouse("m4", "sniff", ~T[13:00:00])

      grill =
        ask("m1", "needs-decision",
          status: "answered",
          asked_at: at(~T[10:10:00]),
          sent_at: at(~T[10:10:09]),
          answered_at: at(~T[10:12:09]),
          taken_at: at(~T[10:12:10])
        )

      ask("m1", "needs-decision",
        status: "superseded",
        spec_sent: true,
        asked_at: at(~T[10:16:00]),
        sent_at: at(~T[10:16:00])
      )

      spec =
        ask("m1", "needs-decision",
          status: "answered",
          spec_sent: true,
          asked_at: at(~T[10:20:00]),
          sent_at: at(~T[10:20:00]),
          answered_at: at(~T[10:24:00]),
          taken_at: at(~T[10:24:01])
        )

      done1 =
        ask("m1", "done", status: "closed", asked_at: at(~T[10:45:00]), sent_at: at(~T[10:45:30]))

      first_copy =
        ask("m2", "needs-decision",
          status: "superseded",
          spec_sent: true,
          asked_at: at(~T[11:00:00])
        )

      ask("m2", "needs-decision",
        status: "answered",
        asked_at: at(~T[11:00:05]),
        sent_at: at(~T[11:00:10]),
        answered_at: at(~T[11:06:10]),
        taken_at: at(~T[11:06:11])
      )

      done2 = ask("m2", "done", status: "closed", asked_at: at(~T[11:20:10]))
      done3 = ask("m3", "done", status: "closed", asked_at: at(~T[12:30:00]))
      done4 = ask("m4", "done", status: "closed", asked_at: at(~T[13:30:00]))

      turn(grill, input: 10, cache_writes: 40, cache_reads: 100, output: 2)
      turn(spec, input: 20)

      turn(done1, [input: 0], [
        [label: "Security review", type: "general-purpose", input: 200, seconds: 120]
      ])

      turn(first_copy, input: 50)

      turn(done2, [output: 40], [
        [label: "Review the diff", type: "security-reviewer", input: 100, seconds: 60],
        [label: "Frontend review", type: "general-purpose", input: 10],
        [label: "Find the latest herdr release", type: "general-purpose", input: 10]
      ])

      turn(done3, cache_reads: 9000)
      turn(done4, input: 50, efforts: ["medium"])
    end)
  end

  test "--json prints the four views from what the house holds", %{main: main} do
    four_mice(main)

    out = capture_io(fn -> assert CLI.run(["metrics", "--json"], main) == 0 end)
    data = JSON.decode!(out)

    assert %{"version" => 1} = data

    assert [
             %{
               "mode" => "build",
               "model" => "claude-opus-5-5",
               "effort" => "xhigh",
               "mice" => 3,
               "steps" => 2,
               "new_tokens" => 72,
               "cache_reads" => 100,
               "cost_units" => 250,
               "seconds" => 120,
               "decisions" => 2
             },
             %{"mode" => "sniff", "effort" => "medium", "mice" => 1, "cost_units" => 50}
           ] = data["shapes"]

    waits = Map.new(data["waits"], &{&1["wait"], &1})
    assert %{"n" => 4, "sum" => 14} = waits["asked_to_delivered"]

    assert %{"n" => 3, "median" => 240, "p90" => 360, "sum" => 720} =
             waits["delivered_to_answered"]

    assert %{"n" => 3, "sum" => 3} = waits["answered_to_taken"]
    assert %{"n" => 3, "sum" => 737} = waits["asked_to_taken"]

    assert %{
             "mice" => 2,
             "rounds_before" => 0,
             "spawn_to_spec" => 600,
             "wait_for_ok" => 240,
             "ok_to_finished" => 840,
             "spend_before_ok" => 0.14,
             "revised" => 1
           } = data["spec"]

    assert [
             %{"axis" => "security", "runs" => 2, "cost_units" => 100, "seconds" => 60},
             %{"axis" => "frontend", "runs" => 1},
             %{"axis" => "other", "runs" => 1}
           ] = data["reviewers"]

    assert data["agent_share"] == 0.2
  end

  test "the text puts each figure on its own line, in the person's terms", %{main: main} do
    four_mice(main)

    out = capture_io(fn -> assert CLI.run(["metrics"], main) == 0 end)

    assert out =~
             "  build · claude-opus-5-5 · xhigh — 3 mice · 2 steps · new 72 · reads 100 · " <>
               "250 cost units · working 2 min · 2 decisions\n"

    assert out =~ ~r/delivered → answered\s+3 · 4 min · 6 min · 12 min\n/
    assert out =~ ~r/spawn → spec sent\s+10 min\n/
    assert out =~ ~r/wait for your ok\s+4 min\n/
    assert out =~ ~r/ok → finished\s+14 min\n/
    assert out =~ ~r/revised after a reply\s+1 of 2\n/
    assert out =~ ~r/security\s+2 · 100 · 1 min · /
  end

  test "an empty house says no usage is recorded yet, and still exits 0", %{main: main} do
    seed(main, fn -> :ok end)

    out = capture_io(fn -> assert CLI.run(["metrics"], main) == 0 end)

    assert out =~ "No usage recorded yet"
  end

  test "is in the usage text" do
    out = capture_io(fn -> CLI.run(["help"]) end)
    assert out =~ "metrics [--json]"
  end
end
