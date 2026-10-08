defmodule Whiska.Desktop do
  @moduledoc """
  The desktop's own notification centre, reached without herdr — the boundary
  a hoot falls back to when herdr says it did not show one
  (ADR-0062).

  herdr is still asked first (ADR-0062). This is what answers when herdr's one
  switch, `[ui.toast] delivery`, is off for a reason that has nothing to do with
  Whiska. It sits behind a behaviour for the same reason herdr does (ADR-0031):
  a test can see what would have been raised without anything appearing on the
  person's screen.
  """

  @typedoc "What was raised, by which program — or why nothing was."
  @type result :: {:ok, String.t()} | {:error, :no_notifier | term()}

  @doc "Raise `notification` on this machine's desktop."
  @callback notify(notification :: Whiska.Herdr.notification()) :: result()

  @doc "The implementation in force — the real notifier, or a test's stand-in."
  @spec impl() :: module()
  def impl, do: Application.get_env(:whiska, :desktop, Whiska.Desktop.Notifier)
end
