defmodule Whiska.Doctor.ReportTest do
  @moduledoc "How a doctor's findings read on a terminal, and what its exit status says."
  use ExUnit.Case, async: true

  alias Whiska.Doctor.Check
  alias Whiska.Doctor.Report

  defp report(checks), do: %Report{repo: "/Users/me/projects/myrepo", checks: checks}

  defp ok(name, detail), do: %Check{status: :ok, name: name, detail: detail}
  defp warn(name, detail, fix), do: %Check{status: :warn, name: name, detail: detail, fix: fix}
  defp fail(name, detail, fix), do: %Check{status: :fail, name: name, detail: detail, fix: fix}

  test "names the repo it examined" do
    out = Report.render(report([]))
    assert out =~ "whiska doctor — myrepo (/Users/me/projects/myrepo)"
  end

  test "one line per check, status word first, name aligned" do
    out =
      Report.render(
        report([ok("binary", "~/.local/bin/whiska"), fail("Stop", "not wired", "whiska init")])
      )

    assert out =~ ~r/^  ok    binary +~\/\.local\/bin\/whiska$/m
    assert out =~ ~r/^  FAIL  Stop +not wired$/m
  end

  test "a fix goes on its own indented line under the finding, and ok lines have none" do
    out = Report.render(report([ok("binary", "fine"), warn("owl", "not running", "whiska owl")]))

    assert out =~ ~r/not running\n +fix: whiska owl$/m
    refute out =~ ~r/fine\n +fix:/
  end

  test "a fix of several lines keeps every line indented under the finding" do
    out = Report.render(report([warn("tab bar", "nothing draws it", "paste this:\n[ui]\nx = 1")]))

    assert out =~ ~r/nothing draws it\n +fix: paste this:\n +\[ui\]\n +x = 1$/m
  end

  test "the summary counts failures and warnings" do
    out = Report.render(report([fail("a", "x", "f"), fail("b", "x", "f"), warn("c", "x", "f")]))
    assert out =~ "2 failed, 1 warning."
  end

  test "the summary says so when everything passed" do
    assert Report.render(report([ok("a", "x")])) =~ "All checks passed."
  end

  test "the summary says so when there are only warnings" do
    out = Report.render(report([ok("a", "x"), warn("b", "x", "f")]))
    assert out =~ "1 warning."
    refute out =~ "failed"
  end

  test "any failure makes the exit status non-zero; warnings alone do not" do
    assert Report.exit_status(report([ok("a", "x"), warn("b", "x", "f")])) == 0
    assert Report.exit_status(report([ok("a", "x"), fail("b", "x", "f")])) == 1
  end
end
