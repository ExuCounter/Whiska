defmodule Whiska.Mice do
  @moduledoc """
  `whiska mice`: what is currently alive in this house, one line per mouse.

  Separate from `whiska questions` on purpose — a mouse can be running fine
  with nothing pending. Two sources, each asked for what only it knows:

  - **The house** says which mice exist and are not dead (`died_at`, ADR-0026),
    their branch and mode labels (ADR-0002, ADR-0018), and when each record was
    created, which is where uptime comes from.
  - **herdr** says what each mouse's pane is doing right now. A mouse is a herdr
    pane (ADR-0020), and its `agent_status` — `working`, `idle`, `blocked` — is
    the one live signal a plain CLI invocation can reach: it is asked over the
    boundary ADR-0031 names, not read from the owl. The pane is found the way the
    house finds it, by the pane's cwd sitting inside the mouse's worktree.

  What this deliberately does not do: mark anything. A mouse with no pane is
  shown as `no pane` and left for the owl, which owns dead-mouse detection
  (ADR-0026). A listing only reports.

  The "what is it doing" excerpt the spec describes — the last tool call, kept in
  the owl's memory (ADR-0006) — is not here. Nothing captures it yet (the hook
  opens SQLite and exits; ADR-0030, ADR-0033), and a fresh CLI process has no
  channel to the owl's memory either way.
  """

  alias Whiska.Herdr
  alias Whiska.Layout
  alias Whiska.Schema.Mouse
  alias Whiska.Storage

  @typedoc "One line of the listing, already rendered as words."
  @type row :: %{branch: String.t(), mode: String.t(), status: String.t(), uptime: String.t()}

  @typedoc "herdr's answer, or why it was not asked."
  @type panes :: {:ok, [Herdr.pane()]} | {:error, term()} | :no_socket

  @doc """
  Every alive mouse in the house at `main_checkout`, as rows.

  Options: `:herdr_socket` (defaults to `HERDR_SOCKET_PATH`); `nil` means herdr
  is not asked and every status is `?`.
  """
  @spec list(Path.t(), keyword()) :: {:ok, [row()]} | {:error, term()}
  def list(main_checkout, opts \\ []) do
    socket = Keyword.get_lazy(opts, :herdr_socket, &Herdr.socket_path/0)

    with {:ok, handle} <- Storage.open(main_checkout) do
      try do
        {:ok, rows(Storage.alive_mice(), ask_herdr(socket), DateTime.utc_now())}
      after
        Storage.close(handle)
      end
    end
  end

  defp ask_herdr(nil), do: :no_socket
  defp ask_herdr(socket), do: Herdr.impl().list_panes(socket)

  @doc "Turn mouse records and herdr's pane list into rows. Pure."
  @spec rows([Mouse.t()], panes(), DateTime.t()) :: [row()]
  def rows(mice, panes, now) do
    Enum.map(mice, fn mouse ->
      %{
        branch: mouse.branch || mouse.mouse_id,
        mode: mouse.mode,
        status: status(mouse, panes),
        uptime: format_uptime(DateTime.diff(now, mouse.created_at))
      }
    end)
  end

  defp status(mouse, {:ok, panes}) do
    case Enum.find(
           panes,
           &(&1.agent != nil and is_binary(&1.cwd) and Layout.inside?(&1.cwd, mouse.path))
         ) do
      nil -> "no pane"
      pane -> pane.agent_status
    end
  end

  defp status(_mouse, _unreachable), do: "?"

  @doc "Seconds as a person would say them: `45s`, `4m`, `2h 15m`, `3d 4h`."
  @spec format_uptime(integer()) :: String.t()
  def format_uptime(seconds) when seconds < 60, do: "#{max(seconds, 0)}s"
  def format_uptime(seconds) when seconds < 3600, do: "#{div(seconds, 60)}m"

  def format_uptime(seconds) when seconds < 86_400,
    do: "#{div(seconds, 3600)}h #{rem(div(seconds, 60), 60)}m"

  def format_uptime(seconds), do: "#{div(seconds, 86_400)}d #{rem(div(seconds, 3600), 24)}h"

  @doc "Rows as lines, columns lined up. One line per mouse, no width fight (ADR-0027)."
  @spec render([row()]) :: String.t()
  def render([]), do: "No mice alive."

  def render(rows) do
    columns = [:branch, :mode, :status, :uptime]

    widths =
      Map.new(columns, fn c ->
        {c, rows |> Enum.map(&String.length(Map.fetch!(&1, c))) |> Enum.max()}
      end)

    Enum.map_join(rows, "\n", fn row ->
      columns
      |> Enum.map_join("  ", &String.pad_trailing(Map.fetch!(row, &1), widths[&1]))
      |> String.trim_trailing()
    end)
  end
end
