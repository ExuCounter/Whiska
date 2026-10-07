defmodule Whiska.Owl.Hooks do
  @moduledoc """
  The hook socket: Whiska's own hooks, answered by the owl rather than by a
  fresh escript (ADR-0033).

  The shim sends the hook's name, the environment it fired in and its payload;
  the owl runs the very modules `whiska hook <name>` runs, and sends back what
  that command would have printed. Whatever the shim cannot read as an answer —
  nothing, a closed connection, a hook this owl does not know — sends it to the
  escript, so a dead, hung or older owl changes nothing about what a hook does.

  The request:

      hook 1 <hook-name> <payload-bytes>[ --global]
      HERDR_PANE_ID=w1:p2
      …
      <blank line>
      <exactly payload-bytes of payload>

  The answer is `ok <exit-status>` on its own line, then the hook's stdout.

  The environment is the hook's, never the owl's. An owl started by hand in the
  main session's pane carries that pane's id, and read from there every mouse
  would be the main session (ADR-0053). Only the variables the hooks read are
  taken.

  A request is believed as the escript believes its stdin: anyone who can reach
  this socket is the person's own account, and could run `whiska hook stop` with
  the same payload (ADR-0033). Warnings the hooks print go to the owl's log.
  """

  alias Whiska.Hook.PreToolUse
  alias Whiska.Hook.SessionStart
  alias Whiska.Hook.Stop
  alias Whiska.Hook.UserPromptSubmit
  alias Whiska.Owl
  alias Whiska.Owl.House

  @version "1"
  @env ~w(HERDR_ENV HERDR_PANE_ID CLAUDE_PROJECT_DIR HOME PWD)
  @timeout 2_000
  @max_payload 16 * 1024 * 1024

  @doc false
  def handle(socket, _opts) do
    deadline = System.monotonic_time(:millisecond) + @timeout

    with {:ok, hook, bytes} <- header(socket, deadline),
         {:ok, env} <- env(socket, %{}, deadline),
         {:ok, payload} <- payload(socket, bytes, deadline) do
      answer(socket, hook, payload, env)
    end
  end

  defp header(socket, deadline) do
    with {:ok, line} <- line(socket, deadline) do
      case String.split(line, " ") do
        ["hook", @version, name, bytes | flags] -> hook(name, flags, bytes)
        _ -> {:error, :not_a_request}
      end
    end
  end

  defp hook(name, flags, bytes) do
    with {n, ""} when n in 0..@max_payload <- Integer.parse(bytes),
         {:ok, hook} <- known(name, flags) do
      {:ok, hook, n}
    else
      _ -> {:error, :not_a_request}
    end
  end

  defp known("pre-tool-use", []), do: {:ok, :pre_tool_use}
  defp known("stop", []), do: {:ok, :stop}
  defp known("user-prompt-submit", []), do: {:ok, :user_prompt_submit}
  defp known("session-start", []), do: {:ok, {:session_start, :repo}}
  defp known("session-start", ["--global"]), do: {:ok, {:session_start, :global}}
  defp known(_name, _flags), do: :error

  defp env(socket, acc, deadline) do
    case line(socket, deadline) do
      {:ok, ""} ->
        {:ok, acc}

      {:ok, pair} ->
        case String.split(pair, "=", parts: 2) do
          [key, value] when key in @env -> env(socket, Map.put(acc, key, value), deadline)
          _ -> env(socket, acc, deadline)
        end

      error ->
        error
    end
  end

  # The whole request has one deadline, so a caller trickling it in a line at a
  # time is cut off as surely as one that sends nothing.
  defp line(socket, deadline) do
    :ok = :inet.setopts(socket, packet: :line)

    case :gen_tcp.recv(socket, 0, left(deadline)) do
      {:ok, line} -> {:ok, String.trim_trailing(line, "\n")}
      error -> error
    end
  end

  defp payload(_socket, 0, _deadline), do: {:ok, ""}

  defp payload(socket, bytes, deadline) do
    :ok = :inet.setopts(socket, packet: :raw)
    :gen_tcp.recv(socket, bytes, left(deadline))
  end

  defp left(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  # A house the owl cannot read or write is no answer: the connection closes
  # with nothing said, and the shim runs the escript, which may well reach it.
  # Answering would put the owl's weaker fallback in place of the escript's
  # real decision.
  defp answer(socket, :pre_tool_use, payload, env) do
    case PreToolUse.judge(payload, env) do
      :unreadable -> :no_answer
      decision -> decision |> PreToolUse.encode() |> printed() |> reply(socket)
    end
  end

  # The entry is on the doorstep before the shim hears back, and the
  # connection is closed before the house is asked to collect it: collecting
  # is the owl's own business, and the mouse does not wait for it. A house too
  # busy to answer in time collects on its next trigger instead.
  defp answer(socket, :stop, payload, env) do
    case Stop.leave(payload, env) do
      {:error, _} ->
        :no_answer

      left ->
        reply("", socket)
        collect(left)
    end
  end

  # Taken only once the answer is out: a stamp on an answer that never reached
  # the session is an answer nobody rings for again (ADR-0080). The stamp comes
  # after the connection is closed, so the session does not wait for it.
  defp answer(socket, :user_prompt_submit, payload, env) do
    case UserPromptSubmit.handover(payload, env) do
      :none ->
        reply("", socket)

      {:error, _} ->
        :no_answer

      {output, take} ->
        if reply(printed(output), socket) == :ok, do: take.()
    end
  end

  defp answer(socket, {:session_start, scope}, payload, env) do
    case SessionStart.output(payload, env, scope) do
      :none -> reply("", socket)
      output -> reply(output, socket)
    end
  end

  defp collect({:left, main}) do
    with {:ok, house} <- Owl.house(main), do: House.collect(house)
  catch
    :exit, _busy -> :ok
  end

  defp collect(:ok), do: :ok

  # What `IO.puts/1` would have printed, as the escript does.
  defp printed(:none), do: ""
  defp printed(output), do: output <> "\n"

  # Closing is what lets the shim go: `nc` reads until the owl hangs up.
  defp reply(stdout, socket) do
    sent = :gen_tcp.send(socket, ["ok 0\n", stdout])
    :gen_tcp.close(socket)
    sent
  end
end
