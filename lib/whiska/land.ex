defmodule Whiska.Land do
  @moduledoc """
  `whiska land`: copy a finished branch's own commits onto the branch the main
  checkout is on, oldest first and merges from its base left out, then run the
  repo's checks.

  Files the mouse left uncommitted stop the landing and are named, so the
  person sees each one before it reaches a commit; `--commit <file>` commits
  them in the worktree with the message in that file, then lands. Whiska's own
  files are never committed.

  A clash lands nothing: the checkout is put back as it was. A failing check
  leaves the copies where they are, for the person to fix or take back. The
  worktree and the branch stay either way: the owl takes them down once it
  sees the work in the base (ADR-0061).

  The checks are the `checks:` line under `## Finish` in the main checkout's
  `CLAUDE.md` (ADR-0049), read before anything is copied, so a branch cannot
  name the checks its own landing runs.
  """

  alias Whiska.Git
  alias Whiska.Inbox
  alias Whiska.Schema.Mouse

  @whiska_files ~w(.whiska-mouse .whiska-spec.md .whiska-research.md .whiska-plan.md
                   .whiska-brief.md .whiska-inbox)

  @doc "Land `mouse`'s branch onto `main_checkout`, committing first with the message in `commit`."
  @spec run(Path.t(), Mouse.t(), Path.t() | nil) :: {:ok, String.t()} | {:error, String.t()}
  def run(main_checkout, %Mouse{} = mouse, commit) do
    with :ok <- no_merge_request(mouse),
         {:ok, onto} <- onto(main_checkout),
         checks = checks(main_checkout),
         :ok <- commit_left(mouse, commit, "land"),
         {:ok, %{base: base, commits: commits}} <- own_commits(main_checkout, mouse),
         :ok <- something(mouse.branch, base, commits),
         {:ok, before} <- Git.head(main_checkout),
         :ok <- cherry_pick(main_checkout, commits) do
      landed = "Landed #{count(commits)} from #{mouse.branch} onto #{onto}."

      case run_checks(main_checkout, checks) do
        :none ->
          {:ok, landed <> " This repo names no checks under ## Finish in CLAUDE.md, so none ran."}

        :ok ->
          {:ok, landed <> " Checks pass: #{Enum.join(checks, ", ")}."}

        {:failed, check, output} ->
          {:error,
           "#{landed} The check `#{check}` failed:\n\n#{output}\n\nThe copies stay on " <>
             "#{onto}. `git reset --keep #{String.slice(before, 0, 12)}` takes them back."}
      end
    end
  end

  defp no_merge_request(%Mouse{merge_request_url: nil}), do: :ok

  defp no_merge_request(%Mouse{branch: branch, merge_request_url: url}) do
    {:error,
     "#{branch} has a merge request open, #{url}. Landing beside it would copy its work " <>
       "and leave it open; it lands through the merge request."}
  end

  defp onto(main_checkout) do
    case Git.head_branch(main_checkout) do
      {:ok, branch} -> {:ok, branch}
      {:error, _} -> {:error, "the main checkout is on no branch, so there is nowhere to land."}
    end
  end

  @doc """
  The commands the `checks:` line under `## Finish` in `checkout`'s `CLAUDE.md`
  names, split at commas.
  """
  @spec checks(Path.t()) :: [String.t()]
  def checks(checkout) do
    with {:ok, text} <- File.read(Path.join(checkout, "CLAUDE.md")),
         [_, finish] <- Regex.run(~r/^## Finish[ \t]*\n(.*?)(?=^## |\z)/ms, text),
         [_, line] <- Regex.run(~r/^checks:[ \t]*(.+)$/m, finish) do
      line |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
    else
      _ -> []
    end
  end

  @doc """
  Commit, in the mouse's worktree, the files it left, with the message in
  `commit`; with no message, refuse and name each file, so the person sees
  them before they reach a commit. `command` is the one that asked.
  """
  @spec commit_left(Mouse.t(), Path.t() | nil, String.t()) :: :ok | {:error, String.t()}
  def commit_left(%Mouse{path: path, branch: branch}, commit, command) do
    case {Git.uncommitted(path), commit} do
      {{:ok, []}, _} ->
        :ok

      {{:ok, files}, nil} ->
        {:error,
         "#{branch} has files not committed, so nothing was done:\n\n" <>
           Enum.map_join(files, "", &"  #{&1}\n") <>
           "\n`whiska #{command} <id> --commit <message-file>` commits them first, with " <>
           "the message in that file."}

      {{:ok, _files}, file} ->
        commit(path, file)

      {{:error, reason}, _} ->
        {:error, "could not read #{path} (#{inspect(reason)}), so nothing was done."}
    end
  end

  defp commit(worktree, file) do
    keep_out = Enum.map(@whiska_files, &":!#{&1}")

    with {:ok, _} <- Inbox.read(file),
         {_, 0} <- git(worktree, ["add", "-A", "--", "." | keep_out]),
         {_, 0} <- git(worktree, ["commit", "--quiet", "-F", Path.expand(file)]) do
      :ok
    else
      {:error, message} -> {:error, message}
      {out, _} -> {:error, "git would not commit in #{worktree}: #{String.trim(out)}"}
    end
  end

  defp own_commits(main_checkout, mouse) do
    case Git.own_commits(main_checkout, mouse.branch, mouse.base) do
      {:ok, own} ->
        {:ok, own}

      {:error, reason} ->
        {:error, "could not read #{mouse.branch}'s commits (#{inspect(reason)})."}
    end
  end

  defp something(branch, base, []), do: {:error, "#{branch} has nothing beyond #{base} to land."}
  defp something(_branch, _base, _commits), do: :ok

  defp cherry_pick(main_checkout, commits) do
    case git(main_checkout, ["cherry-pick" | commits]) do
      {_, 0} ->
        :ok

      {out, _} ->
        {clashing, _} = git(main_checkout, ["diff", "--name-only", "--diff-filter=U"])
        git(main_checkout, ["cherry-pick", "--abort"])

        {:error,
         "the branch's work clashes with this checkout, so nothing landed. " <>
           clash(clashing, out)}
    end
  end

  defp clash("", out), do: "Git said:\n\n#{String.trim(out)}"
  defp clash(files, _out), do: "In:\n\n" <> Enum.map_join(String.split(files), "", &"  #{&1}\n")

  defp run_checks(_checkout, []), do: :none

  defp run_checks(checkout, checks) do
    Enum.reduce_while(checks, :ok, fn check, :ok ->
      case System.cmd("sh", ["-c", check], cd: checkout, stderr_to_stdout: true) do
        {_, 0} -> {:cont, :ok}
        {out, _} -> {:halt, {:failed, check, tail(out)}}
      end
    end)
  end

  defp tail(output) do
    output |> String.split("\n") |> Enum.take(-30) |> Enum.join("\n") |> String.trim()
  end

  defp count([_]), do: "1 commit"
  defp count(commits), do: "#{length(commits)} commits"

  defp git(dir, args), do: System.cmd("git", args, cd: dir, stderr_to_stdout: true)
end
