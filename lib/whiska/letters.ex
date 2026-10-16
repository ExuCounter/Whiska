defmodule Whiska.Letters do
  @moduledoc """
  The person's words for a mouse, as letters: files in its worktree, holding
  what `whiska send` hands a running mouse and the comments `whiska spawn
  --from` hands a fresh one. A mouse reads its own worktree without asking anyone, which a file the
  main session wrote elsewhere is not.

  A letter from another repo's main session (`whiska tell`) is kept in the
  house, beside its database (`put_house/2`).

  The folder is ignored through the main checkout's `.git/info/exclude`, like
  the spec (`Whiska.Spec`), so it never reaches a commit or keeps the owl from
  reading the worktree clean.
  """

  @folder ".whiska-letters"
  @name ~r/\A\d{8}-\d{6}-[0-9a-f]{8}\.md\z/

  @spec exclude_line() :: String.t()
  def exclude_line, do: "/" <> @folder <> "/"

  @doc "Whether `path` is where `put/3` or `write/3` lays a letter in a worktree."
  @spec copy?(String.t()) :: boolean()
  def copy?(path) do
    Path.type(path) == :absolute and Path.basename(Path.dirname(path)) == @folder and
      Regex.match?(@name, Path.basename(path))
  end

  @doc """
  Copy `source` into `worktree`'s letters under a name no earlier letter has.
  Answers the copy's absolute path.
  """
  @spec put(Path.t(), Path.t(), Path.t()) :: {:ok, Path.t()} | {:error, term()}
  def put(main_checkout, worktree, source) do
    with {:ok, copy} <- new_path(main_checkout, worktree),
         :ok <- File.cp(source, copy) do
      {:ok, copy}
    end
  end

  @doc """
  Write `text` into `worktree`'s letters under a name no earlier letter has,
  for a letter Whiska writes itself. Answers its absolute path. The folder
  must be a plain folder and the file new: nothing is written through a link.
  """
  @spec write(Path.t(), Path.t(), String.t()) :: {:ok, Path.t()} | {:error, term()}
  def write(main_checkout, worktree, text) do
    with {:ok, path} <- new_path(main_checkout, worktree),
         {:ok, %File.Stat{type: :directory}} <- File.lstat(Path.dirname(path)),
         :ok <- File.write(path, text, [:exclusive]) do
      {:ok, path}
    else
      {:ok, %File.Stat{}} -> {:error, :not_a_plain_folder}
      {:error, _} = error -> error
    end
  end

  @doc """
  Copy `source` into the letters of the house at `main_checkout`, beside its
  database, for a letter from another house's main session (`whiska tell`).
  Answers the copy's absolute path. Two repos may tell one house in the same
  second, so the name is random and the copy never replaces a file.
  """
  @spec put_house(Path.t(), Path.t()) :: {:ok, Path.t()} | {:error, term()}
  def put_house(main_checkout, source) do
    folder = house_folder(main_checkout)
    path = Path.join(folder, name())

    with :ok <- File.mkdir_p(folder),
         {:ok, %File.Stat{type: :directory}} <- File.lstat(folder),
         :ok <- File.chmod(folder, 0o700),
         {:ok, text} <- File.read(source),
         :ok <- File.write(path, "", [:exclusive]),
         :ok <- File.chmod(path, 0o600),
         :ok <- File.write(path, text) do
      {:ok, path}
    else
      {:ok, %File.Stat{}} -> {:error, :not_a_plain_folder}
      {:error, _} = error -> error
    end
  end

  @doc """
  Whether `path` is a plain file named as `put_house/2` names one, directly in
  `main_checkout`'s house letters, and that folder a plain folder: nothing
  reached through a link.
  """
  @spec in_house?(Path.t(), Path.t()) :: boolean()
  def in_house?(main_checkout, path) do
    folder = house_folder(main_checkout)

    Path.dirname(path) == folder and Path.basename(path) =~ @name and
      match?({:ok, %File.Stat{type: :directory}}, File.lstat(folder)) and
      match?({:ok, %File.Stat{type: :regular}}, File.lstat(path))
  end

  defp house_folder(main_checkout),
    do: Path.join(Path.dirname(Whiska.Storage.database_path(main_checkout)), "letters")

  defp new_path(main_checkout, worktree) do
    folder = Path.join(worktree, @folder)
    path = Path.join(folder, name())

    with :ok <- Whiska.Spec.ignore(main_checkout, exclude_line()),
         :ok <- File.mkdir_p(folder),
         do: {:ok, path}
  end

  defp name do
    stamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%d-%H%M%S")
    "#{stamp}-#{Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)}.md"
  end

  @doc """
  The text of a file the person's words were written to: a plain file with
  something in it.
  """
  @spec read(Path.t()) :: {:ok, String.t()} | {:error, String.t()}
  def read(path) do
    case File.read(path) do
      {:ok, text} ->
        if String.trim(text) == "", do: {:error, "#{path} is empty."}, else: {:ok, text}

      {:error, :eisdir} ->
        {:error, "#{path} is a folder, not a file."}

      {:error, reason} ->
        {:error, "could not read #{path} (#{:file.format_error(reason)})."}
    end
  end
end
