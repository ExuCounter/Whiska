defmodule Whiska.Adr do
  @moduledoc """
  This repo's own `docs/adr/`, not anything Whiska installs elsewhere
  (ADR-0070).

  A branch writes a new record as `next-<slug>.md` and cites it by a placeholder, `ADR-`
  then `next-<slug>`. The number is only known when the branch lands, so `claim/2` hands
  it out then, rewriting the file name, the README link and every citation in one go.

  `problems/2` is the check `mix test` runs. It tells a placeholder in flight from one
  that landed by asking main: a `next-` file main's tree does not hold yet belongs to the
  branch and is fine; one main holds reached main unclaimed.
  """

  @scanned ~w(.claude .gitignore CLAUDE.md CONTEXT.md README.md mix.exs config docs handoffs lib priv specs test)
  @numbered ~r/^(\d{4})-.+\.md$/
  @placeholder_file ~r/^next-(.+)\.md$/
  @cited ~r/ADR-(\d+)|ADR-next-([a-z0-9-]*[a-z0-9])/
  @linked ~r/\]\((?:\.\/)?((?:\d{4}|next)-[a-z0-9-]+\.md)(?:#[^)]*)?\)/

  @typedoc """
  What git says about `docs/adr/`: the file names on `main`, and on the commit this
  branch was cut from.
  """
  @type view :: %{main: [String.t()], base: [String.t()]}

  @doc "Every collision, dangling citation and unclaimed placeholder, one line each."
  @spec problems(Path.t(), view()) :: [String.t()]
  def problems(root, view) do
    files = adr_files(root)

    collisions(files, view) ++
      dangling(root, files) ++ broken_links(root, files) ++ landed_unclaimed(files, view)
  end

  @doc """
  Give every placeholder in the tree the next free number after both the tree and
  main, in file-name order. Returns `{old, new}` file names. Commits nothing.
  """
  @spec claim(Path.t(), view()) :: [{String.t(), String.t()}]
  def claim(root, view) do
    files = adr_files(root)
    first = highest(files ++ view.main) + 1

    files
    |> Enum.sort()
    |> Enum.flat_map(&placeholder_slug/1)
    |> Enum.with_index(first)
    |> Enum.map(fn {slug, n} -> claim_one(root, slug, String.pad_leading("#{n}", 4, "0")) end)
  end

  @doc "Read `main` and the merge base off git, for `problems/2` and `claim/2`."
  @spec view(Path.t()) :: view()
  def view(root) do
    base = git!(root, ["merge-base", "HEAD", "main"]) |> String.trim()
    %{main: tree(root, "main"), base: tree(root, base)}
  end

  defp tree(root, rev) do
    root
    |> git!(["ls-tree", "--name-only", rev, "docs/adr/"])
    |> String.split("\n", trim: true)
    |> Enum.map(&Path.basename/1)
  end

  defp git!(root, args) do
    case System.cmd("git", args, cd: root, stderr_to_stdout: true) do
      {out, 0} -> out
      {out, _} -> raise "git #{Enum.join(args, " ")} failed in #{root}: #{out}"
    end
  end

  defp collisions(files, view) do
    held_at_cut = view.base |> Enum.flat_map(&number_of/1) |> MapSet.new(fn {n, _} -> n end)

    landed_since_cut =
      Enum.reject(view.main -- view.base, fn name ->
        Enum.any?(number_of(name), fn {n, _} -> n in held_at_cut end)
      end)

    (files ++ landed_since_cut)
    |> Enum.uniq()
    |> Enum.flat_map(&number_of/1)
    |> Enum.group_by(fn {n, _} -> n end, fn {_, name} -> name end)
    |> Enum.filter(fn {_, names} -> length(names) > 1 end)
    |> Enum.sort()
    |> Enum.map(fn {n, names} -> "ADR number #{n} is taken twice: #{Enum.join(names, ", ")}" end)
  end

  defp dangling(root, files) do
    numbers = files |> Enum.flat_map(&number_of/1) |> MapSet.new(fn {n, _} -> n end)
    slugs = files |> Enum.flat_map(&placeholder_slug/1) |> MapSet.new()

    for {path, text} <- scanned(root),
        [whole | groups] <- Regex.scan(@cited, text),
        not resolves?(groups, numbers, slugs),
        uniq: true,
        do: "#{whole} in #{path} cites a record that is not in docs/adr/"
  end

  defp resolves?([n], numbers, _), do: n in numbers
  defp resolves?(["", slug], _, slugs), do: slug in slugs

  defp broken_links(root, files) do
    for name <- ["README.md" | files],
        {:ok, text} <- [File.read(Path.join([root, "docs/adr", name]))],
        [_, target] <- Regex.scan(@linked, text),
        target not in files,
        uniq: true,
        do: "docs/adr/#{name} links to #{target}, which is not there"
  end

  defp landed_unclaimed(files, view) do
    for name <- files, placeholder_slug(name) != [], name in view.main do
      "docs/adr/#{name} reached main without a number; run mix adr.claim and commit"
    end
  end

  defp claim_one(root, slug, number) do
    old = "next-#{slug}.md"
    new = "#{number}-#{slug}.md"
    File.rename!(Path.join([root, "docs/adr", old]), Path.join([root, "docs/adr", new]))
    # The slug must end where the citation does, or a shorter slug eats a longer one.
    cited = ~r/ADR-next-#{Regex.escape(slug)}(?![a-z0-9-]*[a-z0-9])/
    linked = "[next-#{slug}](#{old})"

    for {path, text} <- scanned(root) do
      rewritten =
        text
        |> String.replace(linked, "[#{number}](#{new})")
        |> String.replace(old, new)
        |> then(&Regex.replace(cited, &1, "ADR-#{number}"))

      if rewritten != text, do: File.write!(Path.join(root, path), rewritten)
    end

    {old, new}
  end

  defp adr_files(root) do
    dir = Path.join(root, "docs/adr")
    if File.dir?(dir), do: dir |> File.ls!() |> Enum.reject(&(&1 == "README.md")), else: []
  end

  defp number_of(name) do
    case Regex.run(@numbered, name) do
      [_, n] -> [{n, name}]
      nil -> []
    end
  end

  defp placeholder_slug(name) do
    case Regex.run(@placeholder_file, name) do
      [_, slug] -> [slug]
      nil -> []
    end
  end

  defp highest(names) do
    names
    |> Enum.flat_map(&number_of/1)
    |> Enum.map(fn {n, _} -> String.to_integer(n) end)
    |> Enum.max(fn -> 0 end)
  end

  # Text files only: a binary under priv/ is skipped rather than misread.
  defp scanned(root) do
    @scanned
    |> Enum.map(&Path.join(root, &1))
    |> Enum.flat_map(&walk/1)
    |> Enum.flat_map(fn full ->
      text = File.read!(full)
      if String.valid?(text), do: [{Path.relative_to(full, root), text}], else: []
    end)
  end

  # A symlink is never followed, so neither the check nor the claim leaves the repo.
  defp walk(path) do
    case File.lstat(path) do
      {:ok, %{type: :regular}} ->
        [path]

      {:ok, %{type: :directory}} ->
        path |> File.ls!() |> Enum.flat_map(&walk(Path.join(path, &1)))

      _ ->
        []
    end
  end
end
