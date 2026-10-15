defmodule Whiska.Desktop do
  @moduledoc """
  The desktop's own notification centre, where every hoot is raised (ADR-0062).

  herdr is not asked. Its `[ui.toast] delivery` is one switch over its own
  agent toasts — every mouse's included — and every notification sent through
  its API, and it answers `shown: true` with the switch off. Whiska is the one
  source of notifications, and only for what waits on the person in a main
  session, so it raises them itself. The boundary sits behind a behaviour for
  the same reason herdr's does (ADR-0031): a test can see what would have been
  raised without anything appearing on the person's screen.
  """

  @typedoc """
  What to raise. `sound` is one of the two events a hoot has, or `:none`.
  `jump` is the main checkout a click on it should take the person to, where
  the notifier can carry a click.
  """
  @type notification :: %{
          required(:title) => String.t(),
          required(:body) => String.t(),
          required(:sound) => :none | :done | :request,
          optional(:jump) => Path.t()
        }

  @typedoc "What was raised, by which program — or why nothing was."
  @type result :: {:ok, String.t()} | {:error, :no_notifier | term()}

  @doc "Raise `notification` on this machine's desktop."
  @callback notify(notification :: notification()) :: result()

  @doc "The implementation in force — the real notifier, or a test's stand-in."
  @spec impl() :: module()
  def impl, do: Application.get_env(:whiska, :desktop, Whiska.Desktop.Notifier)
end
