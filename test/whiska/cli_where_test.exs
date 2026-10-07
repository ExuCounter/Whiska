defmodule Whiska.CLIWhereTest do
  @moduledoc """
  `whiska where` — where a hook is running, as one stable line of JSON, over
  real git repos with herdr faked at the boundary ADR-0031 names.
  """
  # Serial: the test sets HERDR_SOCKET_PATH in the OS env.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import Mox

  alias Whiska.CLI
  alias Whiska.Herdr.Mock, as: Herdr
  alias Whiska.Layout
  alias Whiska.Test.GitRepo

  setup :verify_on_exit!

  @socket "/fake/herdr.sock"

  setup do
    root = Path.join(System.tmp_dir!(), "whiska-where-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    # Resolved, as git resolves it: /var is a symlink to /private/var on macOS.
    repo = GitRepo.create(Layout.canonical(root))

    was = System.get_env("HERDR_SOCKET_PATH")
    System.put_env("HERDR_SOCKET_PATH", @socket)

    on_exit(fn ->
      if was,
        do: System.put_env("HERDR_SOCKET_PATH", was),
        else: System.delete_env("HERDR_SOCKET_PATH")

      File.rm_rf!(root)
    end)

    {:ok, repo: repo}
  end

  # A worktree laid out the way spawn-worktree lays it out: under the main
  # checkout's own `worktrees/` folder.
  defp worktree(repo, branch) do
    path = Path.join([repo.checkout, "worktrees", branch])
    GitRepo.git!(repo.checkout, ["worktree", "add", "-b", branch, path])
    path
  end

  defp where(cwd) do
    out = capture_io(fn -> send(self(), {:code, CLI.run(["where"], cwd)}) end)
    assert_received {:code, code}
    {code, out}
  end

  defp main_workspace(checkout, answer) do
    expect(Herdr, :main_workspace, fn @socket, ^checkout -> answer end)
  end

  test "in a worktree: its root, the whole branch, the main checkout and its workspace",
       %{repo: repo} do
    path = worktree(repo, "feat/csv-page")
    main_workspace(repo.checkout, {:ok, "w3"})

    assert where(path) ==
             {0,
              ~s({"version":1,"worktree":"#{path}","branch":"feat/csv-page",) <>
                ~s("main_checkout":"#{repo.checkout}","main_workspace":"w3"}\n)}
  end

  test "a subfolder of a worktree answers for the worktree", %{repo: repo} do
    path = worktree(repo, "feat-a")
    sub = Path.join(path, "lib/deep")
    File.mkdir_p!(sub)
    main_workspace(repo.checkout, {:ok, "w3"})

    {0, out} = where(sub)
    assert %{"worktree" => ^path, "branch" => "feat-a"} = JSON.decode!(out)
  end

  test "in the main checkout: no worktree or branch, but the checkout and its workspace",
       %{repo: repo} do
    main_workspace(repo.checkout, {:ok, "w3"})

    assert where(repo.checkout) ==
             {0,
              ~s({"version":1,"worktree":null,"branch":null,) <>
                ~s("main_checkout":"#{repo.checkout}","main_workspace":"w3"}\n)}
  end

  test "a folder under worktrees/ that is no checkout of its own is the main checkout",
       %{repo: repo} do
    worktree(repo, "feat/x")
    main_workspace(repo.checkout, {:ok, "w3"})

    {0, out} = where(Path.join([repo.checkout, "worktrees", "feat"]))

    assert %{"worktree" => nil, "branch" => nil, "main_checkout" => checkout} =
             JSON.decode!(out)

    assert checkout == repo.checkout
  end

  test "outside any repo every field but the version is null", %{repo: repo} do
    stub(Herdr, :main_workspace, fn _, _ -> flunk("herdr asked about no checkout") end)

    assert where(repo.root) ==
             {0,
              ~s({"version":1,"worktree":null,"branch":null,) <>
                ~s("main_checkout":null,"main_workspace":null}\n)}
  end

  test "a linked worktree outside worktrees/ is not Whiska's, so it answers null",
       %{repo: repo} do
    elsewhere = Path.join(repo.root, "elsewhere")
    GitRepo.git!(repo.checkout, ["worktree", "add", "-b", "stray", elsewhere])

    {0, out} = where(elsewhere)
    assert %{"worktree" => nil, "main_checkout" => nil} = JSON.decode!(out)
  end

  test "herdr failing leaves the workspace null and still exits 0", %{repo: repo} do
    path = worktree(repo, "feat-a")
    main_workspace(repo.checkout, {:error, :econnrefused})

    {0, out} = where(path)
    checkout = repo.checkout

    assert %{"branch" => "feat-a", "main_checkout" => ^checkout, "main_workspace" => nil} =
             JSON.decode!(out)
  end

  test "no herdr running at all leaves the workspace null and still exits 0", %{repo: repo} do
    System.delete_env("HERDR_SOCKET_PATH")
    was_home = System.get_env("HOME")
    System.put_env("HOME", repo.root)
    on_exit(fn -> System.put_env("HOME", was_home) end)
    stub(Herdr, :main_workspace, fn _, _ -> flunk("herdr asked with no socket") end)

    {0, out} = where(repo.checkout)
    assert %{"main_checkout" => _, "main_workspace" => nil} = JSON.decode!(out)
  end

  test "a herdr that never answers costs a hook at most half a second", %{repo: repo} do
    expect(Herdr, :main_workspace, fn _, _ -> Process.sleep(5_000) end)

    {micros, {0, out}} = :timer.tc(fn -> where(repo.checkout) end)
    assert %{"main_checkout" => _, "main_workspace" => nil} = JSON.decode!(out)
    assert micros < 1_000_000
  end

  test "a herdr reply that makes the lookup raise is a null workspace, not a crash",
       %{repo: repo} do
    expect(Herdr, :main_workspace, fn _, _ -> raise "malformed reply" end)

    {0, out} = where(repo.checkout)
    assert %{"main_workspace" => nil} = JSON.decode!(out)
  end

  test "a submodule is not a main checkout", %{repo: repo} do
    sub = Path.join(repo.root, "lib-src")
    File.mkdir_p!(sub)
    GitRepo.git!(sub, ["init", "-b", "main"])
    GitRepo.commit!(sub, "lib.txt", "lib")

    GitRepo.git!(repo.checkout, [
      "-c",
      "protocol.file.allow=always",
      "submodule",
      "add",
      sub,
      "vendor/lib"
    ])

    {0, out} = where(Path.join(repo.checkout, "vendor/lib"))
    assert %{"worktree" => nil, "main_checkout" => nil} = JSON.decode!(out)
  end

  test "no workspace open on the main checkout is a null workspace", %{repo: repo} do
    main_workspace(repo.checkout, {:ok, nil})

    {0, out} = where(repo.checkout)
    assert %{"main_workspace" => nil} = JSON.decode!(out)
  end

  test "a branch name full of shell characters comes back as plain JSON", %{repo: repo} do
    branch = ~s(feat/$HOME'"`x`)
    path = worktree(repo, branch)
    main_workspace(repo.checkout, {:ok, "w3"})

    {0, out} = where(path)
    assert %{"branch" => ^branch} = JSON.decode!(out)
  end
end
