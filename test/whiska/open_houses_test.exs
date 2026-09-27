defmodule Whiska.OpenHousesTest do
  @moduledoc """
  The owl's on-disk record of which houses it has open (ADR-0039): one main
  checkout per line, under `~/.whiska/`, trusted only while an owl is alive.
  """
  use ExUnit.Case, async: true

  alias Whiska.OpenHouses

  setup do
    root = Path.join(System.tmp_dir!(), "whiska-oh-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, path: Path.join(root, "dot-whiska/houses")}
  end

  test "no file yet reads as no houses", %{path: path} do
    assert OpenHouses.read(path) == []
  end

  test "add writes the file, creating its folder, and reads back sorted and unique", %{
    path: path
  } do
    assert :ok = OpenHouses.add("/b/repo", path)
    assert :ok = OpenHouses.add("/a/repo/", path)
    assert :ok = OpenHouses.add("/b/repo", path)

    assert OpenHouses.read(path) == ["/a/repo", "/b/repo"]
    assert File.read!(path) == "/a/repo\n/b/repo\n"
  end

  test "remove takes one out and leaves the rest; removing what is not there is fine", %{
    path: path
  } do
    OpenHouses.add("/a/repo", path)
    OpenHouses.add("/b/repo", path)

    assert :ok = OpenHouses.remove("/a/repo", path)
    assert :ok = OpenHouses.remove("/nowhere", path)
    assert OpenHouses.read(path) == ["/b/repo"]
  end

  test "a hand-edited file with blank lines and stray whitespace still reads", %{path: path} do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "\n  /a/repo  \n\n/b/repo\n")
    assert OpenHouses.read(path) == ["/a/repo", "/b/repo"]
  end

  describe "open/2 — the record as the statusline may trust it" do
    test "is the record while an owl is in the process table", %{path: path} do
      OpenHouses.add("/a/repo", path)
      assert OpenHouses.open([4242], path) == ["/a/repo"]
    end

    test "is nothing when no owl is alive, whatever the file says", %{path: path} do
      OpenHouses.add("/a/repo", path)
      assert OpenHouses.open([], path) == []
    end
  end

  test "the default path is under the configured whiska home" do
    assert OpenHouses.path() == Path.join(Application.fetch_env!(:whiska, :home), "houses")
  end
end
