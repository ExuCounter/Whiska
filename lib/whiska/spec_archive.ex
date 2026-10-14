defmodule Whiska.SpecArchive do
  @moduledoc """
  A copy of every mouse's spec, kept in the main checkout after its worktree is
  gone (ADR-0063).

  The spec itself lives in the worktree and goes with it (ADR-0063). Its text
  rides on the doorstep entry of the turn that ended with it, and the owl writes
  it here when it collects that entry, so no way of removing a worktree — the
  owl's sweep, `whiska drop`, or by hand — can lose it.

  One file per spec, `.whiska/specs/<date first written>-<branch>.md`, holding
  the text as sent, the build plan beside it as `<the same name>.plan.md`, the
  research document as `<the same name>.research.md`, and the mouse's last
  report as `<the same name>.report.md`. The mouse's record names that shared
  name (`kept_as`), which is how each is found again. A revision overwrites its
  file; a later turn that leaves the text as it was writes nothing.
  The folder is ignored through `.git/info/exclude`, the same local file the
  spec itself is ignored through, so no committed file changes (ADR-0056).
  """

  alias Whiska.Doorstep.Entry
  alias Whiska.HouseFile
  alias Whiska.Report
  alias Whiska.Schema.Mouse
  alias Whiska.Spec
  alias Whiska.Storage

  @dir ".whiska/specs"
  @exclude_line "/.whiska/"
  @spec_suffix ""
  @plan_suffix ".plan"
  @research_suffix ".research"
  @report_suffix ".report"
  @suffixes [@spec_suffix, @plan_suffix, @research_suffix, @report_suffix]

  @doc "Where this checkout's specs are kept."
  @spec dir(Path.t()) :: Path.t()
  def dir(main_checkout), do: Path.join(main_checkout, @dir)

  @doc """
  Keep the spec an entry carried: `:kept` when it was new or revised. An entry
  with no spec, or with the spec already kept, writes nothing and is
  `:unchanged`.
  """
  @spec keep(Path.t(), Entry.t()) :: :kept | :unchanged | {:error, term()}
  def keep(main_checkout, %Entry{} = entry),
    do: keep(main_checkout, entry, entry.spec, @spec_suffix)

  @doc "Keep the build plan an entry carried, beside its spec, the way `keep/2` keeps the spec."
  @spec keep_plan(Path.t(), Entry.t()) :: :kept | :unchanged | {:error, term()}
  def keep_plan(main_checkout, %Entry{} = entry),
    do: keep(main_checkout, entry, entry.plan, @plan_suffix)

  @doc "Keep the research document an entry carried, beside its spec, the way `keep/2` keeps the spec."
  @spec keep_research(Path.t(), Entry.t()) :: :kept | :unchanged | {:error, term()}
  def keep_research(main_checkout, %Entry{} = entry),
    do: keep(main_checkout, entry, entry.research, @research_suffix)

  @doc """
  Keep the final message an entry carried when it is a document
  (`Whiska.Report`): a sniff mouse's as its research document, any other's as
  its report. A message that is not one keeps nothing.
  """
  @spec keep_document(Path.t(), Entry.t(), String.t()) :: :kept | :unchanged | {:error, term()}
  def keep_document(main_checkout, %Entry{text: text} = entry, mode) do
    cond do
      not Report.document?(text) -> :unchanged
      mode == "sniff" -> keep(main_checkout, entry, Report.text(text), @research_suffix)
      true -> keep(main_checkout, entry, Report.text(text), @report_suffix)
    end
  end

  @doc "The research document kept for `mouse`, or nil."
  @spec research(Path.t(), Mouse.t()) :: Path.t() | nil
  def research(main_checkout, %Mouse{} = mouse), do: kept(main_checkout, mouse, @research_suffix)

  @doc "The report kept for `mouse`, or nil."
  @spec report(Path.t(), Mouse.t()) :: Path.t() | nil
  def report(main_checkout, %Mouse{} = mouse), do: kept(main_checkout, mouse, @report_suffix)

  defp kept(_main_checkout, %Mouse{kept_as: nil}, _suffix), do: nil

  defp kept(main_checkout, %Mouse{kept_as: name}, suffix) do
    file = path(main_checkout, name, suffix)
    if File.exists?(file), do: file
  end

  defp keep(_main_checkout, _entry, nil, _suffix), do: :unchanged

  defp keep(main_checkout, entry, text, suffix) do
    with :ok <- Spec.ignore(main_checkout, @exclude_line) do
      mouse = Storage.mouse(entry.mouse_id)
      name = (mouse && mouse.kept_as) || new_name(main_checkout, entry)
      file = path(main_checkout, name, suffix)

      if same?(file, text) do
        :unchanged
      else
        with {:ok, _path} <- HouseFile.write(main_checkout, @dir, Path.basename(file), text),
             :ok <- name_on(mouse, name),
             do: :kept
      end
    end
  end

  # A file that is not a plain one is replaced, never read through.
  defp same?(file, text) do
    match?({:ok, %File.Stat{type: :regular}}, File.lstat(file)) and File.read(file) == {:ok, text}
  end

  # A document for a mouse with no record is written, but nothing names it.
  defp name_on(nil, _name), do: :ok
  defp name_on(%Mouse{kept_as: name}, name), do: :ok
  defp name_on(%Mouse{mouse_id: mouse_id}, name), do: Storage.set_kept_as(mouse_id, name)

  @doc """
  Strip the header an older Whiska wrote at the top of each kept file, naming
  the file on its mouse's record as it goes; a mouse this house has no record
  of names nothing. A file without one is left as it is, so a second run
  changes nothing. Best effort: a file that cannot be read or written is left
  as it is.
  """
  @spec unhead(Path.t()) :: :ok
  def unhead(main_checkout) do
    folder = dir(main_checkout)

    with {:ok, %File.Stat{type: :directory}} <- File.lstat(folder),
         {:ok, names} <- File.ls(folder) do
      for name <- Enum.sort(names),
          file = Path.join(folder, name),
          {:ok, %File.Stat{type: :regular}} <- [File.lstat(file)],
          {:ok, text} <- [File.read(file)],
          {:ok, header, body} <- [unheader(text)],
          {:ok, _path} <- [HouseFile.write(main_checkout, @dir, name, body)],
          stem when is_binary(stem) <- [stem(name, header["branch"])] do
        Storage.set_kept_as(header["mouse"], stem)
      end
    end

    :ok
  end

  @header_keys ~w(repo branch mouse question replaced written status)

  # The header an older Whiska wrote: `---`, a line per key of its own, one
  # naming the mouse, `---`, then a blank line before the text. Front matter
  # with any other key is the mouse's own text, and stays.
  defp unheader("---\n" <> rest) do
    with [lines, body] <- String.split(rest, "---\n\n", parts: 2),
         pairs =
           Enum.map(String.split(lines, "\n", trim: true), &String.split(&1, ": ", parts: 2)),
         true <- Enum.all?(pairs, &match?([key, _] when key in @header_keys, &1)),
         %{"mouse" => _} = header <- Map.new(pairs, &List.to_tuple/1) do
      {:ok, header, body}
    else
      _ -> :error
    end
  end

  defp unheader(_text), do: :error

  # A kept file's shared name: its own, less `.md` and its kind's suffix. The
  # branch the header names says where the name ends, so a branch that itself
  # ends in `.report` is not read as one.
  defp stem(name, branch) when is_binary(branch) do
    with [_, date, rest] <- Regex.run(~r/^(\d{4}-\d{2}-\d{2})-(.+)\.md$/, name) do
      slug = Regex.escape(slug(branch))

      Enum.find_value(@suffixes, fn suffix ->
        stem = String.replace_suffix(rest, suffix, "")

        if String.ends_with?(rest, suffix) and Regex.match?(~r/^#{slug}(-\d+)?$/, stem),
          do: "#{date}-#{stem}"
      end)
    end
  end

  defp stem(_name, _branch), do: nil

  defp path(main_checkout, name, suffix),
    do: Path.join(dir(main_checkout), name <> suffix <> ".md")

  # Two mice on one branch name on the same day keep a name each. A name is
  # taken when a mouse holds it or any kind of file does, so a plan kept with
  # no spec never sits beside another mouse's spec.
  defp new_name(main_checkout, entry) do
    base = "#{DateTime.to_date(entry.stamped_at)}-#{slug(entry.branch)}"

    Stream.iterate(1, &(&1 + 1))
    |> Stream.map(fn
      1 -> base
      n -> "#{base}-#{n}"
    end)
    |> Enum.find(fn name ->
      not Storage.kept_as_taken?(name) and
        not Enum.any?(@suffixes, &File.exists?(path(main_checkout, name, &1)))
    end)
  end

  defp slug(branch), do: String.replace(branch, ~r/[^A-Za-z0-9._-]+/, "-")
end
