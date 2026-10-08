defmodule Whiska.Owl.Listener do
  @moduledoc """
  One Unix socket the owl answers on (ADR-0033).

  Each connection is handed to its own process, so an answer that takes a while
  — a house whose database is busy — never holds up the next caller. The
  handler module reads the request, writes the answer and closes; the listener
  only accepts.

  The socket is owner-only, so only the person's own account can connect. A
  socket file left by an owl that crashed is removed at start; one that still
  answers belongs to an owl that is running, and is left alone, since there is
  one owl per machine (ADR-0001). A socket that cannot be opened — a whiska home
  too deep for the 104-byte limit macOS puts on a socket's path — is said in the
  log and skipped: every caller falls back when nobody answers, and the owl's
  real work goes on without it.
  """

  use GenServer

  @doc """
  Options: `:path`, where the socket lives; `:handler`, a module with
  `handle/2`, given each connection and `:handler_opts`.
  """
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def child_spec(opts) do
    %{id: {__MODULE__, Keyword.fetch!(opts, :path)}, start: {__MODULE__, :start_link, [opts]}}
  end

  @impl true
  def init(opts) do
    path = Keyword.fetch!(opts, :path)
    handler = {Keyword.fetch!(opts, :handler), Keyword.get(opts, :handler_opts, [])}
    Process.flag(:trap_exit, true)

    with :ok <- claim(path),
         {:ok, listen} <- listen(path) do
      owner = self()
      acceptor = spawn_link(fn -> accept(listen, handler, owner) end)
      {:ok, %{path: path, listen: listen, acceptor: acceptor}}
    else
      {:error, reason} ->
        say(path, reason)
        :ignore
    end
  end

  @impl true
  def handle_info({:EXIT, pid, reason}, %{acceptor: pid} = state),
    do: {:stop, reason, state}

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{path: path, listen: listen}) do
    :gen_tcp.close(listen)
    File.rm(path)
    :ok
  end

  defp claim(path) do
    File.mkdir_p!(Path.dirname(path))

    cond do
      not File.exists?(path) -> :ok
      answers?(path) -> {:error, :held_by_another_owl}
      true -> File.rm(path)
    end
  end

  defp answers?(path) do
    case :gen_tcp.connect({:local, path}, 0, [:binary, active: false], 500) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      {:error, _} ->
        false
    end
  end

  defp listen(path) do
    with {:ok, listen} <-
           :gen_tcp.listen(0, [:binary, packet: :raw, active: false, ifaddr: {:local, path}]),
         :ok <- File.chmod(path, 0o600) do
      {:ok, listen}
    end
  end

  defp accept(listen, handler, owner) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        pid = spawn(fn -> serve(socket, handler) end)
        :ok = :gen_tcp.controlling_process(socket, pid)
        send(pid, :go)
        accept(listen, handler, owner)

      {:error, :closed} ->
        :ok

      # Out of file descriptors, most likely. Crashing here would restart the
      # listener into the same wall until the owl itself gave up, houses and
      # all, so it waits and tries again; callers fall back meanwhile.
      {:error, _reason} ->
        Process.sleep(100)
        accept(listen, handler, owner)
    end
  end

  # The handler starts only once it owns the socket.
  defp serve(socket, {handler, opts}) do
    receive do
      :go -> :ok
    end

    try do
      handler.handle(socket, opts)
    after
      :gen_tcp.close(socket)
    end
  end

  defp say(path, :held_by_another_owl),
    do: Whiska.Owl.Log.line("whiska: another owl is answering on #{path} — not listening there")

  defp say(path, reason),
    do: Whiska.Owl.Log.line("whiska: could not listen on #{path} (#{inspect(reason)})")
end
