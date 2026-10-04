defmodule Whiska.Test.NoDesktop do
  @moduledoc """
  The desktop the test config installs: there is no notifier, so a hoot that
  falls back draws nothing on the screen of whoever runs the suite. A test that
  wants to see the fallback injects `Whiska.Desktop.Mock`.
  """
  @behaviour Whiska.Desktop

  @impl true
  def notify(_notification), do: {:error, :no_notifier}
end
