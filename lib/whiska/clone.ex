defmodule Whiska.Clone do
  @moduledoc """
  Stocking a new worktree with the main checkout's untracked folders, before
  Claude starts (ADR-0069: `whiska shape` runs it).

  A worktree holds only committed files, so a fresh mouse has no `deps`, `_build`
  or `node_modules`, and none of the person's untracked files. The folders are
  cloned copy-on-write — `cp -c` on macOS, `cp --reflink=auto` on Linux — never
  symlinked, so each mouse owns its copy and a change in one reaches no other.

  **What is cloned.** The marker defaults: `mix.exs` gives `deps` and `_build`,
  `package.json` gives `node_modules`. They are cloned only when the worktree's
  lockfile equals the main checkout's; otherwise they are skipped and the report
  says why. Not `.venv`: a virtualenv holds absolute paths into the main
  checkout.

  **The override** is `<main-checkout>/.git/whiska/clone`, in the house beside
  the doorstep and the backstop, never in the repo's tree. Plain text (the form
  ADR-0039 gives the open-houses record): one path per line, relative to the
  repo root, `#` starts a comment, and a lone `off` turns cloning off. Listed
  paths are added to the defaults and cloned without the lockfile check.

  **Never overwrite.** A path the worktree already has as a folder (it holds
  tracked files) gets only its missing entries cloned.

  **Hidden from git.** Each entry cloned is added to the main checkout's
  `.git/info/exclude` unless git already ignores it, so a copy is never a change
  to commit and never stops the owl taking the worktree down (ADR-0061). Lines
  are never removed: the next worktree needs them.

  A clone never fails the spawn. Whatever goes wrong becomes the report line.
  """

  @override ".git/whiska/clone"

  @markers [
    {"mix.exs", "mix.lock", ["deps", "_build"]},
    {"package.json", nil, ["node_modules"]}
  ]
  @node_lockfiles ~w(package-lock.json yarn.lock pnpm-lock.yaml)

  @doc """
  Clone into `worktree` from `main_checkout`. Returns the one line the spawn
  reports: what was cloned and how long it took, or why nothing was.
  """
  @spec run(Path.t(), Path.t()) :: String.t()
  def run(main_checkout, worktree) do
    {micros, line} = :timer.tc(fn -> safely(main_checkout, worktree) end)
    String.replace(line, "{time}", seconds(micros))
  end

  defp safely(main, worktree) do
    case read_override(main) do
      :off ->
        "cloning is off for this repo"

      {:paths, extras} ->
        {inside, outside} = Enum.split_with(extras, &inside_repo?/1)
        {defaults, skipped} = defaults(main, worktree)
        result = clone_all(main, worktree, defaults ++ inside)

        refused =
          if outside != [], do: ["#{Enum.join(outside, ", ")} is outside the repo"], else: []

        report(result, skipped ++ refused ++ hide(main, worktree, result.cloned))
    end
  rescue
    error -> "could not clone (#{Exception.message(error)})"
  end

  defp read_override(main) do
    lines =
      case File.read(Path.join(main, @override)) do
        {:ok, text} -> text |> String.split("\n") |> Enum.map(&without_comment/1)
        {:error, _} -> []
      end

    lines = Enum.reject(lines, &(&1 == ""))
    if "off" in lines, do: :off, else: {:paths, Enum.uniq(lines)}
  end

  defp without_comment(line), do: line |> String.split("#", parts: 2) |> hd() |> String.trim()

  defp inside_repo?(path) do
    Path.type(path) == :relative and ".." not in Path.split(path)
  end

  # The marker folders whose lockfile matches, and a reason per marker whose
  # lockfile does not.
  defp defaults(main, worktree) do
    @markers
    |> Enum.filter(fn {marker, _, _} -> File.regular?(Path.join(main, marker)) end)
    |> Enum.reduce({[], []}, fn {_marker, lock, folders}, {paths, skipped} ->
      case lockfile_gate(main, worktree, lock) do
        :ok ->
          {paths ++ folders, skipped}

        {why, name} ->
          {paths,
           skipped ++ ["#{Enum.join(folders, ", ")} skipped: #{lockfile_reason(why, name)}"]}
      end
    end)
  end

  defp lockfile_gate(main, worktree, nil) do
    name = Enum.find(@node_lockfiles, &File.regular?(Path.join(main, &1))) || hd(@node_lockfiles)
    lockfile_gate(main, worktree, name)
  end

  defp lockfile_gate(main, worktree, name) do
    case {File.read(Path.join(main, name)), File.read(Path.join(worktree, name))} do
      {{:ok, same}, {:ok, same}} -> :ok
      {{:error, _}, _} -> {:no_lockfile, name}
      _ -> {:differs, name}
    end
  end

  defp lockfile_reason(:no_lockfile, name), do: "the main checkout has no #{name} to compare"
  defp lockfile_reason(:differs, name), do: "#{name} differs from the main checkout's"

  defp clone_all(main, worktree, paths) do
    paths
    |> Enum.flat_map(&clone_path(main, worktree, &1))
    |> Enum.reduce(%{cloned: [], missing: [], failed: []}, fn
      {:cloned, entries}, acc -> %{acc | cloned: acc.cloned ++ entries}
      {:missing, path}, acc -> %{acc | missing: acc.missing ++ [path]}
      {:failed, path, why}, acc -> %{acc | failed: acc.failed ++ ["#{path}: #{why}"]}
    end)
  end

  defp clone_path(main, worktree, path) do
    src = Path.join(main, path)
    dest = Path.join(worktree, path)

    with true <- plain_ancestors?(main, path) and plain_ancestors?(worktree, path) do
      case {File.lstat(src), File.lstat(dest)} do
        {{:error, _}, _} ->
          [{:missing, path}]

        {{:ok, _}, {:error, _}} ->
          [clone_entry(src, dest, path)]

        {{:ok, %{type: :directory}}, {:ok, %{type: :directory}}} ->
          merge_missing(src, dest, path)

        {{:ok, _}, {:ok, _}} ->
          [{:failed, path, "something is already in the way in the worktree"}]
      end
    else
      false -> [{:failed, path, "it passes through a symlink"}]
    end
  end

  # No folder above the path itself may be a symlink, in either checkout: it
  # could lead the copy, or what is read, outside the repo.
  defp plain_ancestors?(root, path) do
    path
    |> Path.split()
    |> Enum.drop(-1)
    |> Enum.scan(root, &Path.join(&2, &1))
    |> Enum.all?(&(not symlink?(&1)))
  end

  defp symlink?(path), do: match?({:ok, %{type: :symlink}}, File.lstat(path))

  defp merge_missing(src, dest, path) do
    src
    |> File.ls!()
    |> Enum.sort()
    |> Enum.reject(&match?({:ok, _}, File.lstat(Path.join(dest, &1))))
    |> Enum.map(&clone_entry(Path.join(src, &1), Path.join(dest, &1), Path.join(path, &1)))
  end

  defp clone_entry(src, dest, path) do
    if String.contains?(path, ["\n", "\r"]) do
      {:failed, inspect(path), "its name has a line break"}
    else
      File.mkdir_p!(Path.dirname(dest))

      case System.cmd("cp", cp_args(src, dest), stderr_to_stdout: true) do
        {_, 0} -> {:cloned, [path]}
        {out, _} -> {:failed, path, String.trim(out)}
      end
    end
  end

  defp cp_args(src, dest) do
    case :os.type() do
      {:unix, :darwin} -> ["-cR", src, dest]
      _ -> ["-R", "--reflink=auto", src, dest]
    end
  end

  # Each cloned entry goes into the main checkout's exclude file, which every
  # worktree reads, unless git already ignores it. Returns a note per failure.
  defp hide(main, worktree, entries) do
    for entry <- entries,
        not ignored?(worktree, entry),
        {:error, reason} <- [Whiska.Spec.ignore(main, "/" <> escape(entry))] do
      "could not hide #{entry} from git (#{inspect(reason)})"
    end
  end

  defp ignored?(worktree, entry) do
    args = ["check-ignore", "-q", "--", entry]
    {_, code} = System.cmd("git", args, cd: worktree, stderr_to_stdout: true)
    code == 0
  end

  # A gitignore pattern's own characters, taken literally.
  defp escape(entry) do
    entry
    |> String.replace(~r/[\\*?\[]/, "\\\\\\0")
    |> String.replace(~r/ +$/, fn spaces -> String.replace(spaces, " ", "\\ ") end)
    |> then(&if String.starts_with?(&1, ["!", "#"]), do: "\\" <> &1, else: &1)
  end

  defp report(%{cloned: cloned, missing: missing, failed: failed}, skipped) do
    parts =
      [
        if(cloned != [], do: "cloned #{Enum.join(cloned, ", ")} in {time}"),
        if(missing != [], do: "#{Enum.join(missing, ", ")} is not in the main checkout")
      ] ++ skipped ++ [if(failed != [], do: "could not clone #{Enum.join(failed, "; ")}")]

    case Enum.reject(parts, &is_nil/1) do
      [] -> "nothing to clone"
      parts -> Enum.join(parts, "; ")
    end
  end

  defp seconds(micros), do: :erlang.float_to_binary(micros / 1_000_000, decimals: 2) <> "s"
end
