defmodule Whiska.Shape do
  @moduledoc """
  What a mouse is spawned as: its mode and the model it runs on (ADR-0069).

  The model belongs to the shape. Investigation is a lighter job than building,
  so a sniff mouse starts on a lighter model; a build mouse passes no `--model`
  at all and keeps whatever the person's own Claude Code default is. A spawn
  may name another model for either, so the common case needs no decision and
  the odd one is still a flag away.

  Which models exist, and which mode starts on which, live in
  `priv/models.json` and nowhere else: adding, renaming or re-defaulting a
  model is an edit to that file and a rebuild. It is read at compile time
  because the escript carries no `priv/`. Models are named by the aliases
  `claude --model` takes, which resolve to the latest of each family, so
  nothing names a version.
  """

  @models_file "priv/models.json"
  @external_resource @models_file

  {models, defaults} =
    case @models_file |> File.read!() |> JSON.decode!() do
      %{"models" => [_ | _] = models, "defaults" => %{} = defaults} -> {models, defaults}
      _ -> raise "#{@models_file}: expected a \"models\" list and a \"defaults\" object"
    end

  # The file owns the models, not the modes: those are build and sniff everywhere else.
  if Enum.sort(Map.keys(defaults)) != ~w(build sniff) do
    raise "#{@models_file}: \"defaults\" must give exactly build and sniff a model or null"
  end

  # An alias reaches `claude --model` through a spawn script, so it must be one plain word.
  for model <- models, not Regex.match?(~r/\A[a-z0-9-]+\z/, model) do
    raise "#{@models_file}: #{inspect(model)} is not a plain model alias"
  end

  for {mode, model} <- defaults, model != nil and model not in models do
    raise "#{@models_file}: #{mode} defaults to #{model}, which is not one of its models"
  end

  @models models
  @defaults defaults

  @type t :: %{mode: String.t(), model: String.t() | nil}

  @doc "The model aliases a spawn may name."
  def models, do: @models

  @doc "Each mode's default model, `nil` for the person's own default."
  def defaults, do: @defaults

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

  @doc "The shape in words: `build`, or `sniff on` and its model."
  @spec describe(String.t(), String.t() | nil) :: String.t()
  def describe(mode, nil), do: mode
  def describe(mode, model), do: "#{mode} on #{model}"
end
