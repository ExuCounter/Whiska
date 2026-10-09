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

  describe "gauge/2" do
    test "with no window it is the plain size" do
      assert Context.gauge(142_000, nil) == "142K"
    end

    test "with a window it adds a five-cell bar of how much is used" do
      assert Context.gauge(142_000, 200_000) == "142K ▰▰▰▰▱"
      assert Context.gauge(10_000, 200_000) == "10K ▱▱▱▱▱"
    end

    test "past the window the bar is full, never longer" do
      assert Context.gauge(250_000, 200_000) == "250K ▰▰▰▰▰"
    end

    test "nothing read is nothing shown" do
      assert Context.gauge(nil, 200_000) == nil
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
