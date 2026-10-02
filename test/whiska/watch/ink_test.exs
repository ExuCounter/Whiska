defmodule Whiska.Watch.InkTest do
  @moduledoc """
  The board's colour: plain ANSI, and nothing that fights the dim the
  statusline script wraps a stale board in (ADR-0051, addendum of 2026-10-02).
  """
  use ExUnit.Case, async: true

  alias Whiska.Watch.Ink

  test "cyan is the plain ANSI code, so the terminal's own theme picks the shade" do
    assert Ink.cyan("feat-a") == "\e[36mfeat-a\e[39m"
  end

  test "yellow is the plain ANSI code" do
    assert Ink.yellow("waiting on you") == "\e[33mwaiting on you\e[39m"
  end

  test "dim ends with the intensity code, not a full reset" do
    assert Ink.dim("6m") == "\e[2m6m\e[22m"
  end

  test "nothing ever emits a full reset, which would end the stale wrapper's dim" do
    for inked <- [Ink.cyan("a"), Ink.yellow("a"), Ink.dim("a")] do
      refute inked =~ "\e[0m"
    end
  end

  test "an empty string is left alone rather than wrapped in codes" do
    for f <- [&Ink.cyan/1, &Ink.yellow/1, &Ink.dim/1], do: assert(f.("") == "")
  end

  test "plain/1 is what a test reads a coloured board back as" do
    assert Ink.plain(Ink.cyan("feat-a") <> "  " <> Ink.dim("6m")) == "feat-a  6m"
  end
end
