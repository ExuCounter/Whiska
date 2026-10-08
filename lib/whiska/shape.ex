defmodule Whiska.Shape do
  @moduledoc """
  What a mouse is spawned as: its mode, the model it runs on and the effort it
  runs at (ADR-0069). The three are chosen apart
  (ADR-0069): the mode is what the
  mouse may do, the model what kind of thinking the work needs, and the effort
  how much of it.

  The rules for choosing live in `priv/models.json` and nowhere else
  (`Whiska.Shape.Rules`). Each is a sentence about the work, so the spawning
  session judges them — `whiska shape --rules` prints the file for it — and
  names what it chose. A model or effort named here is used as named; one left
  unnamed is the catch-all's. The file is read at compile time because the
  escript carries no `priv/`.

  What reaches Claude is flags: the model, the effort, and the file's fallback
  chain, which Claude Code walks itself when a model is overloaded or not
  available. Every word is plain, checked at build time for the file and here
  for the command line, so a spawn can split the flags in any shell.
  """

  alias Whiska.Shape.Rules

  @rules_file "priv/models.json"
  @external_resource @rules_file
  @rules Rules.load!(@rules_file)
  @text File.read!(@rules_file)

  @modes @rules["modes"]
  @model Rules.catch_all(@rules["model"]["choose"])
  @effort Rules.catch_all(@rules["effort"]["choose"])
  @fallback @rules["model"]["fallback"]

  @usage "expected whiska shape <build|sniff> [--model <name>] [--effort <level>], " <>
           "or whiska shape --rules."

  @type t :: %{mode: String.t(), model: String.t() | nil, effort: String.t() | nil}

  @doc "`priv/models.json` as this build read it."
  @spec rules() :: String.t()
  def rules, do: @text

  @doc "The model and the effort a spawn that names neither gets."
  @spec catch_all() :: %{model: String.t() | nil, effort: String.t() | nil}
  def catch_all, do: %{model: @model, effort: @effort}

  @doc "Read `whiska shape`'s arguments: a mode, then `--model` and `--effort` in any order."
  @spec parse([String.t()]) :: {:ok, t()} | {:error, String.t()}
  def parse([mode | flags]) when is_map_key(@modes, mode) do
    with {:ok, named} <- flags(flags, %{}) do
      {:ok, Map.merge(%{mode: mode, model: @model, effort: @effort}, named)}
    end
  end

  def parse(["-" <> _ | _]), do: {:error, @usage}
  def parse([other | _]), do: {:error, "#{other} is not a mode — expected build or sniff."}
  def parse([]), do: {:error, @usage}

  defp flags([], named), do: {:ok, named}

  defp flags([flag, value | rest], named) when flag in ["--model", "--effort"] do
    key = if flag == "--model", do: :model, else: :effort

    cond do
      Map.has_key?(named, key) -> {:error, "#{flag} is named twice."}
      Rules.plain_word?(value) -> flags(rest, Map.put(named, key, value))
      true -> {:error, "#{inspect(value)} is not one plain word, so it cannot follow #{flag}."}
    end
  end

  defp flags(_other, _named), do: {:error, @usage}

  @doc """
  The flags to start Claude with. Unnamed parts are left out, and the fallback
  chain skips the chosen model: retrying the model that just failed is no
  fallback.
  """
  @spec claude_args(t(), [String.t()]) :: [String.t()]
  def claude_args(%{model: model, effort: effort}, fallback \\ @fallback) do
    fallback = fallback |> Enum.reject(&(&1 == model)) |> Enum.uniq()

    flag("--model", model) ++
      flag("--effort", effort) ++
      flag("--fallback-model", if(fallback != [], do: Enum.join(fallback, ",")))
  end

  defp flag(_name, nil), do: []
  defp flag(name, value), do: [name, value]

  @doc "The shape as a sentence: `a sniff mouse on <model>, <effort> effort`."
  @spec describe(t()) :: String.t()
  def describe(%{mode: mode, model: model, effort: effort}) do
    "a #{mode} mouse on #{model || "your default model"}, #{effort || "your default"} effort"
  end

  @doc """
  The mode a mouse was shaped as, when its mode has since moved off it, or nil.
  Only a mouse flipped before ADR-0074 can be: its model and effort were chosen
  for the other mode's work.
  """
  @spec moved_from(%{mode: String.t(), shaped_as: String.t() | nil}) :: String.t() | nil
  def moved_from(%{mode: mode, shaped_as: as}) when is_binary(as) and as != mode, do: as
  def moved_from(_mouse), do: nil

  @doc "The shape, short, for a listing: the mode, then only what was named."
  @spec label(t()) :: String.t()
  def label(%{mode: mode, model: model, effort: effort}) do
    on = if model, do: " on #{model}", else: ""
    at = if effort, do: ", #{effort} effort", else: ""
    mode <> on <> at
  end
end
