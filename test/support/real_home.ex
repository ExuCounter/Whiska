defmodule Whiska.Test.RealHome do
  @moduledoc """
  The one thing the suite must never touch: the person's own home.

  Everything Whiska writes outside a repo hangs off two settings — the whiska
  home (`:home`, where the open-houses record, the owl's log and wrapper and
  `herdr-status.sh` live, ADR-0039) and the user home (`:user_home`, where the
  owl's launchd plist goes, ADR-0040). `test_helper.exs` points both at a
  per-run temp folder; this is the check that says whether they still are, and
  `Whiska.Test.HomeGuard` runs it after every test.
  """

  @doc "The person's real home."
  @spec path() :: Path.t()
  def path, do: Path.expand(System.user_home!())

  @doc "True when `candidate` is neither the person's home nor inside it."
  @spec outside?(Path.t() | nil, Path.t()) :: boolean()
  def outside?(candidate, real \\ path())
  def outside?(nil, _real), do: false

  def outside?(candidate, real) do
    candidate = Path.expand(candidate)
    real = Path.expand(real)
    candidate != real and not String.starts_with?(candidate, real <> "/")
  end

  @doc "Every path the suite could write to outside a repo, by the name to say when it is wrong."
  @spec watched() :: %{String.t() => Path.t()}
  def watched do
    launchd = Whiska.LaunchAgent.paths()

    %{
      "the whiska home (:home)" => Whiska.OpenHouses.home(),
      "the open-houses record" => Whiska.OpenHouses.path(),
      "the user home (:user_home)" => Whiska.LaunchAgent.user_home(),
      "the owl's launchd plist" => launchd.plist,
      "the owl's launchd wrapper" => launchd.wrapper,
      "the owl's log" => launchd.log,
      "herdr-status.sh" => Whiska.Install.herdr_status_path()
    }
  end

  @doc "The watched paths that have fallen inside the person's home. None is the only good answer."
  @spec violations() :: [{String.t(), Path.t()}]
  def violations do
    real = path()

    watched()
    |> Enum.reject(fn {_name, candidate} -> outside?(candidate, real) end)
    |> Enum.sort()
  end
end
