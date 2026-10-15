defmodule Whiska.ContextTest do
  @moduledoc "How full a mouse's context is, said in a few characters (ADR-0050, ADR-0082)."
  use ExUnit.Case, async: true

  alias Whiska.Context

  describe "size/1" do
    test "small counts are plain, thousands are K, millions are M" do
      assert Context.size(850) == "850"
      assert Context.size(142_300) == "142K"
      assert Context.size(1_250_000) == "1.2M"
    end
  end

  describe "gauge/1" do
    test "is the plain size" do
      assert Context.gauge(142_000) == "142K"
    end

    test "nothing read is nothing shown" do
      assert Context.gauge(nil) == nil
    end
  end

  describe "band/2, how near the auto-compact window a context is" do
    test "under two thirds is fine, from two thirds a warning, from nine tenths full" do
      assert Context.band(199_999, 300_000) == :ok
      assert Context.band(200_000, 300_000) == :warn
      assert Context.band(269_999, 300_000) == :warn
      assert Context.band(270_000, 300_000) == :full
      assert Context.band(400_000, 300_000) == :full
    end

    test "follows the window, so a smaller one warns sooner" do
      assert Context.band(70_000, 100_000) == :warn
      assert Context.band(90_000, 100_000) == :full
    end
  end

  describe "tokens/1, from the last assistant message's usage" do
    defp assistant(usage),
      do:
        JSON.encode!(%{"type" => "assistant", "message" => %{"usage" => usage, "content" => []}})

    test "input, cache read and cache creation are added; output is not" do
      line =
        assistant(%{
          "input_tokens" => 10,
          "cache_read_input_tokens" => 100_000,
          "cache_creation_input_tokens" => 2_000,
          "output_tokens" => 999
        })

      assert Context.tokens(line) == 102_010
    end

    test "the last assistant message wins, and a user line or a torn line is skipped" do
      text =
        Enum.join(
          [
            assistant(%{"input_tokens" => 1}),
            assistant(%{"input_tokens" => 7, "cache_read_input_tokens" => 3}),
            JSON.encode!(%{"type" => "user", "message" => %{"content" => "hi"}}),
            ~s({"type":"assistant","mess)
          ],
          "\n"
        )

      assert Context.tokens(text) == 10
    end

    test "a message with no usage, or all zeros (a synthetic one), says nothing" do
      assert Context.tokens(assistant(%{})) == nil
      assert Context.tokens(assistant(%{"input_tokens" => 0})) == nil
      assert Context.tokens("not json") == nil
    end
  end
end
