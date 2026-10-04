defmodule Whiska.Shape do
  @moduledoc """
  What a mouse is spawned as: its mode and the model it runs on (ADR-0069).

  The model belongs to the shape. Investigation is a lighter job than building,
  so a sniff mouse starts on `sonnet`; a build mouse passes no `--model` at all
  and keeps whatever the person's own Claude Code default is. A spawn may name
  another model for either, so the common case needs no decision and the odd
  one is still a flag away.

  Models are named by the aliases `claude --model` takes, which resolve to the
  latest of each family, so nothing here names a version.
  """

  @models ~w(fable opus sonnet)
  @defaults %{"build" => nil, "sniff" => "sonnet"}

  @type t :: %{mode: String.t(), model: String.t() | nil}

  @doc "The model aliases a spawn may name."
  def models, do: @models

  @doc "Read `whiska shape`'s arguments: a mode, and optionally `--model <alias>`."
  @spec parse([String.t()]) :: {:ok, t()} | {:error, String.t()}
  def parse([mode | rest]) when is_map_key(@defaults, mode) do
    case rest do
      [] ->
        {:ok, %{mode: mode, model: @defaults[mode]}}

      ["--model", model] when model in @models ->
        {:ok, %{mode: mode, model: model}}

      ["--model", model] ->
        {:error, "#{model} is not a model — expected #{Enum.join(@models, ", ")}."}

      _ ->
        {:error, "expected whiska shape <build|sniff> [--model <alias>]."}
    end
  end

  def parse([other | _]), do: {:error, "#{other} is not a mode — expected build or sniff."}
  def parse([]), do: {:error, "expected whiska shape <build|sniff> [--model <alias>]."}

  @doc "The shape in words: `sniff on sonnet`, `build`."
  @spec describe(String.t(), String.t() | nil) :: String.t()
  def describe(mode, nil), do: mode
  def describe(mode, model), do: "#{mode} on #{model}"
end
