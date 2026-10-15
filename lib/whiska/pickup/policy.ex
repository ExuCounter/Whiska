defmodule Whiska.Pickup.Policy do
  @moduledoc """
  When a turn that died on an API error is picked up next, and when the person
  is told about it (ADR-0067).

  Read off the error's kind, as Claude Code's own `error` field names it:

    * `server_error` — asleep, offline, a cut stream, a timeout. Picked up
      again 2, 4, 8 and 16 minutes after the previous pickup, then every 30,
      with no limit. Offline, a pickup fails before any request leaves the
      machine, so it costs two lines in the pane and no tokens.
    * `authentication_failed` — the login expired. Every 10 minutes, with no
      limit: a refused login costs nothing, and a `/login` in any session
      revives the ones already running.
    * `rate_limit` — once the reset Claude Code recorded has passed.
    * Anything else, `invalid_request` and `model_not_found` among them, is no
      outage that clears by itself, and is never picked up.

  The waits are counted from the previous pickup, which the owl recorded
  itself, rather than from the error, which only the transcript says. Every
  time read from the transcript is somebody else's text, so a retry is never
  sooner than the first backoff after the last pickup, nor further off than
  `@furthest_days`, whatever the file claims.
  """

  alias Whiska.Transcript

  @typedoc """
  What a stalled mouse is waiting out: its kind, when it is due (nil: never),
  and how many pickups of this run have failed.
  """
  @type stall :: %{kind: String.t(), retry_at: DateTime.t() | nil, failed: non_neg_integer()}

  @backoff_minutes [2, 4, 8, 16]
  @ceiling_minutes 30
  @login_minutes 10

  # Longer than a weekly limit's window.
  @furthest_days 8

  # A server error is told after this many pickups that also failed.
  @told_after 3

  @doc """
  When the mouse is next picked up for `error`, after `failed` pickups of this
  run failed, the latest at `picked_up_at` (nil on a run's first). The first
  pickup of a run is due at once, but for a rate limit, which waits for its
  reset.
  """
  @spec next(Transcript.api_error(), non_neg_integer(), DateTime.t() | nil, DateTime.t()) ::
          stall()
  def next(%{kind: kind} = error, failed, picked_up_at, now) do
    since = picked_up_at || plausible(error[:at], now) || now
    reset = error[:resets_at] |> plausible(now) |> unspent(picked_up_at)
    due = due(Map.put(error, :resets_at, reset), failed, since, now)
    %{kind: kind, retry_at: due && bounded(due, picked_up_at, now), failed: failed}
  end

  defp plausible(%DateTime{} = at, now) do
    if DateTime.diff(at, now, :day) |> abs() <= @furthest_days, do: at
  end

  defp plausible(_none, _now), do: nil

  # A reset the last pickup already waited for is not this failure's reset.
  defp unspent(%DateTime{} = reset, %DateTime{} = picked_up_at),
    do: if(DateTime.compare(reset, picked_up_at) == :gt, do: reset)

  defp unspent(reset, _no_pickup), do: reset

  defp bounded(due, picked_up_at, now) do
    soonest = if picked_up_at, do: minutes(picked_up_at, hd(@backoff_minutes)), else: due
    furthest = DateTime.add(now, @furthest_days * 86_400, :second)
    due |> latest(soonest) |> earliest(furthest)
  end

  defp latest(a, b), do: if(DateTime.compare(a, b) == :lt, do: b, else: a)
  defp earliest(a, b), do: if(DateTime.compare(a, b) == :gt, do: b, else: a)

  defp due(%{kind: "rate_limit", resets_at: %DateTime{} = at}, _pickups, _since, _now), do: at
  defp due(%{kind: "rate_limit"}, _pickups, since, _now), do: minutes(since, @ceiling_minutes)

  defp due(%{kind: kind}, 0, _since, now) when kind in ~w(server_error authentication_failed),
    do: now

  defp due(%{kind: "authentication_failed"}, _pickups, since, _now),
    do: minutes(since, @login_minutes)

  defp due(%{kind: "server_error"}, pickups, since, _now),
    do: minutes(since, Enum.at(@backoff_minutes, pickups - 1, @ceiling_minutes))

  defp due(_never, _pickups, _since, _now), do: nil

  defp minutes(since, n), do: DateTime.add(since, n * 60, :second)

  @doc """
  Whether the person is owed the one notification of this run: an expired login
  and a kind never picked up at once, a server error after its third failed
  pickup, a rate limit never — its reset is on the sidebar.
  """
  @spec owes_hoot?(stall()) :: boolean()
  def owes_hoot?(%{kind: "authentication_failed"}), do: true
  def owes_hoot?(%{kind: "rate_limit"}), do: false
  def owes_hoot?(%{kind: "server_error", failed: failed}), do: failed >= @told_after
  def owes_hoot?(%{retry_at: nil}), do: true
  def owes_hoot?(_stall), do: false
end
