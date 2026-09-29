defmodule Whiska.Watch do
  @moduledoc """
  The board: what every mouse in this house is doing, one row each.

  ADR-0051 puts it in this repo's Claude Code statusline, which is as many
  lines as the script prints. `whiska mice` answers the same question when
  asked; this answers it without being asked, in front of the person, while
  they work on something else.

  A row is branch, herdr's status, and one column of detail — the question
  waiting on the person if there is one, otherwise what the mouse is doing
  (`Whiska.Watch.Transcript`). Live mice first, ordered by how much they want
  the person: waiting, blocked, working, then the quiet ones. Five rows at most,
  and the cap never drops a mouse that is waiting — a hidden question is the one
  failure a board must not have.

  A dead mouse (ADR-0026) keeps a row only while it still has an orphaned
  question, which is the one thing left that the person can act on: nothing can
  be replied to, so the row carries the `whiska close` that clears it. Nothing
  here acts — the board only reports.
  """

  alias Whiska.Herdr
  alias Whiska.Layout
  alias Whiska.Question.Marker
  alias Whiska.Schema.Mouse
  alias Whiska.Schema.Question
  alias Whiska.Storage
  alias Whiska.Watch.Transcript

  @board_max 5
  @branch_max 24
  @dim "\e[2m"
  @undim "\e[0m"

  @waiting ["open", "sent"]

  @typedoc "One line of the board, already rendered as words."
  @type row :: %{
          mouse_id: String.t(),
          branch: String.t(),
          status: String.t(),
          detail: String.t(),
          state: :live | :dead
        }

  @typedoc "`more` is how many live mice the cap left off; `waiting` what no row covers."
  @type t :: %{rows: [row()], more: non_neg_integer(), waiting: non_neg_integer()}

  @doc """
  The board for the house at `main_checkout`.

  Options: `:herdr_socket` (defaults to `HERDR_SOCKET_PATH`), and `board/2`'s
  `:action`.
  """
  @spec house(Path.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def house(main_checkout, opts \\ []) do
    socket = Keyword.get_lazy(opts, :herdr_socket, &Herdr.socket_path/0)

    with {:ok, handle} <- Storage.open(main_checkout) do
      try do
        built =
          board(
            Storage.all(Mouse),
            opts
            |> Keyword.take([:action])
            |> Keyword.merge(
              questions: Storage.questions() ++ Storage.orphaned_questions(),
              panes: ask_herdr(socket)
            )
          )

        {:ok, built}
      after
        Storage.close(handle)
      end
    end
  end

  defp ask_herdr(nil), do: :no_socket
  defp ask_herdr(socket), do: Herdr.impl().list_panes(socket)

  @doc """
  The board for a house's mice.

  Options: `:questions`, its waiting and orphaned questions; `:panes`, herdr's
  answer in `Whiska.Mice.panes/0` form; `:action`, what a mouse is doing,
  `Whiska.Watch.Transcript.read/1` unless a test pins it.
  """
  @spec board([Mouse.t()], keyword()) :: t()
  def board(mice, opts \\ []) do
    questions = Keyword.get(opts, :questions, [])
    panes = Keyword.get(opts, :panes, :no_socket)
    action = Keyword.get(opts, :action, &Transcript.read(&1.path))

    by_mouse = Map.new(Enum.reverse(questions), &{&1.mouse_id, &1})
    {alive, dead} = Enum.split_with(mice, &is_nil(&1.died_at))

    {shown, more} =
      alive
      |> Enum.map(&live_row(&1, by_mouse[&1.mouse_id], panes, action))
      |> Enum.sort_by(&rank/1)
      |> cap()

    dead_rows = Enum.flat_map(dead, &dead_row(&1, by_mouse[&1.mouse_id]))
    rows = shown ++ dead_rows

    %{rows: rows, more: more, waiting: uncovered(questions, rows)}
  end

  defp live_row(mouse, question, panes, action) do
    %{
      mouse_id: mouse.mouse_id,
      branch: mouse.branch || mouse.mouse_id,
      status: status(mouse, panes),
      detail: detail(question, mouse, action),
      state: :live
    }
  end

  defp dead_row(_mouse, nil), do: []

  defp dead_row(mouse, %Question{} = question) do
    [
      %{
        mouse_id: mouse.mouse_id,
        branch: mouse.branch || mouse.mouse_id,
        status: "dead",
        detail: "##{question.id} orphaned · whiska close #{question.id}",
        state: :dead
      }
    ]
  end

  defp status(mouse, {:ok, panes}) do
    panes
    |> Enum.find(&(&1.agent != nil and is_binary(&1.cwd) and Layout.inside?(&1.cwd, mouse.path)))
    |> case do
      nil -> "no pane"
      pane -> said_status(pane.agent_status)
    end
  end

  defp status(_mouse, _unreachable), do: "?"

  # herdr's `done` is the same state as `idle` in a tab the person has not
  # looked at, which every mouse works in (ADR-0026 note in `Whiska.Owl.House`).
  defp said_status("done"), do: "idle"
  defp said_status("unknown"), do: "?"
  defp said_status(status), do: status

  defp detail(%Question{status: status} = question, _mouse, _action) when status in @waiting do
    case Marker.pointer(question.text) do
      "" -> "waiting on you · ##{question.id}"
      pointer -> ~s(waiting on you · ##{question.id} · "#{pointer}")
    end
  end

  defp detail(_question, mouse, action) do
    case action.(mouse) do
      {:tool, phrase} -> phrase
      {:said, sentence} -> ~s("#{sentence}")
      nil -> ""
    end
  end

  defp rank(%{detail: "waiting on you" <> _}), do: 0
  defp rank(%{status: "blocked"}), do: 1
  defp rank(%{status: "working"}), do: 2
  defp rank(_quiet), do: 3

  defp cap(rows) do
    {Enum.take(rows, @board_max), max(length(rows) - @board_max, 0)}
  end

  defp uncovered(questions, rows) do
    shown = MapSet.new(rows, & &1.mouse_id)

    questions
    |> Enum.filter(&(&1.status in @waiting and not MapSet.member?(shown, &1.mouse_id)))
    |> length()
  end

  @doc """
  The board as the statusline draws it. Empty when the house is quiet.

  Options: `:color`, whether a dead mouse's row is dimmed — true unless the
  caller is writing somewhere that cannot show it.
  """
  @spec render(t(), keyword()) :: String.t()
  def render(board, opts \\ [])

  def render(%{rows: [], more: 0, waiting: 0}, _opts), do: ""

  def render(%{rows: rows, more: more, waiting: waiting}, opts) do
    color = Keyword.get(opts, :color, true)
    widths = widths(rows)

    (Enum.map(rows, &line(&1, widths, color)) ++ [more_line(more), waiting_line(waiting)])
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp widths(rows) do
    %{
      branch: width(rows, &String.length(clip(&1.branch))),
      status: width(rows, &String.length(&1.status))
    }
  end

  defp width([], _of), do: 0
  defp width(rows, of), do: rows |> Enum.map(of) |> Enum.max()

  defp line(row, widths, color) do
    text =
      "🐭 " <>
        String.pad_trailing(clip(row.branch), widths.branch) <>
        "  " <> String.pad_trailing(row.status, widths.status) <> "  " <> row.detail

    text |> String.trim_trailing() |> dim(row.state, color)
  end

  defp dim(text, :dead, true), do: @dim <> text <> @undim
  defp dim(text, _state, _color), do: text

  defp clip(branch) do
    if String.length(branch) > @branch_max,
      do: String.slice(branch, 0, @branch_max - 1) <> "…",
      else: branch
  end

  defp more_line(0), do: nil
  defp more_line(more), do: "🐭 +#{more} more"

  defp waiting_line(0), do: nil
  defp waiting_line(waiting), do: "🐱 #{waiting} waiting"
end
