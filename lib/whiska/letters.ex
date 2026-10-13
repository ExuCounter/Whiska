defmodule Whiska.Letters do
  @moduledoc """
  The person's words for a mouse, as letters: files in its worktree, holding
  what `whiska send` hands a running mouse and the comments `whiska spawn
  --from` hands a fresh one. A mouse reads its own worktree without asking anyone, which a file the
  main session wrote elsewhere is not.

  The folder is ignored through the main checkout's `.git/info/exclude`, like
  the spec (`Whiska.Spec`), so it never reaches a commit or keeps the owl from
  reading the worktree clean.
  """

  @folder ".whiska-letters"

  @spec exclude_line() :: String.t()
  def exclude_line, do: "/" <> @folder <> "/"

  @doc """
  Copy `source` into `worktree`'s letters under a name no earlier letter has.
  Answers the copy's absolute path.
  """
  @spec put(Path.t(), Path.t(), Path.t()) :: {:ok, Path.t()} | {:error, term()}
  def put(main_checkout, worktree, source) do
    folder = Path.join(worktree, @folder)
    stamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%d-%H%M%S")
    copy = Path.join(folder, "#{stamp}-#{System.unique_integer([:positive])}.md")

    with :ok <- Whiska.Spec.ignore(main_checkout, exclude_line()),
         :ok <- File.mkdir_p(folder),
         :ok <- File.cp(source, copy) do
      {:ok, copy}
    end
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
