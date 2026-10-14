defmodule Whiska.BriefTest do
  use ExUnit.Case, async: true

  alias Whiska.Brief
  alias Whiska.Question.Marker

  test "each brief renders whole: a mouse's carries its task and the finished marker" do
    for mode <- ["build", "sniff"] do
      text = Brief.render(mode, "Make the CSV page sortable by date.")
      assert text =~ "Make the CSV page sortable by date.", mode
      refute text =~ "{{", mode
      assert text =~ Marker.render(:done), mode
    end

    refute Brief.render(:main) =~ "{{"
  end

  test "a build mouse's plan shows signatures, data and the first failing test as code" do
    assert "build" |> Brief.render("task") |> String.replace(~r/\s+/, " ") =~
             "signatures, data shapes and the first failing test as code blocks"
  end

  test "a build mouse's spec and plan say each fact once" do
    build = "build" |> Brief.render("task") |> String.replace(~r/\s+/, " ")
    assert build =~ "Each fact appears once across the spec, plan and research document"
    assert build =~ "only choices you made yourself"
    assert build =~ "each limit the task or the person's answers set"
    assert build =~ "The cold reviewer reads the spec, never the task or plan"
    assert build =~ "never function bodies"
  end

  test "a mouse's documents keep each link on one line and use lists, not tables" do
    for mode <- ["build", "sniff"] do
      text = mode |> Brief.render("task") |> String.replace(~r/\s+/, " ")
      assert text =~ "Never wrap a markdown link across lines", mode
      assert text =~ "no tables", mode
    end
  end

  test "a build mouse writes each point as a paragraph and ends on what to review" do
    build = "build" |> Brief.render("task") |> String.replace(~r/\s+/, " ")
    assert build =~ "Each point is one short paragraph: no bullets, no sub-lists."
    assert build =~ "The question line names what to review or decide"
  end

  test "the recap leads with counts and says what each question needs, not its options" do
    main = :main |> Brief.render() |> String.replace(~r/\s+/, " ")
    assert main =~ "one line of counts"
    assert main =~ "what it needs from the person, never its options"
    assert main =~ "no branch names, ids or commands"
  end

  test "a reply about something else ends with a note on what still waits" do
    main = :main |> Brief.render() |> String.replace(~r/\s+/, " ")
    assert main =~ "Still waiting on you"
    assert main =~ "A reply about that question, or a recap, needs none"
  end

  test "land and pr run in the background so the person's input is not blocked" do
    main = :main |> Brief.render() |> String.replace(~r/\s+/, " ")
    assert main =~ "run_in_background"
    assert main =~ "one line saying it is running"
    assert main =~ "one after another"
  end
end
