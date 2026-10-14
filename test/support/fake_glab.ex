defmodule Whiska.Test.FakeGlab do
  @moduledoc """
  A `glab` on disk that answers `glab api` the way the real one does with
  `--include`: a status line, headers, a blank line and the body on stdout,
  noise on stderr, and a non-zero exit for anything but a 2xx.

  Each answer is a file the test writes, named for the API path it answers; a
  path with a query is looked up as written, then without its query. A path
  nobody answered is a 404. Every call's arguments are kept, one call to a
  line, so a test can see exactly what was run.

  The forge's tool is replaced on disk, as `pr_test.exs` replaces `gh`:
  nothing in Elixir is mocked for it (ADR-0031).
  """

  @type t :: %{dir: Path.t(), bin: Path.t(), calls: Path.t()}

  @doc "A fresh fake under `root`."
  @spec create(Path.t()) :: t()
  def create(root) do
    dir = Path.join(root, "fake-glab-#{System.unique_integer([:positive])}")
    answers = Path.join(dir, "answers")
    File.mkdir_p!(answers)
    bin = Path.join(dir, "glab")
    calls = Path.join(dir, "calls")

    File.write!(bin, """
    #!/bin/sh
    printf '%s\\037' "$@" >> '#{calls}'
    printf '\\n' >> '#{calls}'
    echo "DEPRECATION WARNING: noise a real glab prints" >&2
    for last in "$@"; do path="$last"; done
    key=$(printf '%s' "$path" | tr -c 'A-Za-z0-9' '_')
    base=$(printf '%s' "${path%%\\?*}" | tr -c 'A-Za-z0-9' '_')
    for k in "$key" "$base"; do
      if [ -f '#{answers}'/"$k" ]; then
        if [ -f '#{answers}'/"$k.sleep" ]; then sleep "$(cat '#{answers}'/"$k.sleep")"; fi
        cat '#{answers}'/"$k"
        exit "$(cat '#{answers}'/"$k.exit")"
      fi
    done
    printf 'HTTP/2.0 404 Not Found\\nContent-Type: application/json\\n\\n{"message":"404 Not found"}'
    exit 1
    """)

    File.chmod!(bin, 0o755)
    %{dir: dir, bin: bin, calls: calls}
  end

  @doc """
  Answer `path` with `body`, encoded as JSON unless it is a string.

  Options: `:status` (200), `:headers` (a map), `:sleep` (seconds before
  answering).
  """
  @spec answer(t(), String.t(), term(), keyword()) :: :ok
  def answer(fake, path, body, opts \\ []) do
    status = Keyword.get(opts, :status, 200)
    headers = Keyword.get(opts, :headers, %{})
    text = if is_binary(body), do: body, else: JSON.encode!(body)

    head =
      ["HTTP/2.0 #{status} #{reason(status)}", "Content-Type: application/json"] ++
        Enum.map(headers, fn {k, v} -> "#{k}: #{v}" end)

    file = Path.join([fake.dir, "answers", key(path)])
    # Written whole under another name and renamed, so a read in flight sees
    # the old answer or the new one and never half of either.
    File.write!(file <> ".exit.tmp", if(status in 200..299, do: "0", else: "1"))
    File.rename!(file <> ".exit.tmp", file <> ".exit")

    case Keyword.get(opts, :sleep) do
      nil -> File.rm(file <> ".sleep")
      seconds -> File.write!(file <> ".sleep", to_string(seconds))
    end

    File.write!(file <> ".tmp", Enum.join(head, "\r\n") <> "\r\n\r\n" <> text)
    File.rename!(file <> ".tmp", file)
  end

  @doc "Every call so far, each as its argument list."
  @spec calls(t()) :: [[String.t()]]
  def calls(fake) do
    case File.read(fake.calls) do
      {:ok, text} ->
        text
        |> String.split("\n", trim: true)
        |> Enum.map(&String.split(&1, "\x1f", trim: true))

      {:error, :enoent} ->
        []
    end
  end

  defp key(path), do: String.replace(path, ~r/[^A-Za-z0-9]/, "_")

  defp reason(200), do: "OK"
  defp reason(401), do: "Unauthorized"
  defp reason(403), do: "Forbidden"
  defp reason(404), do: "Not Found"
  defp reason(429), do: "Too Many Requests"
  defp reason(_), do: "Status"
end
