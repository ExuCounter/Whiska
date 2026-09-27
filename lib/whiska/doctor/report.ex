defmodule Whiska.Doctor.Report do
  @moduledoc """
  A doctor's findings for one repo, and how they read on a terminal.

  One line per check: the status word first, fixed width, so a column of them
  scans; then the check's name, aligned; then what was found. A fix, when
  there is one, sits on its own indented line right under the finding. Plain
  ASCII, no colour — this is read in whatever pane it was typed in, and
  sometimes pasted somewhere else.

  Silence is not a result here. A healthy machine still prints every check,
  because on a machine where the owl has never run, "nothing printed" and
  "nothing checked" would look the same.
  """

  alias Whiska.Doctor.Check

  @enforce_keys [:repo, :checks]
  defstruct [:repo, :checks]

  @type t :: %__MODULE__{repo: Path.t(), checks: [Check.t()]}

  @status_width 6
  @indent "  "

  @doc "The whole report as text, ready to print."
  @spec render(t()) :: String.t()
  def render(%__MODULE__{repo: repo, checks: checks}) do
    name_width =
      checks |> Enum.map(&String.length(&1.name)) |> Enum.max(fn -> 0 end) |> Kernel.+(2)

    lines =
      Enum.flat_map(checks, fn check ->
        [line(check, name_width)] ++ fix_line(check, name_width)
      end)

    Enum.join(
      ["whiska doctor — #{Path.basename(repo)} (#{repo})", ""] ++ lines ++ ["", summary(checks)],
      "\n"
    )
  end

  defp line(%Check{} = check, name_width) do
    @indent <>
      String.pad_trailing(word(check.status), @status_width) <>
      String.pad_trailing(check.name, name_width) <>
      check.detail
  end

  defp fix_line(%Check{fix: nil}, _), do: []
  defp fix_line(%Check{status: :ok}, _), do: []

  defp fix_line(%Check{fix: fix}, name_width),
    do: [
      String.duplicate(" ", String.length(@indent) + @status_width + name_width) <> "fix: " <> fix
    ]

  defp word(:ok), do: "ok"
  defp word(:warn), do: "warn"
  defp word(:fail), do: "FAIL"

  defp summary(checks) do
    fails = Enum.count(checks, &(&1.status == :fail))
    warns = Enum.count(checks, &(&1.status == :warn))

    case {fails, warns} do
      {0, 0} -> "All checks passed."
      {0, w} -> "#{warnings(w)}."
      {f, 0} -> "#{f} failed."
      {f, w} -> "#{f} failed, #{warnings(w)}."
    end
  end

  defp warnings(1), do: "1 warning"
  defp warnings(n), do: "#{n} warnings"

  @doc "Non-zero on any failure, so a script can ask without reading the text."
  @spec exit_status(t()) :: 0 | 1
  def exit_status(%__MODULE__{checks: checks}) do
    if Enum.any?(checks, &(&1.status == :fail)), do: 1, else: 0
  end
end
