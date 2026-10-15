defmodule Whiska.MergeRequestOpenTest do
  @moduledoc """
  `whiska merge-request open`, which a herdr key runs from the focused pane's
  directory, over a real git repo and a fake `gh` and `glab` on PATH.
  """
  # Serial: the test puts fake forge tools first on the OS PATH.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Whiska.CLI
  alias Whiska.Storage
  alias Whiska.Test.GitRepo

  setup do
    root = Path.join(System.tmp_dir!(), "whiska-mr-open-#{System.unique_integer([:positive])}")
    repo = GitRepo.create(root)
    path = Path.join(repo.checkout, "worktrees/feat-a")
    {_, 0} = System.cmd("git", ["worktree", "add", "-q", "-b", "feat-a", path], cd: repo.checkout)
    calls = Path.join(root, "calls")
    bin = Path.join(root, "bin")
    File.mkdir_p!(bin)

    for tool <- ~w(gh glab) do
      File.write!(Path.join(bin, tool), """
      #!/bin/sh
      printf '#{tool} %s\\n' "$*" >> '#{calls}'
      """)

      File.chmod!(Path.join(bin, tool), 0o755)
    end

    was = System.get_env("PATH")
    System.put_env("PATH", bin <> ":" <> was)

    Storage.within(repo.checkout, fn ->
      {:ok, _} = Storage.record_mouse(%{mouse_id: "m1", path: path, branch: "feat-a"})
    end)

    on_exit(fn ->
      System.put_env("PATH", was)
      File.rm_rf!(root)
    end)

    {:ok, repo: repo, path: path, calls: calls}
  end

  defp open(cwd) do
    parent = self()

    err =
      capture_io(:stderr, fn ->
        out =
          capture_io(fn -> send(parent, {:code, CLI.run(["merge-request", "open"], cwd)}) end)

        send(parent, {:out, out})
      end)

    assert_received {:code, code}
    assert_received {:out, out}
    {code, out <> err}
  end

  defp record(repo, url) do
    Storage.within(repo.checkout, fn -> {:ok, _} = Storage.record_merge_request("m1", url) end)
  end

  test "opens the GitHub pull request of the mouse whose worktree holds the directory", %{
    repo: repo,
    path: path,
    calls: calls
  } do
    record(repo, "https://github.com/acme/app/pull/12")
    File.mkdir_p!(Path.join(path, "lib"))

    assert {0, _} = open(Path.join(path, "lib"))
    assert File.read!(calls) == "gh pr view https://github.com/acme/app/pull/12 --web\n"
  end

  test "opens a GitLab merge request through glab, by its number and project", %{
    repo: repo,
    path: path,
    calls: calls
  } do
    record(repo, "https://gitlab.example.com/acme/app/-/merge_requests/9134")

    assert {0, _} = open(path)

    assert File.read!(calls) ==
             "glab mr view 9134 --web --repo https://gitlab.example.com/acme/app\n"
  end

  test "a mouse with no merge request recorded says so, and opens nothing", %{
    path: path,
    calls: calls
  } do
    assert {1, said} = open(path)
    assert said =~ "feat-a has no merge request"
    refute File.exists?(calls)
  end

  test "a directory that is no mouse's worktree says so", %{repo: repo, calls: calls} do
    assert {1, said} = open(repo.checkout)
    assert said =~ "not in a mouse's worktree"
    refute File.exists?(calls)
  end
end
