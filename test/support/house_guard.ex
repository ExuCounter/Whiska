defmodule Whiska.Test.HouseGuard do
  @moduledoc """
  The guard that keeps the suite out of every real house.

  A mouse's `mix test` once opened the main checkout's own database and applied
  the branch's migrations to it, through a hook payload with no `cwd` that fell
  back to the worktree the suite ran in. `config/test.exs` installs `check/1`
  as `Whiska.Storage`'s guard: a house outside the run's temp folder is refused
  before anything is created, and the run fails at exit. Refusing alone is not
  enough — `Whiska.Isolated` turns any error into a fallback, which is how
  that leak stayed green.
  """

  @expected :whiska_house_guard_expected

  @doc "Allow a house under the temp folder; refuse, loudly, any other."
  @spec check(Path.t()) :: :ok | {:error, {:outside_test_area, Path.t()}}
  def check(path) do
    if Enum.any?(temp_folders(), &inside?(path, &1)) do
      :ok
    else
      unless Process.get(@expected), do: report(path)
      {:error, {:outside_test_area, path}}
    end
  end

  @doc "Run `work` in which a refusal is the point, so it does not fail the run."
  @spec expect_refusal((-> result)) :: result when result: term()
  def expect_refusal(work) do
    Process.put(@expected, true)

    try do
      work.()
    after
      Process.delete(@expected)
    end
  end

  # git names a checkout by its resolved path, so on macOS a house under
  # `/var/folders/…` arrives as `/private/var/folders/…`: both spellings count.
  # Read once per run: every house a test opens asks.
  defp temp_folders do
    with nil <- :persistent_term.get(__MODULE__, nil) do
      tmp = System.tmp_dir!()
      {resolved, 0} = System.cmd("pwd", ["-P"], cd: tmp)
      folders = [tmp, String.trim(resolved)]
      :persistent_term.put(__MODULE__, folders)
      folders
    end
  end

  defp inside?(path, root) do
    String.starts_with?(Path.expand(path), String.trim_trailing(Path.expand(root), "/") <> "/")
  end

  defp report(path) do
    {:current_stacktrace, [_ | stacktrace]} = Process.info(self(), :current_stacktrace)

    IO.puts(:stderr, """

    #{IO.ANSI.red()}A test opened a house outside the run's temp folder.#{IO.ANSI.reset()}
      #{path}
    #{Exception.format_stacktrace(stacktrace)}
    Give the hook payload or the command a `cwd` in the test's own temp folder.
    This run fails.
    """)

    System.at_exit(fn _ -> exit({:shutdown, 1}) end)
  end
end
