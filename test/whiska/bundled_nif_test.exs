defmodule Whiska.BundledNIFTest do
  use ExUnit.Case, async: false

  alias Whiska.BundledNIF

  setup do
    cache = Path.join(System.tmp_dir!(), "whiska-nif-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(cache) end)
    {:ok, cache: cache}
  end

  describe "unpack/1" do
    test "writes the NIF where the code path can find it", %{cache: cache} do
      assert {:ok, lib_dir} = BundledNIF.unpack(cache)

      # :code.priv_dir/1 resolves an app by finding "<name>-<vsn>/ebin" on the
      # code path and looking next to it, so both directories have to exist.
      assert File.dir?(Path.join(lib_dir, "ebin"))
      assert File.regular?(Path.join(lib_dir, "priv/sqlite3_nif.so"))
    end

    test "writes the real NIF, byte for byte", %{cache: cache} do
      {:ok, lib_dir} = BundledNIF.unpack(cache)

      unpacked = File.read!(Path.join(lib_dir, "priv/sqlite3_nif.so"))
      original = File.read!(Path.join(:code.priv_dir(:exqlite), "sqlite3_nif.so"))

      assert unpacked == original
    end

    test "leaves the NIF executable", %{cache: cache} do
      {:ok, lib_dir} = BundledNIF.unpack(cache)
      %File.Stat{mode: mode} = File.stat!(Path.join(lib_dir, "priv/sqlite3_nif.so"))

      assert Bitwise.band(mode, 0o100) != 0
    end

    test "is idempotent — the hook runs hundreds of times per session", %{cache: cache} do
      {:ok, lib_dir} = BundledNIF.unpack(cache)
      written_at = File.stat!(Path.join(lib_dir, "priv/sqlite3_nif.so")).mtime

      assert {:ok, ^lib_dir} = BundledNIF.unpack(cache)
      assert {:ok, ^lib_dir} = BundledNIF.unpack(cache)

      assert File.stat!(Path.join(lib_dir, "priv/sqlite3_nif.so")).mtime == written_at
    end

    test "re-extracts if the cached copy is truncated or corrupt", %{cache: cache} do
      {:ok, lib_dir} = BundledNIF.unpack(cache)
      nif = Path.join(lib_dir, "priv/sqlite3_nif.so")
      File.write!(nif, "junk")

      assert {:ok, ^lib_dir} = BundledNIF.unpack(cache)
      assert File.read!(nif) == File.read!(Path.join(:code.priv_dir(:exqlite), "sqlite3_nif.so"))
    end

    test "the cache directory is versioned, so an upgrade cannot reuse a stale NIF", %{
      cache: cache
    } do
      {:ok, lib_dir} = BundledNIF.unpack(cache)

      assert Path.basename(lib_dir) =~ ~r/^exqlite-\d+\.\d+\.\d+$/
    end
  end
end
