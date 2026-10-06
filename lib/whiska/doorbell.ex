defmodule Whiska.Doorbell do
  @moduledoc """
  The one fixed line typed into a mouse's pane when the person has answered it,
  and the owl ringing it again while the answer is not taken
  (ADR-next-an-answer-is-taken-not-typed).

  The answer itself never goes through the terminal. The mouse's own
  `UserPromptSubmit` hook hands it over when this line is submitted, so the
  line only has to say that something is attached — and what to do when it is
  not, which is the one case the hook cannot speak for: a repo whose hook is
  missing.

  A doorbell can be swallowed, and nothing about the pane says so. What says
  so is the answer still not being taken. So on the backstop the owl rings
  again for every chased answer (`Whiska.Storage.chased/0`): at most
  three times, at least `:ring_ms` apart, only into a pane `Whiska.MousePane`
  bounds, and never into a held mouse. A busy pane waits and uses up no ring.
  `:ring_ms` after the last ring, an answer still not taken is marked so, once,
  and the house tells the person.

  This is ADR-0044's second exception: the owl typing into a mouse's own pane,
  about that mouse's own answer.
  """

  alias Whiska.AnswerFlag
  alias Whiska.Delivery.Draft
  alias Whiska.MousePane
  alias Whiska.Schema.Mouse
  alias Whiska.Schema.Question
  alias Whiska.Storage

  @max_rings 3
  @ready ~w(idle done)

  @typedoc "What one sweep did about one chased answer."
  @type outcome ::
          :rang
          | :not_taken
          | {:left, atom() | {:refused, term()} | {:uncounted, term()}}

  @spec line(integer()) :: String.t()
  def line(question_id) do
    "🐱 The person answered ##{question_id}; the answer is attached to this message. " <>
      "If it is not, and you were not given it earlier in this session, say so and end the turn."
  end

  @doc """
  Type the doorbell for `question_id` into `pane`. Whatever herdr's client does
  wrong — an error, a raise, an exit — comes back as `{:error, reason}`: the
  answer is saved before anyone rings, so a ring that fails is only a ring to
  try again.
  """
  @spec press(module(), Path.t(), String.t(), integer()) :: :ok | {:error, term()}
  def press(herdr, socket, pane, question_id) do
    herdr.prompt(socket, pane, line(question_id))
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  @doc """
  One pass over every chased answer of this house.

  Keys: `:main_checkout`, `:herdr`, `:socket`, `:panes` (herdr's last full
  answer, which the house already holds), `:main_pane`, `:ring_ms`, `:now`.
  """
  @spec sweep(map()) :: [{Question.t(), Mouse.t() | nil, outcome()}]
  def sweep(%{panes: {:ok, panes}} = house) do
    judged =
      for q <- Storage.chased() do
        mouse = Storage.mouse(q.mouse_id)
        {q, mouse, verdict(q, mouse, panes, house)}
      end

    ours =
      if Enum.any?(judged, &match?({_q, _mouse, {:ring, _pane}}, &1)),
        do: MousePane.our_worktrees(house),
        else: :unknown

    Enum.map(judged, fn {q, mouse, v} -> {q, mouse, act(q, mouse, v, ours, house)} end)
  end

  def sweep(_no_panes), do: []

  # Cheapest first; the first to refuse is the answer.
  defp verdict(q, mouse, panes, house) do
    with :ok <- alive(mouse),
         :ok <- not_held(mouse),
         :ok <- due(q, house),
         :ok <- rings_left(q) do
      pane(mouse, panes, house)
    end
  end

  defp alive(%Mouse{died_at: nil, removed_at: nil, path: path}) when is_binary(path) do
    if File.dir?(path), do: :ok, else: {:leave, :gone}
  end

  defp alive(_dead_or_unknown), do: {:leave, :gone}

  defp not_held(%Mouse{held_at: %DateTime{}}), do: {:leave, :held}
  defp not_held(_mouse), do: :ok

  defp due(%Question{rung_at: nil}, _house), do: :ok

  defp due(%Question{rung_at: rung_at}, house) do
    if DateTime.diff(house.now, rung_at, :millisecond) >= house.ring_ms,
      do: :ok,
      else: {:leave, :rung_recently}
  end

  defp rings_left(%Question{rings: rings}) when rings < @max_rings, do: :ok
  defp rings_left(%Question{stale_at: nil}), do: :give_up
  defp rings_left(_already_told), do: {:leave, :given_up}

  defp pane(mouse, panes, house) do
    case MousePane.agent_panes(mouse, panes) do
      [%{agent: "claude", agent_status: status} = pane] when status in @ready ->
        if pane.pane_id == house.main_pane, do: {:leave, :main_session}, else: {:ring, pane}

      [%{agent: "claude"}] ->
        {:leave, :busy}

      [_other_agent] ->
        {:leave, :no_claude}

      [] ->
        {:leave, :no_pane}

      _many ->
        {:leave, :many_panes}
    end
  end

  defp act(_q, _mouse, {:leave, reason}, _ours, _house), do: {:left, reason}

  defp act(q, _mouse, :give_up, _ours, house) do
    case Storage.mark_not_taken(q.id, house.now) do
      {:ok, _} -> :not_taken
      {:error, reason} -> {:left, {:uncounted, reason}}
    end
  end

  defp act(_q, _mouse, {:ring, _pane}, :unknown, _house), do: {:left, :no_herdr}

  defp act(q, mouse, {:ring, pane}, {:ok, ours}, house) do
    cond do
      not MousePane.ours?(mouse, ours) -> {:left, :not_our_worktree}
      match?({:hold, _}, Draft.hold(MousePane.box(pane, house))) -> {:left, :typing}
      true -> ring(q, mouse, pane, house)
    end
  end

  # Counted before it is typed, and put back if herdr refuses: a count that
  # depended on a write after the typing would be no cap on the run where that
  # write failed (ADR-0067's reasoning). The flag goes up first too, so the
  # take the ring starts is not short-circuited by the shim.
  defp ring(q, mouse, pane, house) do
    AnswerFlag.set(mouse.path)

    case Storage.set_ring(q.id, house.now, q.rings + 1) do
      {:ok, _} ->
        case press(house.herdr, house.socket, pane.pane_id, q.id) do
          :ok ->
            :rang

          {:error, reason} ->
            Storage.set_ring(q.id, q.rung_at, q.rings)
            {:left, {:refused, reason}}
        end

      {:error, reason} ->
        {:left, {:uncounted, reason}}
    end
  end
end
