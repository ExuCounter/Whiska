defmodule Whiska.BundledNIF do
  @moduledoc """
  Carries SQLite's native library inside the escript, and unpacks it on first run.

  ## Why this exists

  ADR-0030 asks for two things that are, on the face of it, incompatible: a single
  binary from `mix escript.build`, and real Ecto + SQLite. An escript is a zip
  archive, and two things follow from that. It contains no `priv/` directories at
  all, so `exqlite`'s `sqlite3_nif.so` never ships inside it; and even if it did,
  native code has to be `dlopen`ed from a real file on disk, which nothing inside
  a zip is.

  So the library travels as bytes embedded in this module, and the first
  invocation writes it to a cache directory laid out the way `:code.priv_dir/1`
  expects — `<cache>/exqlite-<vsn>/{ebin,priv}` — and puts that on the code path.
  `Exqlite.Sqlite3NIF` then finds it exactly where it always looks, and nothing in
  `exqlite` has to know any of this happened.

  ## Its expiry date

  This is scaffolding with a known end. ADR-0033 replaces this hook with a native
  client once the owl arrives, and at that point the hook stops touching storage
  altogether — the owl holds the database open and the hook just talks to it over
  a socket. This module gets deleted whole; nothing else depends on it.
  """

  require Logger

  @nif_name "sqlite3_nif.so"
  @source Path.join(:code.priv_dir(:exqlite), @nif_name)
  @external_resource @source
  @nif File.read!(@source)
  @nif_size byte_size(@nif)
  @vsn Application.spec(:exqlite, :vsn) |> to_string()

  @doc """
  Make SQLite loadable, and return the directory it was unpacked into.

  Safe to call on every invocation: once the cached copy is present and the right
  size, this is a single `stat` and a code-path append.
  """
  @spec ensure_loadable() :: {:ok, Path.t()} | {:error, term()}
  def ensure_loadable do
    with {:ok, lib_dir} <- unpack(cache_root()) do
      :code.add_patha(String.to_charlist(Path.join(lib_dir, "ebin")))
      {:ok, lib_dir}
    end
  end

  @doc """
  Unpack the bundled NIF beneath `root`, unless a good copy is already there.
  """
  @spec unpack(Path.t()) :: {:ok, Path.t()} | {:error, term()}
  def unpack(root) do
    lib_dir = Path.join(root, "exqlite-#{@vsn}")
    nif = Path.join(lib_dir, "priv/#{@nif_name}")

    if current?(nif) do
      {:ok, lib_dir}
    else
      write(lib_dir, nif)
    end
  end

  # Size is enough of a check here: the bytes are compiled in, so the only way a
  # cached copy differs is a truncated write or a version bump, and the version
  # already has its own directory.
  defp current?(nif) do
    match?({:ok, %File.Stat{type: :regular, size: @nif_size}}, File.stat(nif))
  end

  defp write(lib_dir, nif) do
    # The hook runs many times per session and several can start at once, so the
    # NIF is written to a unique temporary name and renamed into place. A rename
    # within one filesystem is atomic: a concurrent invocation sees either the
    # old file or the complete new one, never a half-written one.
    tmp = "#{nif}.#{System.unique_integer([:positive])}.tmp"

    with :ok <- File.mkdir_p(Path.dirname(nif)),
         :ok <- File.mkdir_p(Path.join(lib_dir, "ebin")),
         :ok <- File.write(tmp, @nif),
         :ok <- File.chmod(tmp, 0o755),
         :ok <- File.rename(tmp, nif) do
      {:ok, lib_dir}
    else
      {:error, reason} ->
        File.rm(tmp)
        {:error, reason}
    end
  end

  defp cache_root do
    base =
      System.get_env("XDG_CACHE_HOME") ||
        Path.join(System.user_home!() || System.tmp_dir!(), ".cache")

    Path.join(base, "whiska")
  end
end
