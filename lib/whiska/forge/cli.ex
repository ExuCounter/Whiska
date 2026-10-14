defmodule Whiska.Forge.CLI do
  @moduledoc """
  The one place a forge's tool runs to read: `glab api`, and `gh api` once
  GitHub is read, through the login the person already has (ADR-0060).

  **Every read is a GET.** Both tools switch to POST as soon as a field flag is
  added and take a method of their own from `-X`, and that login can push,
  merge and comment. So the argument list is built here and nowhere else, the
  only part a caller supplies is the API path, and a path that could pass for
  a flag, or carry a second argument inside a space, is refused before
  anything runs. `argv/2` is what a test pins.

  **It never stops to ask.** `GLAB_NO_PROMPT` and `GH_PROMPT_DISABLED` turn the
  tools' prompts off, and neither checks for an update. The tool runs through a
  port with a deadline and is killed, with what it started, once that passes,
  the way `Whiska.Git.fetch_base/3` treats git.

  **What came back is read from the status line**, which `--include` prints
  before the headers and the body. Stderr goes nowhere, since the tools print
  warnings there and the owl's log is not the place for one a minute. A
  2xx is its body; a 404 is `:missing`, which only the caller can judge; a
  refusal, a rate limit, a server error, a body that is not JSON, a timeout or
  no tool at all is unknown, never an answer (ADR-0060: unknown never alarms).
  """

  alias Whiska.Forge

  # The owl runs under launchd, whose PATH is `/usr/bin:/bin:/usr/sbin:/sbin`
  # (`Whiska.LaunchAgent`), so the places a package manager puts a tool are
  # looked in as well.
  @also_in ["/opt/homebrew/bin", "/usr/local/bin", "/home/linuxbrew/.linuxbrew/bin", "/snap/bin"]

  @path ~r{\A[A-Za-z0-9][A-Za-z0-9._~%/-]*(\?[A-Za-z0-9._~%=&,-]*)?\z}
  @host ~r/\A[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]{1,5})?\z/

  # Stderr is dropped by the shell rather than the port, which can only merge
  # it into what is parsed. The tool and its arguments arrive as `$0` and
  # `$@`, so nothing of theirs is ever read as shell.
  @quiet "exec \"$0\" \"$@\" 2>/dev/null"

  @doc """
  The arguments a read of `path` on `host` runs with: always
  `api --method GET --include --hostname <host> <path>`.
  """
  @spec argv(String.t(), String.t()) ::
          {:ok, [String.t()]} | {:error, :unsafe_path | :unsafe_host}
  def argv(host, path) do
    cond do
      not Regex.match?(@host, host) -> {:error, :unsafe_host}
      not Regex.match?(@path, path) or String.contains?(path, "..") -> {:error, :unsafe_path}
      true -> {:ok, ["api", "--method", "GET", "--include", "--hostname", host, path]}
    end
  end

  @doc "Read `path` on `host` with `run`'s tool."
  @spec get(Forge.run(), String.t(), String.t()) ::
          {:ok, term(), %{String.t() => String.t()}}
          | :missing
          | {:unknown, term(), pos_integer() | nil}
  def get(run, host, path) do
    with {:ok, args} <- argv(host, path) |> unsafe_is_unknown(),
         {:ok, tool} <- tool(run.tool),
         {:ok, out} <- execute(tool, args, run) do
      response(out)
    end
  end

  @doc "Where `tool` is: on the PATH, else where a package manager puts one."
  @spec find(String.t()) :: Path.t() | nil
  def find(tool) do
    System.find_executable(tool) ||
      Enum.find_value(@also_in, fn dir ->
        path = Path.join(dir, tool)
        if executable?(path), do: path
      end)
  end

  defp unsafe_is_unknown({:error, reason}), do: {:unknown, reason, nil}
  defp unsafe_is_unknown(ok), do: ok

  defp tool(path) when is_binary(path) do
    if executable?(path), do: {:ok, path}, else: {:unknown, :no_tool, nil}
  end

  defp tool(_none), do: {:unknown, :no_tool, nil}

  defp executable?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, mode: mode}} -> Bitwise.band(mode, 0o111) != 0
      _ -> false
    end
  end

  defp execute(tool, args, run) do
    case System.find_executable("sh") do
      nil -> {:unknown, :no_shell, nil}
      sh -> spawn(sh, tool, args, run)
    end
  end

  defp spawn(sh, tool, args, run) do
    port =
      Port.open({:spawn_executable, sh}, [
        :binary,
        :exit_status,
        args: ["-c", @quiet, tool | args],
        cd: run.cwd,
        env: env(tool)
      ])

    case await(port, System.monotonic_time(:millisecond) + run.timeout_ms, "") do
      {:exit, _code, out} ->
        {:ok, out}

      :timeout ->
        with {:os_pid, os_pid} <- Port.info(port, :os_pid), do: kill(os_pid)
        await(port, System.monotonic_time(:millisecond) + 1_000, "")
        {:unknown, :timeout, nil}
    end
  end

  # The tool's own folder goes first on the PATH, so whatever it calls in turn
  # is found under launchd too.
  defp env(tool) do
    path = Enum.join([Path.dirname(tool) | @also_in] ++ [System.get_env("PATH", "")], ":")

    [
      {~c"PATH", String.to_charlist(path)},
      {~c"GLAB_NO_PROMPT", ~c"1"},
      {~c"GLAB_CHECK_UPDATE", ~c"false"},
      {~c"GH_PROMPT_DISABLED", ~c"1"},
      {~c"GH_NO_UPDATE_NOTIFIER", ~c"1"},
      {~c"NO_COLOR", ~c"1"}
    ]
  end

  defp await(port, deadline, out) do
    receive do
      {^port, {:data, data}} -> await(port, deadline, out <> data)
      {^port, {:exit_status, code}} -> {:exit, code, out}
    after
      max(deadline - System.monotonic_time(:millisecond), 0) -> :timeout
    end
  end

  # The shell is stopped first, so it starts nothing more, then what it
  # started, then the shell.
  defp kill(os_pid) do
    pid = Integer.to_string(os_pid)
    signal("kill", ["-STOP", pid])
    signal("pkill", ["-9", "-P", pid])
    signal("kill", ["-9", pid])
  end

  defp signal(program, args) do
    with path when is_binary(path) <- System.find_executable(program),
         do: System.cmd(path, args, stderr_to_stdout: true)
  end

  defp response(out) do
    with [head, body] <- String.split(out, ~r/\r?\n\r?\n/, parts: 2),
         [status_line | header_lines] <- String.split(head, ~r/\r?\n/),
         [_, status] <- Regex.run(~r"\AHTTP/[0-9.]+ ([0-9]{3})", status_line) do
      status(String.to_integer(status), headers(header_lines), body)
    else
      _ -> {:unknown, :no_status, nil}
    end
  end

  defp headers(lines) do
    for line <- lines,
        [name, value] <- [String.split(line, ":", parts: 2)],
        into: %{},
        do: {String.downcase(String.trim(name)), String.trim(value)}
  end

  defp status(status, headers, body) when status in 200..299 do
    case JSON.decode(body) do
      {:ok, decoded} -> {:ok, decoded, headers}
      {:error, _} -> {:unknown, :unreadable_body, nil}
    end
  end

  defp status(404, _headers, _body), do: :missing
  defp status(429, headers, _body), do: {:unknown, {:http, 429}, retry_after(headers)}
  defp status(status, _headers, _body), do: {:unknown, {:http, status}, nil}

  # GitLab and GitHub both send `Retry-After` in seconds on a 429.
  defp retry_after(%{"retry-after" => seconds}) do
    case Integer.parse(seconds) do
      {n, ""} when n > 0 -> n * 1_000
      _ -> nil
    end
  end

  defp retry_after(_headers), do: nil
end
