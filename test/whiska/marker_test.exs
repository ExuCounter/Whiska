defmodule Whiska.MarkerTest do
  use ExUnit.Case, async: true

  alias Whiska.Marker

  setup do
    root = Path.join(System.tmp_dir!(), "whiska-marker-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, worktree: root}
  end

  describe "read_or_mint/1" do
    test "mints an id and writes the marker file on first call", %{worktree: worktree} do
      refute File.exists?(Path.join(worktree, ".whiska-mouse"))

      assert {:ok, mouse_id} = Marker.read_or_mint(worktree)

      assert is_binary(mouse_id)
      assert File.read!(Path.join(worktree, ".whiska-mouse")) == mouse_id <> "\n"
    end

    test "is lazy: the same worktree keeps the id it was first given", %{worktree: worktree} do
      assert {:ok, first} = Marker.read_or_mint(worktree)
      assert {:ok, second} = Marker.read_or_mint(worktree)
      assert {:ok, third} = Marker.read_or_mint(worktree)

      assert first == second
      assert second == third
    end

    test "mints a distinct id per worktree", %{worktree: worktree} do
      other = worktree <> "-other"
      File.mkdir_p!(other)
      on_exit(fn -> File.rm_rf!(other) end)

      assert {:ok, a} = Marker.read_or_mint(worktree)
      assert {:ok, b} = Marker.read_or_mint(other)

      refute a == b
    end

    test "the id is opaque — not the branch name, not the folder path", %{worktree: worktree} do
      # ADR-0002: branch and path are mutable labels, never the identity.
      assert {:ok, mouse_id} = Marker.read_or_mint(worktree)

      refute String.contains?(mouse_id, Path.basename(worktree))
      refute String.contains?(mouse_id, "/")
      assert String.length(mouse_id) >= 16
    end

    test "tolerates trailing whitespace in a hand-edited marker", %{worktree: worktree} do
      File.write!(Path.join(worktree, ".whiska-mouse"), "  abc123  \n\n")

      assert {:ok, "abc123"} = Marker.read_or_mint(worktree)
    end

    test "re-mints when the marker file is present but empty", %{worktree: worktree} do
      File.write!(Path.join(worktree, ".whiska-mouse"), "\n")

      assert {:ok, mouse_id} = Marker.read_or_mint(worktree)
      refute mouse_id == ""
      assert {:ok, ^mouse_id} = Marker.read_or_mint(worktree)
    end
  end
end
