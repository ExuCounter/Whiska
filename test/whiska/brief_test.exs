defmodule Whiska.BriefTest do
  use ExUnit.Case, async: true

  alias Whiska.Brief
  alias Whiska.Question.Marker

  test "each brief renders whole: a mouse's points at its first message and carries the finished marker" do
    for mode <- ["build", "sniff"] do
      text = Brief.render(mode)
      assert text |> String.replace(~r/\s+/, " ") =~ "this session's first message", mode
      refute text =~ "{{", mode
      assert text =~ Marker.render(:done), mode
    end

    refute Brief.render(:main) =~ "{{"
  end

  test "a build mouse's plan shows signatures, data and the first failing test as code" do
    assert "build" |> Brief.render() |> String.replace(~r/\s+/, " ") =~
             "signatures, data shapes and the first failing test as code blocks"
  end

  test "a build mouse's spec and plan say each fact once" do
    build = "build" |> Brief.render() |> String.replace(~r/\s+/, " ")
    assert build =~ "Each fact appears once across the spec, plan and research document"
    assert build =~ "only choices you made yourself"
    assert build =~ "each limit the task or the person's answers set"
    assert build =~ "The cold reviewer reads the spec, never the task or plan"
    assert build =~ "never function bodies"
  end

  test "a sniff mouse's research document says each fact once, in about two screens" do
    sniff = "sniff" |> Brief.render() |> String.replace(~r/\s+/, " ")
    assert sniff =~ "## Research document"
    assert sniff =~ "Each fact appears once"
    assert sniff =~ "About two screens."
    assert sniff =~ "Findings, not design"
    refute sniff =~ "in full"
  end

  test "a mouse's documents keep each link on one line and use lists, not tables" do
    for mode <- ["build", "sniff"] do
      text = mode |> Brief.render() |> String.replace(~r/\s+/, " ")
      assert text =~ "Never wrap a markdown link across lines", mode
      assert text =~ "no tables", mode
    end
  end

  test "a build mouse writes each point as a paragraph and ends on what to review" do
    build = "build" |> Brief.render() |> String.replace(~r/\s+/, " ")
    assert build =~ "Each point is one short paragraph: no bullets, no sub-lists."
    assert build =~ "The question line names what to review or decide"
  end

  test "the recap leads with counts and says what each question needs, not its options" do
    main = :main |> Brief.render() |> String.replace(~r/\s+/, " ")
    assert main =~ "one line of counts"
    assert main =~ "what it needs from the person, never its options"
    assert main =~ "no branch names, ids or commands"
  end

  test "a waiting question is reminded once, in one line, then left alone" do
    main = :main |> Brief.render() |> String.replace(~r/\s+/, " ")
    assert main =~ "Remind it once"
    assert main =~ "then never again"
    assert main =~ "Only questions not yet reminded"
    assert main =~ "Meow, still waiting on you:"
    assert main =~ "No links"
    assert main =~ "A reply about that question, or a recap, needs none"
    refute main =~ "per waiting question, its bold heading"
    refute main =~ "**Still waiting on you:**"
  end

  test "land and pr run in the background so the person's input is not blocked" do
    main = :main |> Brief.render() |> String.replace(~r/\s+/, " ")
    assert main =~ "run_in_background"
    assert main =~ "one line saying it is running"
    assert main =~ "one after another"
  end

  test "write/3 refuses a link at the path, and writes nothing through it" do
    root = Path.join(System.tmp_dir!(), "whiska-brief-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)
    main = Path.join(root, "main")
    worktree = Path.join(root, "wt")
    File.mkdir_p!(Path.join(main, ".git"))
    File.mkdir_p!(worktree)
    target = Path.join(root, "CLAUDE.md")
    File.write!(target, "the person's own instructions")
    File.ln_s!(target, Path.join(worktree, ".whiska-brief.md"))

    assert {:error, :not_a_plain_file} = Brief.write(main, worktree, "build")
    assert File.read!(target) == "the person's own instructions"
  end
end
