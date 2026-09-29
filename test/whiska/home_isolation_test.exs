defmodule Whiska.HomeIsolationTest do
  @moduledoc """
  The suite must never write into the person's own home — not `~/.whiska`,
  where the open-houses record lives (ADR-0039), and not
  `~/Library/LaunchAgents`, where the owl's plist goes (ADR-0040). Running
  `mix test` once wiped the record for real, so this is the test that says the
  isolation holds, and holds even for a test that mishandles the setting.
  """
  use ExUnit.Case, async: false

  alias Whiska.LaunchAgent
  alias Whiska.OpenHouses
  alias Whiska.Test.RealHome

  test "no path the suite writes to is inside the person's home" do
    assert RealHome.violations() == []
  end

  test "the whiska home and the user home are two different temp places, not the real ones" do
    assert RealHome.outside?(OpenHouses.home())
    assert RealHome.outside?(LaunchAgent.user_home())
    refute OpenHouses.home() == Path.join(RealHome.path(), ".whiska")
  end

  test "a test that drops the :home setting still lands outside the person's home" do
    previous = Application.get_env(:whiska, :home)
    on_exit(fn -> Application.put_env(:whiska, :home, previous) end)

    Application.delete_env(:whiska, :home)

    assert RealHome.outside?(OpenHouses.home())
    assert RealHome.violations() == []
  end

  test "a test that drops the :user_home setting is caught, not silently allowed" do
    previous = Application.get_env(:whiska, :user_home)
    on_exit(fn -> Application.put_env(:whiska, :user_home, previous) end)

    Application.delete_env(:whiska, :user_home)

    assert [{"the owl's launchd plist", _}, {"the user home (:user_home)", _}] =
             RealHome.violations()
  end

  describe "outside?/2" do
    test "the home itself and anything under it are inside" do
      refute RealHome.outside?("/Users/someone", "/Users/someone")
      refute RealHome.outside?("/Users/someone/.whiska/houses", "/Users/someone")
      refute RealHome.outside?("/Users/someone/x/../.whiska", "/Users/someone")
    end

    test "a sibling whose name merely starts the same is outside" do
      assert RealHome.outside?("/Users/someone-else/.whiska", "/Users/someone")
      assert RealHome.outside?("/tmp/whiska-test-home/.whiska", "/Users/someone")
    end
  end
end
