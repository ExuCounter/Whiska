defmodule Whiska.Herdr.Socket do
  @moduledoc """
  The real herdr client: newline-delimited JSON over herdr's Unix socket.

  Two facts about the wire, both checked against herdr 0.8.2:

  - A plain request gets one reply and herdr then closes the connection, so
    every request opens its own.
  - `events.subscribe` is different: the reply is `subscription_started` and
    the connection stays open, streaming one `{"event": ..., "data": ...}` line
    per event. That connection is held by a process of its own, which forwards
    events to the listener and dies when herdr hangs up.

  Lines are assembled by hand rather than with `packet: :line`: a `pane.list`
  reply from a busy herdr runs past 64 KB, and the line packet mode hands back
  a truncated line once its buffer fills.
  """

  @behaviour Whiska.Herdr

  @connect_timeout 2_000
  @reply_timeout 5_000

  @impl true
  def list_panes(socket) do
    with {:ok, %{"result" => %{"panes" => panes}}} when is_list(panes) <-
           request(socket, "pane.list", %{}) do
      {:ok, Enum.map(panes, &pane/1)}
    else
      {:ok, other} -> {:error, {:unexpected_reply, other}}
      {:error, _} = error -> error
    end
  end

  @impl true
  def pane(socket, pane_id) do
    with {:ok, %{"result" => %{"pane" => raw}}} when is_map(raw) <-
           request(socket, "pane.get", %{"pane_id" => pane_id}) do
      {:ok, pane(raw)}
    else
      {:ok, other} -> {:error, {:unexpected_reply, other}}
      {:error, _} = error -> error
    end
  end

  @impl true
  def read_screen(socket, pane_id) do
    # With its styling: faint text in the prompt box is Claude Code's own
    # suggestion, not the person's draft, and only the escapes say which.
    params = %{
      "pane_id" => pane_id,
      "source" => "visible",
      "format" => "ansi",
      "strip_ansi" => false
    }

    with {:ok, %{"result" => %{"read" => %{"text" => text}}}} when is_binary(text) <-
           request(socket, "pane.read", params) do
      {:ok, text}
    else
      {:ok, other} -> {:error, {:unexpected_reply, other}}
      {:error, _} = error -> error
    end
  end

  @impl true
  def prompt(socket, pane_id, text) do
    with {:ok, %{"result" => _}} <-
           request(socket, "agent.prompt", %{"target" => pane_id, "text" => text}) do
      :ok
    else
      {:ok, other} -> {:error, {:unexpected_reply, other}}
      {:error, _} = error -> error
    end
  end

  @impl true
  def run_command(socket, pane_id, command) do
    # The newline is the Enter that runs it: herdr sends the text as
    # keystrokes, so an alias or a shell function in the person's own profile
    # is honoured exactly as if they had typed the line themselves.
    params = %{"pane_id" => pane_id, "text" => command <> "\n"}

    with {:ok, %{"result" => _}} <- request(socket, "pane.send_text", params) do
      :ok
    else
      {:ok, other} -> {:error, {:unexpected_reply, other}}
      {:error, _} = error -> error
    end
  end

  @impl true
  def focus(socket, pane_id) do
    with {:ok, %{"result" => _}} <- request(socket, "pane.focus", %{"pane_id" => pane_id}) do
      :ok
    else
      {:ok, other} -> {:error, {:unexpected_reply, other}}
      {:error, _} = error -> error
    end
  end

  @impl true
  def worktrees(socket, checkout) do
    with {:ok, %{"result" => %{"worktrees" => worktrees}}} when is_list(worktrees) <-
           request(socket, "worktree.list", %{"cwd" => checkout}) do
      {:ok, worktrees |> Enum.filter(& &1["is_linked_worktree"]) |> Enum.map(&worktree/1)}
    else
      {:ok, other} -> {:error, {:unexpected_reply, other}}
      {:error, _} = error -> error
    end
  end

  @impl true
  def remove_worktree(socket, workspace_id) do
    params = %{"workspace_id" => workspace_id, "force" => false}

    with {:ok, %{"result" => _}} <- request(socket, "worktree.remove", params) do
      :ok
    else
      {:ok, other} -> {:error, {:unexpected_reply, other}}
      {:error, _} = error -> error
    end
  end

  defp worktree(raw) do
    %{path: raw["path"], branch: raw["branch"], workspace_id: raw["open_workspace_id"]}
  end

  # `position` is deliberately not sent: herdr documents it as affecting its
  # own in-app toast only, and where that toast sits is the person's taste,
  # already settled in their config.
  @impl true
  def notify(socket, %{title: title, body: body, sound: sound}) do
    params = %{"title" => title, "body" => body, "sound" => Atom.to_string(sound)}

    case request(socket, "notification.show", params) do
      {:ok, %{"result" => %{"shown" => true}}} -> {:ok, :shown}
      {:ok, %{"result" => %{"shown" => false, "reason" => why}}} -> {:ok, {:not_shown, why}}
      {:ok, %{"result" => %{"shown" => false}}} -> {:ok, {:not_shown, "no reason given"}}
      {:ok, other} -> {:error, {:unexpected_reply, other}}
      {:error, _} = error -> error
    end
  end

  defp pane(raw) do
    %{
      pane_id: raw["pane_id"],
      workspace_id: raw["workspace_id"],
      cwd: raw["cwd"],
      agent: raw["agent"],
      agent_status: raw["agent_status"] || "unknown",
      title: raw["terminal_title_stripped"],
      session: session(raw["agent_session"]),
      scroll_offset: scroll_offset(raw["scroll"])
    }
  end

  defp scroll_offset(%{"offset_from_bottom" => rows}) when is_integer(rows), do: rows
  defp scroll_offset(_unsaid), do: nil

  # herdr names the agent's own session under `agent_session`, and only for a
  # pane running one. For Claude Code the value is the session id, which is the
  # transcript's filename (ADR-0053's folder, this file's name).
  defp session(%{"value" => value}) when is_binary(value) and value != "", do: value
  defp session(_none), do: nil

  @impl true
  def subscribe(socket, subscriptions, listener) do
    parent = self()
    ref = make_ref()

    pid =
      spawn_link(fn ->
        case open_subscription(socket, subscriptions) do
          {:ok, conn} ->
            send(parent, {ref, :ok})
            stream(conn, listener)

          {:error, reason} ->
            send(parent, {ref, {:error, reason}})
        end
      end)

    receive do
      {^ref, :ok} -> {:ok, pid}
      {^ref, {:error, reason}} -> {:error, reason}
    after
      @connect_timeout + @reply_timeout -> {:error, :timeout}
    end
  end

  defp open_subscription(socket, subscriptions) do
    params = %{"subscriptions" => Enum.map(subscriptions, &stringify/1)}

    with {:ok, conn} <- connect(socket),
         :ok <- send_request(conn, "events.subscribe", params),
         {:ok, %{"result" => %{"type" => "subscription_started"}}} <- read_line(conn) do
      {:ok, conn}
    else
      {:ok, other} -> {:error, {:unexpected_reply, other}}
      {:error, _} = error -> error
    end
  end

  defp stream(conn, listener, rest \\ "") do
    case recv_line(conn, rest, :infinity) do
      {:ok, line, rest} ->
        case JSON.decode(line) do
          {:ok, %{"event" => name, "data" => data}} -> send(listener, {:herdr_event, name, data})
          _ -> :ok
        end

        stream(conn, listener, rest)

      {:error, reason} ->
        # Linked to the listener so it cannot outlive the house — which means
        # the exit has to be normal, or losing herdr would take the house down
        # with it instead of letting it resubscribe.
        send(listener, {:herdr_subscription_lost, reason})
        exit(:normal)
    end
  end

  defp request(socket, method, params) do
    with {:ok, conn} <- connect(socket) do
      try do
        with :ok <- send_request(conn, method, params) do
          read_line(conn)
        end
      after
        :gen_tcp.close(conn)
      end
    end
  end

  defp connect(socket) do
    :gen_tcp.connect(
      {:local, socket},
      0,
      [:binary, packet: :line, active: false],
      @connect_timeout
    )
  end

  defp send_request(conn, method, params) do
    id = "whiska:#{System.unique_integer([:positive])}"

    :gen_tcp.send(
      conn,
      JSON.encode!(%{"id" => id, "method" => method, "params" => params}) <> "\n"
    )
  end

  defp read_line(conn) do
    with {:ok, line, _rest} <- recv_line(conn, "", @reply_timeout) do
      case JSON.decode(line) do
        {:ok, %{"error" => error}} -> {:error, {:herdr, error}}
        {:ok, reply} -> {:ok, reply}
        {:error, reason} -> {:error, {:bad_json, reason}}
      end
    end
  end

  # One complete line, however many reads it takes; whatever followed the
  # newline is handed back for the next call.
  defp recv_line(conn, buffer, timeout) do
    case :binary.split(buffer, "\n") do
      [line, rest] ->
        {:ok, line, rest}

      [_] ->
        with {:ok, chunk} <- :gen_tcp.recv(conn, 0, timeout) do
          recv_line(conn, buffer <> chunk, timeout)
        end
    end
  end

  defp stringify(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)
end
