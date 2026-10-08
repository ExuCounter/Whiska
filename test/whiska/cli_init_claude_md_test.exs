defmodule Whiska.CLIInitClaudeMdTest do
  @moduledoc """
  `whiska init` and a repo's own `CLAUDE.md`: the rules arrive at session start
  (ADR-0081), so init takes an older Whiska's block out and
  leaves everything of the person's exactly where it was.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Whiska.CLI

  setup do
    root = Path.join(System.tmp_dir!(), "whiska-md-#{System.unique_integer([:positive])}")
    main = Path.join(root, "myrepo")
    File.mkdir_p!(Path.join(main, ".git"))
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, main: main, path: Path.join(main, "CLAUDE.md")}
  end

  defp init(main), do: capture_io(fn -> assert CLI.run(["init"], main) == 0 end)

  # The header's number is the one an older Whiska really wrote, interpolated so the
  # repo's citation check does not read a record that was folded away as dangling.
  @old_block """
  # myrepo

  Do not delete this.

  <!-- whiska:start -->
  <!-- Whiska wrote this block (`whiska init`). Each part below is replaced in
       place on the next run and nothing outside the markers is touched. To keep
       a part as your own, add `keep` to its start marker — `<!-- whiska:NAME:start
       keep -->` — and Whiska will never rewrite it again. See Whiska ADR-#{"0045"}. -->

  <!-- whiska:worktrees:start -->
  ## Worktrees

  Old routing rules.
  <!-- whiska:worktrees:end -->

  My own note between two parts.

  <!-- whiska:marker:start keep -->
  ## My marker wording
  <!-- whiska:marker:end -->

  <!-- whiska:report:start -->
  ## How a session writes its message
  <!-- whiska:report:end -->
  <!-- whiska:end -->

  ## Finish

  checks: mix test
  """

  test "takes Whiska's parts out, and keeps a keep part, the person's text and every byte outside",
       %{main: main, path: path} do
    File.write!(path, @old_block)
    init(main)

    body = File.read!(path)
    refute body =~ "Old routing rules."
    refute body =~ "How a session writes its message"
    refute body =~ "Whiska wrote this block"
    assert body =~ "<!-- whiska:marker:start keep -->\n## My marker wording\n"
    assert body =~ "My own note between two parts."
    assert String.starts_with?(body, "# myrepo\n\nDo not delete this.\n\n<!-- whiska:start -->")
    assert String.ends_with?(body, "<!-- whiska:end -->\n\n## Finish\n\nchecks: mix test\n")
  end

  test "a block with nothing of the person's in it goes markers and all", %{
    main: main,
    path: path
  } do
    File.write!(path, """
    # myrepo

    <!-- whiska:start -->
    <!-- whiska:report:start -->
    Rules.
    <!-- whiska:report:end -->
    <!-- whiska:end -->
    """)

    init(main)

    assert File.read!(path) == "# myrepo\n"
  end

  test "creates no CLAUDE.md where the repo had none", %{main: main, path: path} do
    init(main)
    refute File.exists?(path)
  end

  test "a CLAUDE.md with no block is left byte for byte alone", %{main: main, path: path} do
    File.write!(path, "# myrepo\n\nMine.")
    init(main)
    assert File.read!(path) == "# myrepo\n\nMine."
  end

  test "says the old block was taken out, only when there was one", %{main: main, path: path} do
    refute init(main) =~ "old block"

    File.write!(path, @old_block)
    assert init(main) =~ "old block"
  end

  test "a block taken out is a change to commit, and the commit line says so",
       %{main: main, path: path} do
    refute init(main) =~ "git add CLAUDE.md"

    File.write!(path, @old_block)
    assert init(main) =~ "git add CLAUDE.md"
  end

  test "tells the person to write the Finish heading the finish rules read", %{main: main} do
    output = init(main)

    assert output =~ "## Finish"
    refute output =~ Whiska.Install.review_loop_path()
  end
end
