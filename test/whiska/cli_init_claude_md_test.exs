defmodule Whiska.CLIInitClaudeMdTest do
  @moduledoc """
  `whiska init` writing the worktree protocol into the repo's own `CLAUDE.md`
  (ADR-0017, ADR-0045). Whiska owns the protocol between herdr, Whiska and
  Claude, so the rules travel with the repo the same way the hooks do
  (ADR-0016).
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Whiska.ClaudeMd
  alias Whiska.CLI

  setup do
    root = Path.join(System.tmp_dir!(), "whiska-md-#{System.unique_integer([:positive])}")
    main = Path.join(root, "myrepo")
    File.mkdir_p!(Path.join(main, ".git"))
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, main: main, path: Path.join(main, "CLAUDE.md")}
  end

  defp init(main), do: capture_io(fn -> assert CLI.run(["init"], main) == 0 end)

  test "creates CLAUDE.md when the repo has none", %{main: main, path: path} do
    init(main)
    assert File.read!(path) == ClaudeMd.merge("")
    assert File.read!(path) =~ "<!-- whiska:worktrees:start -->"
  end

  test "keeps what the repo already says and appends the block", %{main: main, path: path} do
    File.write!(path, "# myrepo\n\nDo not delete this.\n")
    init(main)

    body = File.read!(path)
    assert body =~ "Do not delete this."
    assert body =~ "<!-- whiska:start -->"
  end

  test "re-running leaves the file byte for byte the same", %{main: main, path: path} do
    File.write!(path, "# myrepo\n\nMine.\n")
    init(main)
    once = File.read!(path)
    init(main)
    assert File.read!(path) == once
  end

  test "a part the person marked keep survives init", %{main: main, path: path} do
    init(main)

    kept =
      File.read!(path)
      |> String.replace("<!-- whiska:marker:start -->", "<!-- whiska:marker:start keep -->")

    File.write!(path, kept)
    init(main)

    assert File.read!(path) =~ "<!-- whiska:marker:start keep -->"
  end

  test "says so, and tells the person to commit it", %{main: main} do
    output = init(main)

    assert output =~ "CLAUDE.md"
    assert output =~ "git add"
  end

  test "tells the person to write the Finish heading the finish part reads", %{main: main} do
    output = init(main)

    assert output =~ "## Finish"
    refute output =~ Whiska.Install.review_loop_path()
  end

  test "says the finishing pipeline is a skill the block points at", %{main: main} do
    assert init(main) =~ "whiska-finish"
  end
end
