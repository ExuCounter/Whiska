defmodule Whiska.Metrics do
  @moduledoc """
  What one house says about cost and waiting, for `whiska metrics`: four views
  read from its records, never from transcripts
  (ADR-0086).

  - **Cost by shape**: per mouse, the sum of its own turns' usage, then medians
    over the mice of each mode, model and effort. The model and effort are the
    ones its turns ran on, read from its usage rows.
  - **Waits**: over the questions that ask for an answer, the time from asked
    to delivered, delivered to answered, answered to taken, and asked to taken.
  - **Spec**: per mouse that sent a spec, the grilling rounds before it, spawn
    to spec, the wait for the ok, ok to finished, the share of its spend before
    the ok, and whether a reply revised it.
  - **Reviewers**: agent rows by axis, read from a word in the agent's type,
    else in its label.

  Tokens only, no prices (ADR-0069). Cost units weigh each kind of token by the
  ratio every Claude model is priced at: input + 1.25 × cache writes + 0.1 ×
  cache reads + 5 × output. A median is the nearest-rank one, as is p90.
  """

  alias Whiska.Schema.Mouse
  alias Whiska.Schema.Question
  alias Whiska.Storage

  @cost_units "input + 1.25 × cache writes + 0.1 × cache reads + 5 × output"
  @asking ~w(needs-decision unmarked)

  @waits [
    {"asked_to_delivered", "asked → delivered", :asked_at, :sent_at},
    {"delivered_to_answered", "delivered → answered", :sent_at, :answered_at},
    {"answered_to_taken", "answered → taken", :answered_at, :taken_at},
    {"asked_to_taken", "asked → taken", :asked_at, :taken_at}
  ]

  @doc "The four views, read from the house this process points at."
  @spec read() :: map()
  def read do
    questions = Map.new(Storage.all(Question), &{&1.id, &1})
    mice = Map.new(Storage.all(Mouse), &{&1.mouse_id, &1})

    usage =
      Enum.filter(Storage.usage(), &(not &1.replaced and Map.has_key?(questions, &1.question_id)))

    by_mouse = Enum.group_by(usage, &questions[&1.question_id].mouse_id)
    asked = questions |> Map.values() |> Enum.sort_by(& &1.id) |> Enum.group_by(& &1.mouse_id)
    total = cost(usage)

    %{
      version: 1,
      cost_units: @cost_units,
      recorded: usage != [],
      shapes: shapes(by_mouse, mice, asked),
      waits: waits(Map.values(questions)),
      spec: spec(asked, mice, by_mouse),
      reviewers: reviewers(usage, total),
      agent_share: share(cost(Enum.filter(usage, &(&1.scope == "agent"))), total)
    }
  end

  # -- cost by shape ------------------------------------------------------------

  defp shapes(by_mouse, mice, asked) do
    for {mouse_id, rows} <- by_mouse,
        own = Enum.filter(rows, &(&1.scope == "mouse")),
        own != [] do
      {shape(mice[mouse_id], own),
       %{
         steps: sum(own, :steps),
         new_tokens: sum(own, :input) + sum(own, :cache_writes) + sum(own, :output),
         cache_reads: sum(own, :cache_reads),
         cost_units: round(cost(own)),
         seconds: sum(own, :seconds),
         decisions: Enum.count(Map.get(asked, mouse_id, []), &(&1.kind == "needs-decision"))
       }}
    end
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.map(fn {{mode, model, effort}, mice} ->
      figures =
        for key <- ~w(steps new_tokens cache_reads cost_units seconds decisions)a,
            into: %{},
            do: {key, median(Enum.map(mice, & &1[key]))}

      Map.merge(figures, %{mode: mode, model: model, effort: effort, mice: length(mice)})
    end)
    |> Enum.sort_by(&{&1.mode, &1.model || "", &1.effort || ""})
  end

  defp shape(mouse, own), do: {mode(mouse), most(own, :model), most(own, :effort)}

  defp mode(%Mouse{} = mouse), do: Storage.mode_of(mouse)
  defp mode(nil), do: "unknown"

  defp most(rows, key) do
    case rows |> Enum.map(&Map.get(&1, key)) |> Enum.reject(&is_nil/1) do
      [] -> nil
      values -> values |> Enum.frequencies() |> Enum.max_by(&elem(&1, 1)) |> elem(0)
    end
  end

  # -- waits --------------------------------------------------------------------

  defp waits(questions) do
    asking = Enum.filter(questions, &(&1.kind in @asking))

    for {key, _label, from, to} <- @waits do
      spans = for q <- asking, s = span(Map.get(q, from), Map.get(q, to)), s != nil, do: s

      %{
        wait: key,
        n: length(spans),
        median: median(spans),
        p90: percentile(spans, 0.9),
        sum: Enum.sum(spans)
      }
    end
  end

  # -- spec ---------------------------------------------------------------------

  defp spec(asked, mice, by_mouse) do
    sent =
      for {mouse_id, qs} <- asked,
          specs = Enum.filter(qs, & &1.spec_sent),
          specs != [],
          do: spec_of(mice[mouse_id], qs, specs, Map.get(by_mouse, mouse_id, []))

    %{
      mice: length(sent),
      rounds_before: median(Enum.map(sent, & &1.rounds_before)),
      spawn_to_spec: median(for s <- sent, s.spawn_to_spec, do: s.spawn_to_spec),
      wait_for_ok: median(for s <- sent, s.wait_for_ok, do: s.wait_for_ok),
      ok_to_finished: median(for s <- sent, s.ok_to_finished, do: s.ok_to_finished),
      spend_before_ok: median(for s <- sent, s.spend_before_ok, do: s.spend_before_ok),
      revised: Enum.count(sent, & &1.revised)
    }
  end

  # The ok is the first answer from the last spec question on: a second entry
  # for the same turn carries the spec unchanged, so the person may answer that
  # copy rather than the question marked as the spec (ADR-0036).
  defp spec_of(mouse, qs, [first | _] = specs, rows) do
    last = List.last(specs)
    ok = Enum.find(qs, last, &(&1.id >= last.id and &1.answered_at != nil))
    finished = Enum.find(qs, &(&1.kind == "done" and &1.id > ok.id))
    before = MapSet.new(for q <- qs, q.id <= ok.id, do: q.id)

    %{
      rounds_before: Enum.count(qs, &(&1.id < first.id and &1.kind in @asking)),
      spawn_to_spec: span(mouse && mouse.created_at, first.asked_at),
      wait_for_ok: span(ok.sent_at, ok.answered_at),
      ok_to_finished: span(ok.answered_at, finished && finished.asked_at),
      spend_before_ok:
        share(cost(Enum.filter(rows, &MapSet.member?(before, &1.question_id))), cost(rows)),
      revised: length(specs) > 1
    }
  end

  # -- reviewers ----------------------------------------------------------------

  defp reviewers(usage, total) do
    usage
    |> Enum.filter(&(&1.scope == "agent"))
    |> Enum.group_by(&axis/1)
    |> Enum.map(fn {axis, runs} ->
      %{
        axis: axis,
        runs: length(runs),
        cost_units: median(Enum.map(runs, &round(cost([&1])))),
        seconds: median(for r <- runs, r.seconds, do: r.seconds),
        share: share(cost(runs), total)
      }
    end)
    |> Enum.sort_by(&{-&1.runs, &1.axis})
  end

  # The axes ADR-0049 names, plus the scout, as whole words: a repo's own
  # `security-reviewer` type says its axis, and "latest" says none.
  @axes [
    {~r/\bcold[- ]review\b/, "cold review"},
    {~r/\bsecurity\b/, "security"},
    {~r/\bperformance\b/, "performance"},
    {~r/\bfrontend\b/, "frontend"},
    {~r/\btests?\b/, "tests"},
    {~r/\bscout\b/, "scout"}
  ]

  defp axis(%{type: type, label: label}), do: axis_in(type) || axis_in(label) || "other"

  defp axis_in(nil), do: nil

  defp axis_in(text) do
    text = String.downcase(text)
    Enum.find_value(@axes, fn {word, axis} -> if text =~ word, do: axis end)
  end

  # -- arithmetic ---------------------------------------------------------------

  defp cost(rows) do
    rows
    |> Enum.map(&(&1.input + 1.25 * &1.cache_writes + 0.1 * &1.cache_reads + 5 * &1.output))
    |> Enum.sum()
  end

  defp sum(rows, key), do: rows |> Enum.map(&(Map.get(&1, key) || 0)) |> Enum.sum()

  defp share(_part, total) when total == 0, do: nil
  defp share(part, total), do: Float.round(part / total, 2)

  defp span(%DateTime{} = from, %DateTime{} = to) do
    case DateTime.diff(to, from) do
      s when s >= 0 -> s
      _negative -> nil
    end
  end

  defp span(_from, _to), do: nil

  defp median(values), do: percentile(values, 0.5)

  defp percentile([], _p), do: nil

  defp percentile(values, p) do
    sorted = Enum.sort(values)
    Enum.at(sorted, max(ceil(p * length(sorted)) - 1, 0))
  end

  # -- rendering ----------------------------------------------------------------

  @doc "The views as text for the person."
  @spec render(map()) :: String.t()
  def render(metrics) do
    [
      unless(metrics.recorded,
        do:
          "No usage recorded yet: the owl records it for each turn it collects " <>
            "from now on.\n"
      ),
      render_shapes(metrics.shapes),
      render_waits(metrics.waits),
      render_spec(metrics.spec),
      render_reviewers(metrics.reviewers, metrics.agent_share)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
    |> String.trim_trailing()
  end

  defp render_shapes(shapes) do
    head =
      "Cost by shape: medians per mouse, over its own turns. " <>
        "Cost units = #{@cost_units}.\n"

    rows =
      for s <- shapes do
        label =
          Enum.join([s.mode, s.model || "model unknown", s.effort || "effort unknown"], " · ")

        "  #{label} — " <>
          Enum.join(
            [
              count(s.mice, "mouse", "mice"),
              count(s.steps, "step", "steps"),
              "new #{short(s.new_tokens)}",
              "reads #{short(s.cache_reads)}",
              "#{short(s.cost_units)} cost units",
              "working #{duration(s.seconds)}",
              count(s.decisions, "decision", "decisions")
            ],
            " · "
          ) <> "\n"
      end

    head <> rows_or_none(rows)
  end

  defp render_waits(waits) do
    labels = Map.new(@waits, fn {key, label, _, _} -> {key, label} end)
    head = "Waits, on questions that ask for an answer: how many, median, p90, total.\n"

    rows =
      for w <- waits do
        "  #{String.pad_trailing(labels[w.wait], 22)}" <>
          Enum.join(
            [w.n, duration(w.median), duration(w.p90), duration(w.sum)] |> Enum.map(&to_string/1),
            " · "
          ) <> "\n"
      end

    head <> Enum.join(rows)
  end

  defp render_spec(%{mice: 0}), do: "Spec: no mouse has sent one yet.\n"

  defp render_spec(spec) do
    "Spec: #{count(spec.mice, "mouse", "mice")} sent one. Medians:\n" <>
      Enum.map_join(
        [
          {"grilling rounds before it", to_string(spec.rounds_before)},
          {"spawn → spec sent", duration(spec.spawn_to_spec)},
          {"wait for your ok", duration(spec.wait_for_ok)},
          {"ok → finished", duration(spec.ok_to_finished)},
          {"spend before the ok", percent(spec.spend_before_ok)},
          {"revised after a reply", "#{spec.revised} of #{spec.mice}"}
        ],
        fn {label, value} -> "  #{String.pad_trailing(label, 27)}#{value}\n" end
      )
  end

  defp render_reviewers(reviewers, agent_share) do
    head =
      "Reviewers and other agents: #{percent(agent_share)} of all spend. " <>
        "Runs, median cost units, median time, share of all spend.\n"

    rows =
      for r <- reviewers do
        "  #{String.pad_trailing(r.axis, 13)}" <>
          Enum.join(
            [r.runs, short(r.cost_units), duration(r.seconds), percent(r.share)]
            |> Enum.map(&to_string/1),
            " · "
          ) <> "\n"
      end

    head <> rows_or_none(rows)
  end

  defp rows_or_none([]), do: "  none yet\n"
  defp rows_or_none(rows), do: Enum.join(rows)

  defp count(1, one, _many), do: "1 #{one}"
  defp count(n, _one, many), do: "#{n} #{many}"

  defp percent(nil), do: "–"
  defp percent(share), do: "#{round(share * 100)}%"

  defp duration(nil), do: "–"
  defp duration(s) when s < 60, do: "#{s} s"
  defp duration(s) when s < 3600, do: "#{one_place(s / 60)} min"
  defp duration(s), do: "#{one_place(s / 3600)} h"

  defp short(nil), do: "–"
  defp short(n) when n < 1_000, do: Integer.to_string(n)
  defp short(n) when n < 1_000_000, do: one_place(n / 1_000) <> "k"
  defp short(n), do: one_place(n / 1_000_000) <> "M"

  defp one_place(x) do
    x |> Float.round(1) |> :erlang.float_to_binary(decimals: 1) |> String.replace_suffix(".0", "")
  end

  @doc "The same views as data, for a dashboard to read. `version` bumps when a field changes meaning."
  @spec json(map()) :: String.t()
  def json(metrics), do: metrics |> Map.delete(:recorded) |> JSON.encode!()
end
