defmodule Whiska.Context do
  @moduledoc """
  How full a mouse's context is, read from its Claude Code transcript
  (ADR-0050) and said in a few characters for the sidebar line (ADR-0082) and
  `whiska mice`.

  The size is what the last assistant message sent to the model: its
  `input_tokens`, `cache_read_input_tokens` and `cache_creation_input_tokens`.
  Output is not part of it. A mouse with an auto-compact window also gets a bar
  of how much of the window is used; a mouse without one gets the size alone.

  Everything here is total: a transcript that says nothing is `nil`.
  """

  @input_keys ["input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"]

  @doc "The size alone: `850`, `142K`, `1.2M`."
  @spec size(non_neg_integer()) :: String.t()
  def size(tokens) when tokens < 1_000, do: Integer.to_string(tokens)
  def size(tokens) when tokens < 1_000_000, do: "#{div(tokens, 1_000)}K"
  def size(tokens), do: "#{div(tokens, 100_000) / 10}M"

  @doc "The size, or `nil` when nothing was read."
  @spec gauge(non_neg_integer() | nil) :: String.t() | nil
  def gauge(nil), do: nil
  def gauge(tokens), do: size(tokens)

  @doc """
  How near `window`, the auto-compact window, a context of `tokens` is: `:ok`
  under two thirds, `:warn` from there, `:full` from nine tenths (ADR-0082).
  """
  @spec band(non_neg_integer(), pos_integer()) :: :ok | :warn | :full
  def band(tokens, window) when tokens * 10 >= window * 9, do: :full
  def band(tokens, window) when tokens * 3 >= window * 2, do: :warn
  def band(_tokens, _window), do: :ok

  @doc "The context size at the last assistant message in a transcript's text, or `nil`."
  @spec tokens(String.t()) :: non_neg_integer() | nil
  def tokens(text) do
    text
    |> String.split("\n")
    |> Enum.reverse()
    |> Enum.find_value(&line_tokens/1)
  end

  defp line_tokens(line) do
    with {:ok, %{"type" => "assistant", "message" => %{"usage" => usage}}} <- JSON.decode(line),
         true <- is_map(usage),
         total when total > 0 <- total(usage) do
      total
    else
      _unreadable -> nil
    end
  end

  defp total(usage) do
    Enum.reduce(@input_keys, 0, fn key, sum ->
      case usage[key] do
        count when is_integer(count) and count > 0 -> sum + count
        _other -> sum
      end
    end)
  end
end
