defmodule Whiska.HouseFile do
  @moduledoc """
  A file Whiska writes for the person under `.whiska/` in the main checkout:
  ignored through `.git/info/exclude`, so no committed file changes, and
  replaced whole by a rename.

  A link in the folder would carry the write anywhere the person can write,
  such as a folder Claude Code reads as instructions, so a folder that is a
  link refuses the write. A link at the file itself is replaced by the rename,
  never followed.
  """

  alias Whiska.Spec

  @exclude_line "/.whiska/"

  @doc "Write `text` to `name` in `dir`, a folder under `.whiska/`, and return its path."
  @spec write(Path.t(), String.t(), String.t(), iodata()) :: {:ok, Path.t()} | {:error, term()}
  def write(main_checkout, dir, name, text) do
    folder = Path.join(main_checkout, dir)
    path = Path.join(folder, name)
    temp = "#{path}.#{System.unique_integer([:positive])}.tmp"

    with :ok <- Spec.ignore(main_checkout, @exclude_line),
         :ok <- no_link(main_checkout, dir),
         :ok <- File.mkdir_p(folder),
         :ok <- no_link(main_checkout, dir),
         :ok <- File.write(temp, text, [:exclusive]),
         :ok <- rename(temp, path) do
      {:ok, path}
    end
  end

  defp no_link(main_checkout, dir) do
    dir
    |> Path.split()
    |> Enum.scan(&Path.join(&2, &1))
    |> Enum.find(&match?({:ok, %{type: :symlink}}, File.lstat(Path.join(main_checkout, &1))))
    |> case do
      nil -> :ok
      link -> {:error, {:symlink, link}}
    end
  end

  defp rename(temp, path) do
    with {:error, _} = error <- File.rename(temp, path) do
      File.rm(temp)
      error
    end
  end
end
