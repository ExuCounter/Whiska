defmodule Whiska.Watch.SnapshotTest do
  @moduledoc """
  The file the owl writes the board to and the statusline prints (ADR-0051).
  """
  # Serial: each test points the global `:home` at a folder of its own.
  use ExUnit.Case, async: false

  alias Whiska.Watch.Snapshot

  setup do
    home = Path.join(System.tmp_dir!(), "whiska-snap-#{System.unique_integer([:positive])}")
    Application.put_env(:whiska, :home, home)
    on_exit(fn -> File.rm_rf!(home) end)
    {:ok, home: home}
  end

  describe "path/1" do
    test "names the house by its path, every other character a dash", %{home: home} do
      assert Snapshot.path("/Users/me/projects/whiska") ==
               Path.join(home, "board/-Users-me-projects-whiska")
    end

    test "is the same spelling the statusline script works out in bash", %{home: home} do
      main = "/Users/me/pro.jects/whiska"

      {shell, 0} =
        System.cmd("sh", ["-c", "printf '%s' '#{main}' | LC_ALL=C tr -c 'A-Za-z0-9' '-'"])

      assert Snapshot.path(main) == Path.join([home, "board", shell])
    end

    test "matches bash for a path with a non-ASCII character in it", %{home: home} do
      main = "/Users/josé/repo"

      {shell, 0} =
        System.cmd("sh", ["-c", "printf '%s' '#{main}' | LC_ALL=C tr -c 'A-Za-z0-9' '-'"])

      assert Snapshot.path(main) == Path.join([home, "board", shell])
    end
  end

  describe "write/2" do
    test "creates the folder and the file", %{home: _home} do
      main = "/Users/me/projects/whiska"

      assert :ok = Snapshot.write(main, "🐭 feat-a  working  Edit x.ex", nil)
      assert File.read!(Snapshot.path(main)) == "🐭 feat-a  working  Edit x.ex"
    end

    test "replaces what was there, so a shrinking board cannot leave a tail" do
      main = "/Users/me/projects/whiska"

      :ok = Snapshot.write(main, "🐭 feat-a  working\n🐭 feat-b  idle", nil)
      :ok = Snapshot.write(main, "🐭 feat-a  working", nil)

      assert File.read!(Snapshot.path(main)) == "🐭 feat-a  working"
    end

    test "a quiet house writes an empty file rather than leaving the last board up" do
      main = "/Users/me/projects/whiska"

      :ok = Snapshot.write(main, "🐭 feat-a  working", nil)
      :ok = Snapshot.write(main, "", nil)

      assert File.read!(Snapshot.path(main)) == ""
    end

    test "the board is the person's to read and nobody else's" do
      main = "/Users/me/projects/whiska"
      :ok = Snapshot.write(main, "🐭 feat-a  working", nil)

      assert {:ok, %File.Stat{mode: mode}} = File.stat(Snapshot.path(main))
      assert Bitwise.band(mode, 0o077) == 0
    end

    test "a symlink left where the board goes is replaced, not written through" do
      main = "/Users/me/projects/whiska"
      :ok = Snapshot.write(main, "first", nil)
      elsewhere = Path.join(System.tmp_dir!(), "whiska-snap-target-#{System.unique_integer()}")
      File.write!(elsewhere, "untouched")
      File.ln_s!(elsewhere, Snapshot.path(main) <> ".tmp")

      :ok = Snapshot.write(main, "second", nil)

      assert File.read!(Snapshot.path(main)) == "second"
      assert File.read!(elsewhere) == "untouched"
      File.rm!(elsewhere)
    end
  end
end
