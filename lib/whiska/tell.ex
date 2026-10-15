defmodule Whiska.Tell do
  @moduledoc """
  `whiska tell`: a letter from this repo's main session to another open
  house's main session, on the person's word (ADR-0044).

  The file is copied into that house and recorded there; that house's own
  delivery types one fixed line pointing at the copy into its own main
  session, under away and its gate (ADR-0008, ADR-0047).
  """

  alias Whiska.Delivery.Mode
  alias Whiska.Delivery.Text
  alias Whiska.Letters
  alias Whiska.OpenHouses
  alias Whiska.Storage

  @doc """
  Leave the words in `file` for the open house named `repo`, from the house at
  `main_checkout`. Answers the line for the person, or why nothing was left.

  Options: `:open_houses` (the record's path), `:pids` (the owls running),
  `:away_path`.
  """
  @spec run(Path.t(), String.t(), Path.t(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def run(main_checkout, repo, file, opts \\ []) do
    from = Path.expand(main_checkout)

    with {:ok, houses} <- open_houses(opts),
         {:ok, target} <- find(houses, repo),
         :ok <- not_this(target, from),
         :ok <- has_main_session(target),
         {:ok, _text} <- Letters.read(file),
         {:ok, copy} <- copy(target, file, Path.basename(from)),
         {:ok, _} <- record(target, from, copy) do
      {:ok, left(target, opts)}
    end
  end

  defp open_houses(opts) do
    pids = Keyword.get_lazy(opts, :pids, &Whiska.Owl.pids/0)
    record = Keyword.get_lazy(opts, :open_houses, &OpenHouses.path/0)

    case OpenHouses.open(pids, record) do
      [] when pids == [] ->
        {:error, "no owl is running, so no house is open to take a letter."}

      houses ->
        {:ok, houses}
    end
  end

  defp find(houses, repo) do
    case Enum.filter(houses, &(&1 == Path.expand(repo) or Path.basename(&1) == repo)) do
      [target] ->
        {:ok, target}

      [] ->
        {:error,
         "no open house is called #{repo}. Open ones: " <>
           Enum.map_join(houses, ", ", &Path.basename/1) <> "."}

      several ->
        {:error,
         "#{length(several)} open houses are called #{repo}; name one by its main checkout: " <>
           Enum.join(several, ", ") <> "."}
    end
  end

  defp not_this(target, target),
    do: {:error, "#{Path.basename(target)} is this repo's own house; a letter goes to another."}

  defp not_this(_target, _from), do: :ok

  defp has_main_session(target) do
    case in_house(target, &Storage.main_pane/0) do
      pane when is_binary(pane) ->
        :ok

      nil ->
        {:error,
         "#{Path.basename(target)} has no main session recorded, so nothing would type the " <>
           "letter. Run `whiska start` in its main pane first."}

      {:error, :no_database} ->
        {:error, "#{Path.basename(target)} has no house at #{target} any more."}

      {:error, reason} ->
        {:error, "could not open #{Path.basename(target)}'s house (#{inspect(reason)})."}
    end
  end

  defp copy(target, file, from_repo) do
    with {:ok, copy} <- Letters.put_house(target, file),
         {:ok, _line} <- typeable(from_repo, copy) do
      {:ok, copy}
    else
      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, reason} ->
        {:error,
         "could not copy #{file} into #{Path.basename(target)}'s house (#{inspect(reason)})."}
    end
  end

  defp typeable(from_repo, copy) do
    case Text.letter(from_repo, copy) do
      {:ok, line} ->
        {:ok, line}

      :error ->
        File.rm(copy)
        {:error, "#{copy} holds a character no typed line can carry."}
    end
  end

  defp record(target, from, copy) do
    attrs = %{from_repo: Path.basename(from), from_checkout: from, path: copy}

    case in_house(target, fn -> Storage.leave_letter(attrs) end) do
      {:ok, letter} ->
        {:ok, letter}

      {:error, reason} ->
        File.rm(copy)

        {:error,
         "could not record the letter in #{Path.basename(target)}'s house (#{inspect(reason)})."}
    end
  end

  # `Storage.within/2` makes a house where none is, and an open-houses record
  # can outlive a repo deleted while the owl runs.
  defp in_house(target, fun) do
    if File.exists?(Storage.database_path(target)),
      do: Storage.within(target, fun),
      else: {:error, :no_database}
  rescue
    error -> {:error, Exception.message(error)}
  catch
    :exit, reason -> {:error, reason}
  end

  defp left(target, opts) do
    name = Path.basename(target)
    away? = Mode.away?(Keyword.get_lazy(opts, :away_path, &Mode.away_path/0))

    "Left for #{name}'s main session; it is typed there once that session is free." <>
      if(away?, do: " You are away, so it waits until `resume`.", else: "")
  end
end
