defmodule Whiska.Pickup.PolicyTest do
  use ExUnit.Case, async: true

  alias Whiska.Pickup.Policy

  @now ~U[2026-10-15 12:00:00Z]
  @last ~U[2026-10-15 11:00:00Z]

  defp error(kind, resets_at \\ nil), do: %{kind: kind, at: @now, resets_at: resets_at}
  defp after_last(minutes), do: DateTime.add(@last, minutes * 60, :second)

  describe "next/4" do
    test "a server error is picked up at once, then 2, 4, 8 and 16 minutes on, then every 30" do
      assert %{retry_at: @now} = Policy.next(error("server_error"), 0, nil, @now)

      for {pickups, minutes} <- [{1, 2}, {2, 4}, {3, 8}, {4, 16}, {5, 30}, {12, 30}] do
        due = after_last(minutes)
        assert %{retry_at: ^due} = Policy.next(error("server_error"), pickups, @last, @now)
      end
    end

    test "an expired login is picked up at once, then every ten minutes" do
      assert %{retry_at: @now} = Policy.next(error("authentication_failed"), 0, nil, @now)
      due = after_last(10)
      assert %{retry_at: ^due} = Policy.next(error("authentication_failed"), 7, @last, @now)
    end

    test "a rate limit waits for its reset, or half an hour when none was recorded" do
      reset = ~U[2026-10-21 15:00:00Z]
      assert %{retry_at: ^reset} = Policy.next(error("rate_limit", reset), 0, nil, @now)
      due = after_last(30)
      assert %{retry_at: ^due} = Policy.next(error("rate_limit"), 1, @last, @now)
    end

    test "a first rate limit with no reset recorded counts from the error, not from now" do
      written = %{kind: "rate_limit", at: @last, resets_at: nil}
      due = after_last(30)
      assert %{retry_at: ^due} = Policy.next(written, 0, nil, @now)
    end

    test "a reset that passed before the last pickup is stale, and the half-hour wait used" do
      passed = DateTime.add(@last, -3600, :second)
      due = after_last(30)
      assert %{retry_at: ^due} = Policy.next(error("rate_limit", passed), 1, @last, @now)
    end

    test "a reset or an error time no week reaches is ignored, and the half-hour wait used" do
      half_hour = DateTime.add(@now, 30 * 60, :second)

      for far <- [~U[9999-12-31 23:59:00Z], ~U[1970-01-01 00:00:01Z]] do
        assert %{retry_at: ^half_hour} = Policy.next(error("rate_limit", far), 0, nil, @now)
        odd = %{kind: "rate_limit", at: far, resets_at: nil}
        assert %{retry_at: ^half_hour} = Policy.next(odd, 0, nil, @now)
      end
    end

    test "any other kind is never picked up" do
      for kind <- ~w(invalid_request model_not_found unknown) do
        assert %{kind: ^kind, retry_at: nil} = Policy.next(error(kind), 0, nil, @now)
      end
    end
  end

  describe "owes_hoot?/1" do
    defp stall(kind, failed, retry_at \\ @now),
      do: %{kind: kind, retry_at: retry_at, failed: failed}

    test "an expired login and a kind never picked up are told at once" do
      assert Policy.owes_hoot?(stall("authentication_failed", 0))
      assert Policy.owes_hoot?(stall("invalid_request", 0, nil))
    end

    test "a server error is told after its third failed pickup" do
      refute Policy.owes_hoot?(stall("server_error", 2))
      assert Policy.owes_hoot?(stall("server_error", 3))
    end

    test "a rate limit is never told: its reset is on the sidebar" do
      refute Policy.owes_hoot?(stall("rate_limit", 9))
    end
  end
end
