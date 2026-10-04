defmodule Whiska.Shape.Rules do
  @moduledoc """
  `priv/models.json`: the modes, and the ordered rules a spawn picks a model and
  an effort by (ADR-0069, ADR-next-model-and-effort-are-chosen-by-ordered-rules).

  `Whiska.Shape` reads it while it compiles, so everything here raises: a file
  that is wrong stops the build, with a message naming what to fix.

  What it checks, and what it leaves to others:

  - The file holds `modes`, `model` and `effort`, and nothing else. What a
    mode may do is the hook's to enforce, so nothing here claims to.
  - `modes` describes exactly build and sniff — the two the hook knows.
  - Each `choose` list is ordered and the first rule that fits wins, so the
    last one must be the catch-all, and only the last: a catch-all earlier
    would hide every rule after it.
  - Every model and effort is one plain word — never a check that the model
    exists. Claude Code owns which models exist, and a list of them here is
    what would go stale. The catch-all alone may be null, for the person's own
    default: a flag left off gets the catch-all's, so an earlier null could
    never reach Claude.
  """

  @catch_all "anything else"
  @two_modes ~s("modes" must describe exactly build and sniff, the modes the hook enforces)

  @doc """
  The decoded file at `path`, once it passes every check above. Raises a
  `RuntimeError` naming the file and the problem otherwise.
  """
  @spec load!(Path.t()) :: map()
  def load!(path) do
    with {:ok, text} <- File.read(path),
         {:ok, rules} <- decode(text),
         :ok <- check(rules) do
      rules
    else
      {:error, problem} when is_binary(problem) -> raise "#{path}: #{problem}"
      {:error, reason} -> raise "#{path}: could not be read (#{inspect(reason)})"
    end
  end

  @doc "One plain word: lowercase letters, digits and dashes, starting with no dash."
  @spec plain_word?(term()) :: boolean()
  def plain_word?(word), do: is_binary(word) and word =~ ~r/\A[a-z0-9][a-z0-9-]*\z/

  @doc "The `use` of a list's catch-all: what a spawn that names nothing gets."
  @spec catch_all([map()]) :: String.t() | nil
  def catch_all(choose), do: List.last(choose)["use"]

  defp decode(text) do
    case JSON.decode(text) do
      {:ok, %{} = rules} -> {:ok, rules}
      {:ok, _other} -> {:error, "must be one JSON object"}
      {:error, reason} -> {:error, "is not JSON (#{inspect(reason)})"}
    end
  end

  defp check(rules) do
    with :ok <- keys(rules, "the file", ~w(modes model effort)),
         :ok <- modes(rules["modes"]),
         :ok <- keys(rules["model"], ~s("model"), ~w(choose fallback)),
         :ok <- choose(rules["model"]["choose"], "model.choose"),
         :ok <- fallback(rules["model"]["fallback"]),
         :ok <- keys(rules["effort"], ~s("effort"), ~w(choose)) do
      choose(rules["effort"]["choose"], "effort.choose")
    end
  end

  defp keys(%{} = map, where, expected) do
    case {expected -- Map.keys(map), Map.keys(map) -- expected} do
      {[], []} -> :ok
      {[missing | _], _} -> {:error, "#{where} is missing #{inspect(missing)}"}
      {[], [extra | _]} -> {:error, "#{where} has #{inspect(extra)}; #{holds(where, expected)}"}
    end
  end

  defp keys(_other, where, _expected), do: {:error, "#{where} must be a JSON object"}

  defp holds(where, expected) do
    {init, [last]} = Enum.split(Enum.map(expected, &inspect/1), -1)
    names = if init == [], do: last, else: Enum.join(init, ", ") <> " and " <> last
    "#{where} holds #{names} and nothing else"
  end

  defp modes(%{} = modes) when map_size(modes) == 2 do
    Enum.find_value(~w(build sniff), :ok, fn mode ->
      case modes[mode] do
        nil -> {:error, @two_modes}
        text -> if words?(text), do: nil, else: undescribed(mode)
      end
    end)
  end

  defp modes(_other), do: {:error, @two_modes}

  defp undescribed(mode),
    do: {:error, "modes.#{mode} must say, in words, when a mouse is spawned as #{mode}"}

  defp words?(text), do: is_binary(text) and String.trim(text) != ""

  defp choose([_ | _] = rules, where) do
    last = length(rules)

    rules
    |> Enum.with_index(1)
    |> Enum.find_value(:ok, fn {rule, n} -> rule(rule, "#{where}, rule #{n}", n == last) end)
    |> case do
      :ok -> catch_all_last(List.last(rules), where)
      problem -> problem
    end
  end

  defp choose(_other, where),
    do: {:error, "#{where} must be a list of rules, ending on the catch-all"}

  defp rule(%{"when" => text, "use" => use} = rule, where, last?) when map_size(rule) == 2 do
    cond do
      not words?(text) ->
        {:error, ~s(#{where}: "when" must say, in words, when this rule applies)}

      not (is_nil(use) or plain_word?(use)) ->
        {:error,
         ~s(#{where}: "use" must be one plain word, or null for the person's own default, not #{inspect(use)})}

      text == @catch_all and not last? ->
        {:error,
         "#{where} is the catch-all, but only the last rule may be: every rule after it would never apply"}

      is_nil(use) and not last? ->
        {:error,
         ~s(#{where}: "use" is null, but only the catch-all may be null: a flag left off gets the catch-all's, so nothing else can ask for the person's own default)}

      true ->
        nil
    end
  end

  defp rule(_other, where, _last?),
    do: {:error, ~s(#{where} must be exactly a "when" and a "use")}

  defp catch_all_last(%{"when" => @catch_all}, _where), do: :ok

  defp catch_all_last(_rule, where),
    do: {:error, ~s(#{where} must end on the catch-all, "when": "#{@catch_all}")}

  defp fallback(models) when is_list(models) do
    if Enum.all?(models, &plain_word?/1),
      do: :ok,
      else: {:error, "model.fallback must be a list of plain words, not #{inspect(models)}"}
  end

  defp fallback(other),
    do: {:error, "model.fallback must be a list of plain words, not #{inspect(other)}"}
end
