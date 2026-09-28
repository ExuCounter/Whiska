defmodule Whiska.Test.NoLaunchctl do
  @moduledoc """
  The launchctl runner the test config installs: `print` answers "not
  loaded", and anything that would change launchd's state raises. A test that
  wants launchctl to say something else injects its own runner; no test can
  reach the real one by accident.
  """

  def run(["print" | _]), do: {"Could not find service (test)\n", 113}
  def run(args), do: raise("launchctl #{Enum.join(args, " ")} would have run for real in a test")
end
