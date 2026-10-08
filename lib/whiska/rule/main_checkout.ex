defmodule Whiska.Rule.MainCheckout do
  @moduledoc """
  The one rule v0.0.1 enforces: a mouse may not edit the main checkout.

  ADR-0013 is the why. Every other protection in this design — worktree
  containment, the finish pipeline, diff review, push approval — only covers a mouse's
  own worktree. An edit made directly in the main checkout skips all of it. So the
  rule is mechanical (ADR-0011): a `PreToolUse` hook that can actually block,
  rather than a line in `CLAUDE.md` that a mouse may or may not follow.

  ## What is policed

  Only tools that hand the hook a literal target path: `Write`, `Edit`,
  `MultiEdit` (`file_path`) and `NotebookEdit` (`notebook_path`). Resolving those
  is exact, so the rule never produces a false denial.

  ## Bash

  `Bash` is policed too, but only when a command is **both** mutating and names a
  path resolving into the main checkout. Gating on mutation is what makes this
  tolerable: `cat <main>/CONTEXT.md` and `grep -r <main>` stay allowed, while
  `sed -i`, a redirect, and `git -C <main> commit` do not. A plain substring
  match on the main-checkout path would have denied the reads too, which is the
  kind of false denial that trains people to ignore a hook.

  The mutation judgment is `Whiska.Shell`'s, and it errs towards "mutating"
  whenever it cannot read a command confidently. Here that costs a false denial
  on an exotic-but-harmless command that happens to mention the main checkout —
  rare enough to be worth the containment.

  Each command in a line is judged on its own, against where the shell stands
  when it runs: the payload's `cwd`, moved by any literal `cd` earlier in the
  line and restored when a `( … )` subshell closes. A mutating command run from
  inside the main checkout is denied whatever it names. ADR-0034 records exactly
  which spellings are read and which are allowed unread; in short, this is
  pattern matching over literal text, and a path the text does not spell out —
  another variable, a substitution, a glob — is allowed. A build mouse can
  always write a program into its worktree and run it, so this rule catches
  honest mistakes, not a mouse set on escaping (ADR-0024).

  Reads are never policed, in any tool: the rule is about containment of
  *changes*, not a sandbox.

  ## No carve-out in v0.0.1

  ADR-0013 carves out Whiska's own config files — `dispatch.yml`, the
  `CLAUDE.md` block — as still directly editable. That carve-out is scoped to
  the **main session** editing its own repo's setup, and does not extend to a
  mouse reaching into the main checkout from a worktree: that is the containment
  breach the ADR exists to stop. So this slice denies every main-checkout edit,
  full stop.
  """

  alias Whiska.Layout
  alias Whiska.Shell

  @path_keys %{
    "Write" => "file_path",
    "Edit" => "file_path",
    "MultiEdit" => "file_path",
    "NotebookEdit" => "notebook_path"
  }

  @type decision :: :allow | {:deny, String.t()}

  @doc """
  Decide one tool call.

  Anything this slice does not police — every tool without an explicit target
  path, and every read — is allowed through untouched, leaving the rest of Claude
  Code's own permission machinery to have the final say.

  `opts` matter only to `Bash`: `:cwd` is where the shell stands when the call
  runs, defaulting to the worktree root, and `:home` is what `$HOME` and `~`
  expand to, defaulting to `HOME`.
  """
  @spec decide(String.t(), map(), Layout.t(), keyword()) :: decision()
  def decide(tool_name, tool_input, layout, opts \\ [])

  def decide("Bash", tool_input, %Layout{} = layout, opts) do
    home = Keyword.get_lazy(opts, :home, fn -> System.get_env("HOME") end)

    cwd = Keyword.get(opts, :cwd) || layout.worktree_root

    shell = %{
      cwd: cwd,
      here: canonical(cwd),
      subshells: [],
      judged: MapSet.new(),
      worktree: Layout.canonical(layout.worktree_root),
      main: Layout.canonical(layout.main_checkout)
    }

    tool_input
    |> Map.get("command", "")
    |> expand_home(home)
    |> Shell.segments()
    |> Enum.reduce_while(shell, fn segment, shell ->
      case judge_segment(segment, shell, layout) do
        {:allow, judged} -> {:cont, move(segment, %{shell | judged: judged}, home)}
        denial -> {:halt, denial}
      end
    end)
    |> case do
      {:deny, _} = denial -> denial
      _shell -> :allow
    end
  end

  def decide(tool_name, tool_input, %Layout{} = layout, _opts) do
    with {:ok, key} <- Map.fetch(@path_keys, tool_name),
         {:ok, raw} when is_binary(raw) <- Map.fetch(tool_input, key) do
      raw
      |> resolve(layout.worktree_root)
      |> judge(layout)
    else
      _ -> :allow
    end
  end

  # Reads of the main checkout are fine; only a command that can change
  # something there is a containment breach. A command writes relative to where
  # it runs, so standing in the main checkout is a breach whatever it names —
  # which is what catches a bare `rm CONTEXT.md` after a `cd`.
  defp judge_segment(segment, shell, layout) do
    cond do
      not Shell.mutating?(segment) ->
        {:allow, shell.judged}

      standing_in_main?(shell) ->
        {:deny, reason_standing(shell.cwd, layout)}

      true ->
        segment
        |> targets(shell)
        |> Enum.reject(&MapSet.member?(shell.judged, &1))
        |> Enum.reduce_while({:allow, shell.judged}, fn target, {:allow, judged} ->
          if reaches_main?(Layout.canonical(target), shell) do
            {:halt, {:deny, reason(target, layout)}}
          else
            {:cont, {:allow, MapSet.put(judged, target)}}
          end
        end)
    end
  end

  defp standing_in_main?(%{here: nil}), do: false

  defp standing_in_main?(%{here: here} = shell) do
    within?(here, shell.main) and not within?(here, shell.worktree)
  end

  # Inside the main checkout, or the main checkout itself or a folder above it,
  # which a `rm -rf` takes with it.
  defp reaches_main?(target, shell) do
    not within?(target, shell.worktree) and
      (within?(target, shell.main) or within?(shell.main, target))
  end

  defp within?(path, dir), do: List.starts_with?(Path.split(path), Path.split(dir))

  @absolute ~r{(?<![^\s=<>|&(])/[^\s`;|&<>()]*}

  # Every absolute path anywhere in the text — glued to an operator, or inside a
  # nested `bash -c '…'` the word reader sees as one word — and every relative
  # one. From outside the worktree any bare word can name a folder that matters,
  # so every word counts there.
  defp targets(segment, shell) do
    absolute = @absolute |> Regex.scan(dequote(segment)) |> List.flatten()

    relative =
      if shell.here && within?(shell.here, shell.worktree),
        do: Shell.paths(segment),
        else: segment |> Shell.words() |> Enum.reject(&String.starts_with?(&1, "-"))

    relative
    |> Enum.map(&dequote/1)
    |> Enum.reject(&(&1 == "" or String.contains?(&1, "$")))
    |> Enum.concat(absolute)
    |> Enum.map(&resolve(&1, shell.cwd))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp dequote(text), do: String.replace(text, ~r/["'\\]/, "")

  # Where the shell stands after this segment. A `cd` inside `( … )` is undone
  # at the closing parenthesis. A `nil` cwd is "somewhere unknown": relative
  # paths after it are not judged.
  defp move(segment, shell, home) do
    trimmed = String.trim(segment)
    [opens] = Regex.run(~r/^\(*/, trimmed)
    [closes] = Regex.run(~r/\)*$/, trimmed)
    {opens, closes} = {byte_size(opens), byte_size(closes)}
    subshells = List.duplicate(shell.cwd, opens) ++ shell.subshells
    cwd = cd(segment, shell.cwd, home)

    cwd =
      case Enum.split(subshells, closes) do
        {[], _rest} -> cwd
        {popped, _rest} -> List.last(popped)
      end

    here = if cwd == shell.cwd, do: shell.here, else: canonical(cwd)
    %{shell | cwd: cwd, here: here, subshells: Enum.drop(subshells, closes)}
  end

  defp canonical(nil), do: nil
  defp canonical(path), do: Layout.canonical(path)

  defp cd(segment, cwd, home) do
    if String.contains?(segment, ["cd", "pushd", "popd"]),
      do: cd_words(segment, cwd, home),
      else: cwd
  end

  defp cd_words(segment, cwd, home) do
    words =
      segment
      |> Shell.words()
      |> Enum.map(&(&1 |> String.trim_leading("(") |> dequote()))
      |> Enum.drop_while(&Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_]*=/, &1))
      |> Enum.drop_while(&(&1 in ["command", "builtin"]))

    case words do
      [cmd | args] when cmd in ["cd", "pushd"] -> cd_args(args, cwd, home)
      ["popd" | _] -> nil
      _ -> cwd
    end
  end

  defp cd_args(args, cwd, home) do
    case Enum.drop_while(args, &(String.starts_with?(&1, "-") and &1 != "-")) do
      [] -> home
      ["-" | _] -> nil
      [dir | _] -> cd_to(dir, cwd)
    end
  end

  defp cd_to(dir, cwd) do
    cond do
      String.contains?(dir, "$") -> nil
      String.starts_with?(dir, "/") -> Path.expand(dir)
      is_nil(cwd) -> nil
      true -> Path.expand(dir, cwd)
    end
  end

  defp expand_home(command, home) when is_binary(home) and home != "" do
    command
    |> String.replace(~r/\$\{HOME(?::?[-?=][^}]*)?\}|\$HOME(?![A-Za-z0-9_])/, home)
    |> String.replace(~r{(?<![^\s=<>"'(])~(?=/|\s|$)}, home)
  end

  defp expand_home(command, _home), do: command

  defp resolve(raw, nil), do: if(Path.type(raw) == :absolute, do: Path.expand(raw))
  defp resolve(raw, base), do: Path.expand(raw, base)

  defp judge(nil, _layout), do: :allow

  defp judge(target, layout) do
    cond do
      Layout.inside?(target, layout.worktree_root) -> :allow
      Layout.inside?(target, layout.main_checkout) -> {:deny, reason(target, layout)}
      true -> :allow
    end
  end

  defp reason_standing(cwd, layout) do
    """
    #{reason(cwd, layout)}

    This command runs from there, so anything it writes lands in the main
    checkout. Step back first: `cd #{layout.worktree_root}`
    """
    |> String.trim()
  end

  defp reason(target, %Layout{branch_label: nil} = layout) do
    """
    Whiska denied this edit: #{target} is in the main checkout.

    This session started in #{layout.worktree_root}, which sits under
    `worktrees/` but is no worktree of this repo — so it is no mouse, and it is
    the last place an edit to the main checkout should come from.

    Edits in the main checkout are blocked (ADR-0013) — they bypass worktree
    containment, the finish pipeline, diff review and push approval. If this
    genuinely belongs in the main checkout, that is a decision for the main
    session.
    """
    |> String.trim()
  end

  defp reason(target, layout) do
    """
    Whiska denied this edit: #{target} is outside this mouse's worktree.

    This mouse's worktree is #{layout.worktree_root}
    The main checkout is     #{layout.main_checkout}

    Edits in the main checkout are blocked (ADR-0013) — they bypass worktree
    containment, the finish pipeline, diff review and push approval. Make this change inside
    the worktree instead; if it genuinely belongs in the main checkout, that is a
    decision for the main session, not for a mouse.
    """
    |> String.trim()
  end
end
