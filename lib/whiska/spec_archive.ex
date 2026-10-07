defmodule Whiska.SpecArchive do
  @moduledoc """
  A copy of every mouse's spec, kept in the main checkout after its worktree is
  gone (ADR-next-spec-archive).

  The spec itself lives in the worktree and goes with it (ADR-0076). Its text
  rides on the doorstep entry of the turn that ended with it, and the owl writes
  it here when it collects that entry, so no way of removing a worktree — the
  owl's sweep, `drop-worktree`, Land here, or by hand — can lose it.

  One file per spec, `.whiska/specs/<date first written>-<branch>.md`, under a
  short header. A revision overwrites its file and moves the question it
  replaced into `replaced:`; a later turn that leaves the spec as it was moves
  nothing. The cleanup sweep turns `status: waiting` into landed or dropped.
  The folder is ignored through `.git/info/exclude`, the same local file the
  spec itself is ignored through, so no committed file changes (ADR-0056).
  """

  alias Whiska.Doorstep.Entry
  alias Whiska.Git
  alias Whiska.Schema.Mouse
  alias Whiska.Schema.Question
  alias Whiska.Spec

  @dir ".whiska/specs"
  @exclude_line "/.whiska/"

  @doc "Where this checkout's specs are kept."
  @spec dir(Path.t()) :: Path.t()
  def dir(main_checkout), do: Path.join(main_checkout, @dir)

  @doc """
  Keep the spec an entry carried, as asked in `question`. An entry with no spec,
  or with the spec already kept, writes nothing.
  """
  @spec keep(Path.t(), Entry.t(), Question.t()) :: :ok | {:error, term()}
  def keep(_main_checkout, %Entry{spec: nil}, _question), do: :ok

  def keep(main_checkout, %Entry{} = entry, %Question{id: id}) do
    with :ok <- Spec.ignore(main_checkout, @exclude_line),
         :ok <- File.mkdir_p(dir(main_checkout)) do
      case find(main_checkout, entry.mouse_id) do
        {_file, %{body: body}} when body == entry.spec ->
          :ok

        {file, saved} ->
          replaced = Enum.reject([saved.header["replaced"], saved.header["question"]], &blank?/1)

          header =
            saved.header
            |> Map.put("question", to_string(id))
            |> Map.put("replaced", Enum.join(replaced, ", "))
            |> Map.put("written", stamp(entry.stamped_at))

          File.write(file, render(header, entry.spec))

        nil ->
          header = %{
            "repo" => Path.basename(main_checkout),
            "branch" => entry.branch,
            "mouse" => entry.mouse_id,
            "question" => to_string(id),
            "written" => stamp(entry.stamped_at),
            "status" => "waiting"
          }

          File.write(new_file(main_checkout, entry), render(header, entry.spec))
      end
    end
  end

  @doc """
  Say what became of each mouse's work, in its kept spec: landed once its
  branch is stamped landed (ADR-0064), dropped once its worktree is gone with
  no landing. Landed is final; dropped can still become landed, since a
  landing is noted from the branch alone after the worktree goes. Best effort:
  a file that cannot be read or written is left as it is.
  """
  @spec settle(Path.t(), [Mouse.t()]) :: :ok
  def settle(main_checkout, mice) do
    kept = index(main_checkout)

    unless kept == %{} do
      for %Mouse{} = mouse <- mice, {file, saved} <- List.wrap(kept[mouse.mouse_id]) do
        case status(main_checkout, mouse, saved.header["status"]) do
          nil -> :ok
          status -> File.write(file, render(Map.put(saved.header, "status", status), saved.body))
        end
      end
    end

    :ok
  end

  defp status(_checkout, _mouse, "landed" <> _), do: nil

  defp status(checkout, %Mouse{landed_at: %DateTime{} = at} = mouse, _status) do
    case head(checkout, mouse) do
      {:ok, sha} -> "landed #{Date.to_iso8601(at)}, branch head #{String.slice(sha, 0, 7)}"
      _ -> "landed #{Date.to_iso8601(at)}"
    end
  end

  defp status(_checkout, %Mouse{path: path}, "waiting") do
    if is_binary(path) and File.dir?(path), do: nil, else: "dropped #{Date.utc_today()}"
  end

  defp status(_checkout, _mouse, _status), do: nil

  defp head(checkout, %Mouse{path: path, branch: branch}) do
    cond do
      is_binary(path) and File.dir?(path) -> Git.head(path)
      is_binary(branch) -> Git.branch_head(checkout, branch)
      true -> {:error, :nothing_to_ask}
    end
  end

  defp find(main_checkout, mouse_id), do: index(main_checkout)[mouse_id]

  defp index(main_checkout) do
    main_checkout
    |> dir()
    |> Path.join("*.md")
    |> Path.wildcard()
    |> Enum.flat_map(fn file ->
      with {:ok, text} <- File.read(file), {:ok, saved} <- parse(text) do
        [{saved.header["mouse"], {file, saved}}]
      else
        _ -> []
      end
    end)
    |> Map.new()
  end

  # Two mice on one branch name on the same day keep a file each.
  defp new_file(main_checkout, entry) do
    base =
      Path.join(dir(main_checkout), "#{DateTime.to_date(entry.stamped_at)}-#{slug(entry.branch)}")

    Stream.iterate(1, &(&1 + 1))
    |> Stream.map(fn
      1 -> base <> ".md"
      n -> "#{base}-#{n}.md"
    end)
    |> Enum.find(&(not File.exists?(&1)))
  end

  defp slug(branch), do: String.replace(branch, ~r/[^A-Za-z0-9._-]+/, "-")

  defp stamp(at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M UTC")

  @keys ~w(repo branch mouse question replaced written status)

  defp render(header, body) do
    lines =
      for key <- @keys, value = header[key], not blank?(value), do: "#{key}: #{value}\n"

    "---\n" <> Enum.join(lines) <> "---\n\n" <> body
  end

  defp parse("---\n" <> rest) do
    case String.split(rest, "---\n\n", parts: 2) do
      [lines, body] ->
        header =
          for line <- String.split(lines, "\n", trim: true),
              [key, value] <- [String.split(line, ": ", parts: 2)],
              into: %{},
              do: {key, value}

        if header["mouse"], do: {:ok, %{header: header, body: body}}, else: :error

      _ ->
        :error
    end
  end

  defp parse(_text), do: :error

  defp blank?(value), do: value in [nil, ""]
end
