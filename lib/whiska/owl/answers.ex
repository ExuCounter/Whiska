defmodule Whiska.Owl.Answers do
  @moduledoc """
  The owl's read-only socket, `~/.whiska/owl.sock` (ADR-0033): what the
  person's own scripts ask, with `nc -U`, instead of starting Whiska.

  One request line in, one line out, then the connection is closed. Every JSON
  answer carries `"version": 1`, which changes only when a field does — the
  same promise `whiska where` makes, because scripts outside this repo depend on
  it. The format is documented in the README.

  | Request | Answer |
  | --- | --- |
  | `waiting` | `{"version":1,"waiting":[row, …]}`, the rows `whiska waiting --json` prints |
  | `show <id> <main_checkout>` | `{"version":1,"question":{…}}`, one question with its whole text |
  | `jump` | `{"version":1,"whiskas":[row, …]}`, the rows `whiska jump --list --json` prints |
  | `questions <main_checkout>` | `{"version":1,"questions":"…"}`, the text `whiska questions` prints there |
  | `line [hint]` | the tab bar's line, plain text |
  | anything else | `{"version":1,"error":"…"}` |

  Question ids are numbered per house, so `show` needs the main checkout as
  well; everything after the id is that path, spaces and all. `show` and
  `questions` answer only for a house in the open-houses record, and `show`
  only when its database is already there, so asking about a path never
  creates one. `jump` and `questions` are what the project picker asks, so it
  starts no escript.

  The owl answering `line` is the owl being up, so the line says it is watching
  — unless entries have waited on a doorstep past the backstop, which means it
  is up and not collecting (`Whiska.Statusline`).

  Options, for a test: `:open_houses`, the record's path, and `:away_path`.
  """

  alias Whiska.OpenHouses
  alias Whiska.Question.Marker
  alias Whiska.Questions
  alias Whiska.Schema.Mouse
  alias Whiska.Schema.Question
  alias Whiska.Statusline
  alias Whiska.Storage
  alias Whiska.Waiting

  @version 1
  @timeout 2_000

  @doc false
  def handle(socket, opts) do
    :ok = :inet.setopts(socket, packet: :line)

    with {:ok, line} <- :gen_tcp.recv(socket, 0, @timeout) do
      reply = line |> String.trim_trailing("\n") |> String.trim_trailing("\r") |> answer(opts)
      :gen_tcp.send(socket, [reply, "\n"])
    end
  end

  @doc "The answer to one request line, without its newline."
  @spec answer(String.t(), keyword()) :: String.t()
  def answer("waiting", opts) do
    encode(%{"waiting" => opts |> Waiting.list() |> Enum.map(&Waiting.row_map/1)})
  end

  def answer("show " <> rest, opts) do
    with [id, main] <- String.split(rest, " ", parts: 2),
         {id, ""} <- Integer.parse(id) do
      show(id, Path.expand(main), opts)
    else
      _ -> error("unknown request")
    end
  end

  def answer("jump", opts) do
    encode(%{"whiskas" => opts |> Waiting.whiskas() |> Waiting.whiskas_json() |> JSON.decode!()})
  end

  def answer("questions " <> main, opts), do: questions(Path.expand(main), opts)

  def answer("line", opts), do: line(nil, opts)
  def answer("line " <> hint, opts), do: line(String.trim(hint), opts)
  def answer(_request, _opts), do: error("unknown request")

  defp line(hint, opts) do
    opts
    |> Keyword.put(:owl_pids, fn -> [String.to_integer(System.pid())] end)
    |> Statusline.summary()
    |> Statusline.render(hint: hint)
  end

  defp recorded?(main, opts) do
    main in (opts |> Keyword.get_lazy(:open_houses, &OpenHouses.path/0) |> OpenHouses.read())
  end

  defp questions(main, opts) do
    if recorded?(main, opts) do
      case Questions.summary(main, Keyword.take(opts, [:away_path])) do
        {:ok, summary} -> encode(%{"questions" => Questions.render(summary)})
        {:error, _} -> error("unreadable house")
      end
    else
      error("no such house")
    end
  catch
    :error, _ -> error("unreadable house")
    :exit, _ -> error("unreadable house")
  end

  defp show(id, main, opts) do
    if recorded?(main, opts) and File.exists?(Storage.database_path(main)) do
      case read(main, id) do
        %Question{} = q -> encode(%{"question" => question_map(q, main)})
        nil -> error("no such question")
        :unreadable -> error("unreadable house")
      end
    else
      error("no such house")
    end
  end

  # A database that will not open, or raises while it is read, is one house's
  # trouble; the caller still gets an answer rather than a closed connection.
  defp read(main, id) do
    case Storage.within(main, fn -> question(id) end) do
      {:error, _} -> :unreadable
      found -> found
    end
  catch
    :error, _ -> :unreadable
    :exit, _ -> :unreadable
  end

  defp question(id) do
    case Storage.question(id) do
      %Question{} = q -> %{q | mouse: Storage.mouse(q.mouse_id)}
      nil -> nil
    end
  end

  defp question_map(%Question{} = q, main) do
    %{
      "id" => q.id,
      "repo" => Path.basename(main),
      "main_checkout" => main,
      "branch" => branch(q),
      "kind" => q.kind,
      "status" => q.status,
      "pointer" => Marker.pointer(q.text || ""),
      "text" => q.text,
      "asked_at" => q.asked_at && DateTime.to_iso8601(q.asked_at)
    }
  end

  defp branch(%Question{mouse: %Mouse{branch: branch}}) when is_binary(branch), do: branch
  defp branch(%Question{mouse_id: mouse_id}), do: mouse_id

  defp error(message), do: encode(%{"error" => message})

  defp encode(fields), do: fields |> Map.put("version", @version) |> JSON.encode!()
end
