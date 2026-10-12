defmodule Whiska.SpecArchive do
  @moduledoc """
  A copy of every mouse's spec, kept in the main checkout after its worktree is
  gone (ADR-0063).

  The spec itself lives in the worktree and goes with it (ADR-0063). Its text
  rides on the doorstep entry of the turn that ended with it, and the owl writes
  it here when it collects that entry, so no way of removing a worktree — the
  owl's sweep, `drop-worktree`, or by hand — can lose it.

  One file per spec, `.whiska/specs/<date first written>-<branch>.md`, under a
  short header, and the build plan beside it as `<the same name>.plan.md`. A
  revision overwrites its file and moves the question it replaced into
  `replaced:`; a later turn that leaves the text as it was moves nothing. The
  cleanup sweep turns `status: waiting` into landed or dropped, for both.
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
  @spec_suffix ""
  @plan_suffix ".plan"

  @doc "Where this checkout's specs are kept."
  @spec dir(Path.t()) :: Path.t()
  def dir(main_checkout), do: Path.join(main_checkout, @dir)

  @doc """
  Keep the spec an entry carried, as asked in `question`: `:kept` when it was
  new or revised. An entry with no spec, or with the spec already kept, writes
  nothing and is `:unchanged`.
  """
  @spec keep(Path.t(), Entry.t(), Question.t()) :: :kept | :unchanged | {:error, term()}
  def keep(main_checkout, %Entry{} = entry, %Question{} = question),
    do: keep(main_checkout, entry, question, entry.spec, @spec_suffix)

  @doc "Keep the build plan an entry carried, beside its spec, the way `keep/3` keeps the spec."
  @spec keep_plan(Path.t(), Entry.t(), Question.t()) :: :kept | :unchanged | {:error, term()}
  def keep_plan(main_checkout, %Entry{} = entry, %Question{} = question),
    do: keep(main_checkout, entry, question, entry.plan, @plan_suffix)

  defp keep(_main_checkout, _entry, _question, nil, _suffix), do: :unchanged

  defp keep(main_checkout, entry, %Question{id: id}, text, suffix) do
    with :ok <- Spec.ignore(main_checkout, @exclude_line),
         :ok <- File.mkdir_p(dir(main_checkout)) do
      case find(main_checkout, names(main_checkout), entry.mouse_id, entry.branch, suffix) do
        {_file, %{body: body}} when body == text ->
          :unchanged

        {file, saved} ->
          replaced = Enum.reject([saved.header["replaced"], saved.header["question"]], &blank?/1)

          header =
            saved.header
            |> Map.put("question", to_string(id))
            |> Map.put("replaced", Enum.join(replaced, ", "))
            |> Map.put("written", stamp(entry.stamped_at))

          write(file, render(header, text))

        nil ->
          header = %{
            "repo" => Path.basename(main_checkout),
            "branch" => entry.branch,
            "mouse" => entry.mouse_id,
            "question" => to_string(id),
            "written" => stamp(entry.stamped_at),
            "status" => "waiting"
          }

          write(new_file(main_checkout, entry, suffix), render(header, text))
      end
    end
  end

  defp write(file, text) do
    with :ok <- File.write(file, text), do: :kept
  end

  @doc """
  Say what became of each mouse's work, in its kept spec: landed once its
  branch is stamped landed (ADR-0064), dropped once its worktree is gone with
  no landing. A mouse in `superseded` has lost its folder to a newer record, so
  its worktree is gone even while the folder stands. Landed is final; dropped
  can still become landed, since a landing is noted from the branch alone after
  the worktree goes. Best effort: a file that cannot be read or written is left
  as it is.
  """
  @spec settle(Path.t(), [Mouse.t()], MapSet.t(String.t())) :: :ok
  def settle(main_checkout, mice, superseded \\ MapSet.new()) do
    names = names(main_checkout)

    unless names == [] do
      for %Mouse{branch: branch} = mouse <- mice,
          is_binary(branch),
          own = Enum.filter(names, &String.contains?(&1, slug(branch))),
          suffix <- [@spec_suffix, @plan_suffix],
          {file, saved} <- List.wrap(find(main_checkout, own, mouse.mouse_id, branch, suffix)) do
        gone? = MapSet.member?(superseded, mouse.mouse_id) or not standing?(mouse.path)

        case status(main_checkout, mouse, gone?, saved.header["status"]) do
          nil -> :ok
          status -> File.write(file, render(Map.put(saved.header, "status", status), saved.body))
        end
      end
    end

    :ok
  end

  defp status(_checkout, _mouse, _gone?, "landed" <> _), do: nil

  defp status(checkout, %Mouse{landed_at: %DateTime{} = at} = mouse, gone?, _status) do
    case head(checkout, mouse, gone?) do
      {:ok, sha} -> "landed #{Date.to_iso8601(at)}, branch head #{String.slice(sha, 0, 7)}"
      _ -> "landed #{Date.to_iso8601(at)}"
    end
  end

  defp status(_checkout, _mouse, true, "waiting"), do: "dropped #{Date.utc_today()}"
  defp status(_checkout, _mouse, _gone?, _status), do: nil

  # A folder another mouse has taken holds that mouse's head, not this one's.
  defp head(_checkout, %Mouse{path: path}, false), do: Git.head(path)
  defp head(checkout, %Mouse{branch: branch}, true), do: Git.branch_head(checkout, branch)

  defp standing?(path), do: is_binary(path) and File.dir?(path)

  defp names(main_checkout) do
    case File.ls(dir(main_checkout)) do
      {:ok, names} -> names
      {:error, _} -> []
    end
  end

  # Only the files named for this branch are opened, so the cost stays with
  # the branch, not with how many specs the folder has kept.
  defp find(main_checkout, names, mouse_id, branch, suffix) do
    slug = slug(branch)

    names
    |> Enum.filter(&named_for?(&1, slug, suffix))
    |> Enum.find_value(fn name ->
      file = Path.join(dir(main_checkout), name)

      with {:ok, text} <- File.read(file),
           {:ok, %{header: %{"mouse" => ^mouse_id}} = saved} <- parse(text) do
        {file, saved}
      else
        _ -> nil
      end
    end)
  end

  defp named_for?(name, slug, suffix) do
    with [_, rest] <- Regex.run(~r/^\d{4}-\d{2}-\d{2}-(.+)\.md$/, name),
         true <- String.ends_with?(rest, suffix) do
      stem = String.replace_suffix(rest, suffix, "")
      stem == slug or Regex.match?(~r/^#{Regex.escape(slug)}-\d+$/, stem)
    else
      _ -> false
    end
  end

  # A build plan takes its spec's name, so the two sit side by side.
  defp new_file(main_checkout, entry, @plan_suffix) do
    with {spec, _saved} <-
           find(main_checkout, names(main_checkout), entry.mouse_id, entry.branch, @spec_suffix),
         paired = Path.rootname(spec) <> @plan_suffix <> ".md",
         false <- File.exists?(paired) do
      paired
    else
      _ -> numbered(main_checkout, entry, @plan_suffix)
    end
  end

  defp new_file(main_checkout, entry, suffix), do: numbered(main_checkout, entry, suffix)

  # Two mice on one branch name on the same day keep a file each. A name is
  # taken when either kind holds it, so a plan kept with no spec never sits
  # beside another mouse's spec.
  defp numbered(main_checkout, entry, suffix) do
    base =
      Path.join(dir(main_checkout), "#{DateTime.to_date(entry.stamped_at)}-#{slug(entry.branch)}")

    stem =
      Stream.iterate(1, &(&1 + 1))
      |> Stream.map(fn
        1 -> base
        n -> "#{base}-#{n}"
      end)
      |> Enum.find(fn stem ->
        not Enum.any?([@spec_suffix, @plan_suffix], &File.exists?(stem <> &1 <> ".md"))
      end)

    stem <> suffix <> ".md"
  end

  defp slug(branch), do: String.replace(branch, ~r/[^A-Za-z0-9._-]+/, "-")

  defp stamp(at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M UTC")

  @keys ~w(repo branch mouse question replaced written status)

  defp render(header, body) do
    lines =
      for key <- @keys,
          value = header[key],
          not blank?(value),
          do: "#{key}: #{String.replace(to_string(value), ~r/[\r\n]+/, " ")}\n"

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
