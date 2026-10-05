defmodule Whiska.Test.NoSystemctl do
  @moduledoc """
  The systemd runner the test config installs: `systemctl --user show`
  answers "not installed", and anything that would change systemd's state
  raises. A test that wants systemd to say something else injects its own
  runner; no test can reach the real one by accident.
  """

  def run(["systemctl", "--user", "show" | _]), do: {"UnitFileState=\nMainPID=0\n", 0}
  def run(argv), do: raise("#{Enum.join(argv, " ")} would have run for real in a test")
end
