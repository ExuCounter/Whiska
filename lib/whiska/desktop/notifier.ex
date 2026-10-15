defmodule Whiska.Desktop.Notifier do
  @moduledoc """
  Raises a notification with the notifier the machine has (ADR-0062):
  `terminal-notifier` on macOS where it is installed, because it alone carries
  a click that runs a command; `osascript`, which ships with macOS, where it is
  not; `notify-send` on Linux. None — a machine with no desktop — is
  `{:error, :no_notifier}`, never a crash.

  The text is somebody else's: a branch name and a pointer line arrive from a
  doorstep file anything in the repo can write. So the program is run directly
  with an argument list and no shell. osascript's script is fixed text that
  reads the title and body from `argv`, and they follow a `--`, because
  osascript keeps reading options after its last `-e` — a title of `-e` would
  otherwise be more script. notify-send's title and body follow a `--` too,
  which ends its option parsing, and its body has `&`, `<` and `>` escaped,
  since a notification server may render it as markup. A NUL byte, which no
  argument can hold, is dropped.

  terminal-notifier takes each value as a property list: one that begins with
  `(`, `{` or `<` is read as an array, a dictionary or data, and the program
  never returns (checked against 2.0.0). Such a value gets an invisible
  zero-width space in front, which makes it plain text. Its click is a shell
  string, `-execute`, so every path in it is single-quoted, a quote inside one
  closed, escaped and reopened. A click runs `whiska jump` on the main
  checkout with the owl's own `escript` and `whiska` paths, since a click runs
  with almost no `PATH`, and brings kitty forward while it runs.
  """

  @behaviour Whiska.Desktop

  # A notifier that does not come back is given up on: the owl's house runs
  # this inline, and a hoot is never worth holding delivery for.
  @default_timeout_ms 5_000

  @sounds %{request: "Ping", done: "Glass", none: ""}

  # The terminal the person works in; a click brings it forward while it runs.
  @terminal_process "kitty"
  @terminal_bundle "net.kovidgoyal.kitty"

  # The freedesktop sound theme's names for the same two events.
  @freedesktop_sounds %{request: "message-new-instant", done: "complete", none: ""}

  @doc """
  Options: `:find` (how a program is looked up: the `PATH`, then where a package
  manager puts one, since the owl runs under launchd with almost no `PATH`),
  `:timeout_ms`, and `command/3`'s. A failing terminal-notifier is followed by
  osascript, or the next one there is.
  """
  @impl true
  def notify(notification, opts \\ []) do
    find = Keyword.get(opts, :find, &Whiska.Forge.CLI.find/1)
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

    attempt(notification, find, opts, timeout)
  end

  # terminal-notifier is the one that can fail where osascript would not (a
  # value it cannot read, macOS refusing the binary), and a hoot lost is worse
  # than one without a click, so a failure there is tried again with the next.
  defp attempt(notification, find, opts, timeout) do
    case command(notification, find, opts) do
      nil ->
        {:error, :no_notifier}

      {path, args} ->
        with {:error, _} = failed <- run(path, args, timeout) do
          if Path.basename(path) == "terminal-notifier",
            do: next(failed, notification, find, opts, timeout),
            else: failed
        end
    end
  end

  defp next(failed, notification, find, opts, timeout) do
    without = fn name -> if name == "terminal-notifier", do: nil, else: find.(name) end

    case attempt(notification, without, opts, timeout) do
      {:error, :no_notifier} -> failed
      answer -> answer
    end
  end

  @doc """
  The program to run and its arguments, or `nil` when there is none.

  Options: `:running` (whether a process of that name is running, `pgrep` by
  default) and `:whiska` (the argument list that runs `whiska`, the owl's own
  `escript` and script by default), both for terminal-notifier's click.
  """
  @spec command(
          Whiska.Desktop.notification(),
          (String.t() -> String.t() | nil),
          keyword()
        ) :: {String.t(), [String.t()]} | nil
  def command(%{title: title, body: body, sound: event} = notification, find, opts \\ []) do
    sound = Map.fetch!(@sounds, event)

    cond do
      path = find.("terminal-notifier") ->
        {path,
         ["-title", plist_safe(clean(title)), "-message", plist_safe(clean(body))] ++
           terminal_notifier_sound(sound) ++ click(notification, opts)}

      path = find.("osascript") ->
        {path, osascript_args(display(), clean(title), clean(body), sound)}

      path = find.("notify-send") ->
        {path,
         ["--app-name=Whiska"] ++
           freedesktop_sound(@freedesktop_sounds[event]) ++
           ["--", clean(title), body |> clean() |> unmarked()]}

      true ->
        nil
    end
  end

  defp terminal_notifier_sound(""), do: []
  defp terminal_notifier_sound(name), do: ["-sound", name]

  defp plist_safe(text) do
    if String.trim_leading(text) =~ ~r/^[({<]/, do: "\u200b" <> text, else: text
  end

  defp click(%{jump: checkout}, opts) do
    running = Keyword.get(opts, :running, &running?/1)
    whiska = Keyword.get_lazy(opts, :whiska, &whiska_argv/0)

    activate = if running.(@terminal_process), do: ["-activate", @terminal_bundle], else: []
    execute = Enum.map_join(whiska ++ ["jump", checkout], " ", &quote_arg/1)

    activate ++ ["-execute", execute]
  end

  defp click(_notification, _opts), do: []

  # Single quotes hold everything but a single quote, which is closed, escaped
  # and reopened.
  defp quote_arg(text), do: "'" <> String.replace(clean(text), "'", "'\\''") <> "'"

  defp running?(name) do
    match?({_, 0}, System.cmd("pgrep", ["-x", name], stderr_to_stdout: true))
  rescue
    _ -> false
  end

  # How the running owl was started: an escript, run by the `escript` of the
  # Erlang it is running on — which launchd's `PATH` does not reach. Elsewhere,
  # whatever `whiska` is to be found.
  defp whiska_argv do
    with escript when is_binary(escript) <- escript(),
         script when is_list(script) <- script_name() do
      [escript, script |> List.to_string() |> Path.expand()]
    else
      _ -> [Whiska.Forge.CLI.find("whiska") || "whiska"]
    end
  end

  defp escript do
    beside = Path.join([List.to_string(:code.root_dir()), "bin", "escript"])
    if File.regular?(beside), do: beside, else: Whiska.Forge.CLI.find("escript")
  end

  defp script_name do
    :escript.script_name()
  catch
    _, _ -> nil
  end

  # A notification server may render the body as markup, links included, so
  # someone else's text is escaped to read as itself.
  defp unmarked(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  defp freedesktop_sound(""), do: []
  defp freedesktop_sound(name), do: ["--hint=string:sound-name:#{name}"]

  @doc false
  # Public so a test can run the real interpreter over the same arguments with
  # an action that hands them back rather than drawing anything.
  def osascript_args(action, title, body, sound),
    do: ["-e", "on run argv", "-e", action, "-e", "end run", "--", title, body, sound]

  defp display do
    "if item 3 of argv is \"\" then\n" <>
      "display notification (item 2 of argv) with title (item 1 of argv)\n" <>
      "else\n" <>
      "display notification (item 2 of argv) with title (item 1 of argv) " <>
      "sound name (item 3 of argv)\n" <>
      "end if"
  end

  defp clean(text), do: String.replace(text, <<0>>, "")

  # A port rather than `System.cmd`, for its OS pid: a notifier that has not
  # come back by the deadline is killed, not left running behind the owl. The
  # pid is asked for only then — a notifier that has already exited has none.
  defp run(path, args, timeout) do
    name = Path.basename(path)

    port =
      Port.open({:spawn_executable, path}, [:binary, :exit_status, :stderr_to_stdout, args: args])

    deadline = System.monotonic_time(:millisecond) + timeout

    case await(port, deadline) do
      {:exit, 0} ->
        {:ok, name}

      {:exit, status} ->
        {:error, {name, {:exit, status}}}

      :timeout ->
        with {:os_pid, os_pid} <- Port.info(port, :os_pid),
             do: System.cmd("kill", ["-9", Integer.to_string(os_pid)], stderr_to_stdout: true)

        await(port, System.monotonic_time(:millisecond) + 1_000)
        {:error, {name, :timeout}}
    end
  rescue
    e -> {:error, {Path.basename(path), {:raised, Exception.message(e)}}}
  end

  defp await(port, deadline) do
    receive do
      {^port, {:data, _}} -> await(port, deadline)
      {^port, {:exit_status, status}} -> {:exit, status}
    after
      max(deadline - System.monotonic_time(:millisecond), 0) -> :timeout
    end
  end
end
