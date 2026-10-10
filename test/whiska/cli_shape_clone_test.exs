defmodule Whiska.CLIShapeCloneTest do
  @moduledoc """
  `whiska shape` also stocks the new worktree with the main checkout's untracked
  folders, copy-on-write, before Claude starts. A real git repo and a real linked
  worktree, since what git ignores and which files are tracked is git's to say
  (ADR-0031).
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Whiska.CLI
  alias Whiska.Test.GitRepo

  setup do
    root = Path.join(System.tmp_dir!(), "whiska-clone-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)
    repo = GitRepo.create(root)
    {:ok, main: repo.checkout}
  end

  defp elixir_project(main, opts \\ []) do
    GitRepo.commit!(main, "mix.exs", "defmodule M do end")
    GitRepo.commit!(main, "mix.lock", "%{}")
    if opts[:ignore], do: GitRepo.commit!(main, ".gitignore", "deps/\n_build/\n")
    File.mkdir_p!(Path.join(main, "deps/foo"))
    File.write!(Path.join(main, "deps/foo/foo.ex"), "foo")
    File.mkdir_p!(Path.join(main, "_build/dev"))
    File.write!(Path.join(main, "_build/dev/beam"), "beam")
  end

  # {exit code, stdout, stderr} of `whiska shape` run in the worktree.
  defp shape(worktree, args \\ ["build"]) do
    {out, stderr} =
      with_io(:stderr, fn ->
        capture_io(fn -> send(self(), {:code, CLI.run(["shape" | args], worktree)}) end)
      end)

    assert_received {:code, code}
    {code, out, stderr}
  end

  defp worktree(main, branch) do
    path = Path.join([main, "worktrees", branch])

    {_, 0} =
      System.cmd("git", ["worktree", "add", "-b", branch, path], cd: main, stderr_to_stdout: true)

    path
  end

  defp override(main, text) do
    path = Path.join(main, ".git/whiska/clone")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, text)
  end

  defp exclude(main) do
    case File.read(Path.join(main, ".git/info/exclude")) do
      {:ok, text} -> String.split(text, "\n", trim: true)
      _ -> []
    end
  end

  defp status(dir), do: System.cmd("git", ["status", "--porcelain"], cd: dir) |> elem(0)

  test "clones deps and _build into a fresh worktree as its own copy, and says so", %{
    main: main
  } do
    elixir_project(main)
    worktree = worktree(main, "feat-a")

    {0, _out, stderr} = shape(worktree)

    assert File.read!(Path.join(worktree, "deps/foo/foo.ex")) == "foo"
    assert File.read!(Path.join(worktree, "_build/dev/beam")) == "beam"
    assert stderr =~ "cloned deps, _build"

    File.write!(Path.join(worktree, "deps/foo/foo.ex"), "changed")
    assert File.read!(Path.join(main, "deps/foo/foo.ex")) == "foo"
  end

  test "clones node_modules for a package.json project", %{main: main} do
    GitRepo.commit!(main, "package.json", "{}")
    GitRepo.commit!(main, "package-lock.json", "{}")
    File.mkdir_p!(Path.join(main, "node_modules/left-pad"))
    File.write!(Path.join(main, "node_modules/left-pad/i.js"), "x")
    worktree = worktree(main, "feat-n")

    {0, _out, stderr} = shape(worktree)

    assert File.exists?(Path.join(worktree, "node_modules/left-pad/i.js"))
    assert stderr =~ "cloned node_modules"
  end

  test "skips the marker folders when the lockfile differs, and says why", %{
    main: main
  } do
    elixir_project(main)
    worktree = worktree(main, "feat-b")
    File.write!(Path.join(worktree, "mix.lock"), "%{changed: true}")

    {0, _out, stderr} = shape(worktree)

    refute File.exists?(Path.join(worktree, "deps"))
    assert stderr =~ "mix.lock differs"
  end

  test "clones the paths the override lists, lockfile or not, and hides each from git", %{
    main: main
  } do
    elixir_project(main, ignore: true)
    File.write!(Path.join(main, ".env"), "SECRET=1")
    override(main, "# my extras\n.env\n")
    worktree = worktree(main, "feat-c")
    File.write!(Path.join(worktree, "mix.lock"), "%{changed: true}")

    {0, _out, stderr} = shape(worktree)

    assert File.read!(Path.join(worktree, ".env")) == "SECRET=1"
    assert stderr =~ ".env"
    assert "/.env" in exclude(main)
    refute status(worktree) =~ ".env"
  end

  test "adds only the missing entries of a listed folder that already exists", %{
    main: main
  } do
    File.mkdir_p!(Path.join(main, ".claude/skills/tracked"))
    GitRepo.commit!(main, ".claude/skills/tracked/SKILL.md", "main version")
    File.mkdir_p!(Path.join(main, ".claude/skills/duty"))
    File.write!(Path.join(main, ".claude/skills/duty/SKILL.md"), "duty")
    File.write!(Path.join(main, ".claude/skills/tracked/SKILL.md"), "locally edited")
    override(main, ".claude/skills\n")
    worktree = worktree(main, "feat-d")

    {0, _out, _stderr} = shape(worktree)

    assert File.read!(Path.join(worktree, ".claude/skills/duty/SKILL.md")) == "duty"
    assert File.read!(Path.join(worktree, ".claude/skills/tracked/SKILL.md")) == "main version"
    assert "/.claude/skills/duty" in exclude(main)
    refute "/.claude/skills/" in exclude(main)
    refute "/.claude/skills/tracked" in exclude(main)
    assert status(worktree) == ""
  end

  test "an `off` line turns cloning off", %{main: main} do
    elixir_project(main)
    override(main, "off # not for this repo\n")
    worktree = worktree(main, "feat-e")

    {0, _out, stderr} = shape(worktree)

    refute File.exists?(Path.join(worktree, "deps"))
    assert stderr =~ "cloning is off"
  end

  test "a listed path missing from main is named", %{main: main} do
    override(main, "nope/missing\n")
    worktree = worktree(main, "feat-f")

    {0, _out, stderr} = shape(worktree)

    assert stderr =~ "nope/missing is not in the main checkout"
  end

  test "a comment may follow a path on its line", %{main: main} do
    File.write!(Path.join(main, ".env"), "x")
    override(main, ".env   # local secrets\n")
    worktree = worktree(main, "feat-cm")

    {0, _out, _stderr} = shape(worktree)

    assert File.read!(Path.join(worktree, ".env")) == "x"
  end

  test "a project with no lockfile is skipped and the reason names the missing file", %{
    main: main
  } do
    GitRepo.commit!(main, "mix.exs", "defmodule M do end")
    File.mkdir_p!(Path.join(main, "deps"))
    worktree = worktree(main, "feat-nl")

    {0, _out, stderr} = shape(worktree)

    refute File.exists?(Path.join(worktree, "deps"))
    assert stderr =~ "no mix.lock to compare"
  end

  test "an entry with a line break in its name is refused, and the others still clone", %{
    main: main
  } do
    File.mkdir_p!(Path.join(main, "priv"))
    GitRepo.commit!(main, "priv/tracked.txt", "t")
    File.write!(Path.join(main, "priv/ok.txt"), "ok")
    File.write!(Path.join(main, "priv/bad\n*"), "bad")
    override(main, "priv\n")
    worktree = worktree(main, "feat-nl2")

    {0, _out, stderr} = shape(worktree)

    assert File.read!(Path.join(worktree, "priv/ok.txt")) == "ok"
    assert "/priv/ok.txt" in exclude(main)
    refute "*" in exclude(main)
    assert stderr =~ "line break"
  end

  test "a listed path through a symlink is refused, in either checkout", %{main: main} do
    elsewhere = Path.join(Path.dirname(main), "elsewhere")
    File.mkdir_p!(elsewhere)
    File.write!(Path.join(elsewhere, "key"), "private")
    File.ln_s!(elsewhere, Path.join(main, "linked"))
    override(main, "linked/key\n")
    worktree = worktree(main, "feat-sl")

    {0, _out, stderr} = shape(worktree)

    refute File.exists?(Path.join(worktree, "linked/key"))
    assert stderr =~ "passes through a symlink"
  end

  test "a name with gitignore characters is hidden as itself", %{main: main} do
    for name <- ["a[1]", "!bang"], do: File.write!(Path.join(main, name), "x")
    override(main, "a[1]\n!bang\n")
    worktree = worktree(main, "feat-esc")

    {0, _out, _stderr} = shape(worktree)

    assert File.exists?(Path.join(worktree, "a[1]"))
    assert File.exists?(Path.join(worktree, "!bang"))
    assert status(worktree) == ""
  end

  test "a listed path that leaves the repo is refused, and nothing outside is touched", %{
    main: main
  } do
    outside = Path.join(Path.dirname(main), "outside-secret")
    File.write!(outside, "secret")
    override(main, "../outside-secret\n#{outside}\n")
    worktree = worktree(main, "feat-k")

    {0, _out, stderr} = shape(worktree)

    refute File.exists?(Path.join(Path.dirname(worktree), "outside-secret"))
    refute File.exists?(Path.join(worktree, "outside-secret"))
    assert stderr =~ "outside the repo"
    refute Enum.any?(exclude(main), &String.contains?(&1, "outside-secret"))
  end

  test "a path git already ignores gets no exclude line, and a repeat adds none twice", %{
    main: main
  } do
    elixir_project(main, ignore: true)
    override(main, "deps\n.env\n")
    File.write!(Path.join(main, ".env"), "x")
    w1 = worktree(main, "feat-g")
    w2 = worktree(main, "feat-h")

    {0, _, _} = shape(w1)
    {0, _, _} = shape(w2)

    assert exclude(main) |> Enum.count(&(&1 == "/.env")) == 1
    refute "/deps" in exclude(main)
  end

  test "a clone that cannot run never fails the shape", %{main: main} do
    elixir_project(main)
    worktree = worktree(main, "feat-i")
    File.write!(Path.join(worktree, "deps"), "a file in the way")

    {code, out, stderr} = shape(worktree)

    assert code == 0
    assert out =~ "--model"
    assert stderr =~ "could not clone deps"
  end

  test "a repo with no markers says nothing was cloned", %{main: main} do
    worktree = worktree(main, "feat-j")

    {0, _out, stderr} = shape(worktree)

    assert stderr =~ "nothing to clone"
  end
end
