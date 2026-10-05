defmodule Whiska.Desktop.Notifier do
  @moduledoc """
  Raises a notification with the first notifier this machine has (ADR-0071):
  `terminal-notifier`, then `osascript` on macOS, then `notify-send` on Linux.
  None — a machine with no desktop — is `{:error, :no_notifier}`, never a
  crash.

  The text is somebody else's: a branch name and a pointer line arrive from a
  doorstep file anything in the repo can write. So the program is run directly
  with an argument list and no shell. osascript's script is fixed text that
  reads the title and body from `argv`, and they follow a `--`, because
  osascript keeps reading options after its last `-e` — a title of `-e` would
  otherwise be more script. notify-send's title and body follow a `--` too,
  which ends its option parsing, and its body has `&`, `<` and `>` escaped,
  since a notification server may render it as markup. Two things a single argument still carries
  are defused: a NUL byte, which no argument can hold, is dropped; and a
  leading `-`, `(`, `{`, `<` or quote, after any whitespace, which
  terminal-notifier's argument parsing would read as an option or a property
  list, gets a zero-width space in front of it.

  The owl runs under a service manager whose PATH has no Homebrew in it, so a
  program not on PATH is also looked for where Homebrew installs one.
  """

  @behaviour Whiska.Desktop

  import Bitwise

  # A notifier that does not come back is given up on: the owl's house runs
  # this inline, and a hoot is never worth holding delivery for.
  @default_timeout_ms 5_000

  @sounds %{request: "Ping", done: "Glass", none: ""}

  # The freedesktop sound theme's names for the same two events.
  @freedesktop_sounds %{request: "message-new-instant", done: "complete", none: ""}

  @homebrew ["/opt/homebrew/bin", "/usr/local/bin"]

  @doc """
  Options: `:find` (how a program is looked up, `System.find_executable/1` by
  default), `:timeout_ms`.
  """
  @impl true
  def notify(notification, opts \\ []) do
    find = Keyword.get(opts, :find, &find/1)
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

    case command(notification, find) do
      nil -> {:error, :no_notifier}
      {path, args} -> run(path, args, timeout)
    end
  end

  @doc "The program to run and its arguments, or `nil` when there is none."
  @spec command(Whiska.Herdr.notification(), (String.t() -> String.t() | nil)) ::
          {String.t(), [String.t()]} | nil
  def command(%{title: title, body: body, sound: event}, find) do
    sound = Map.fetch!(@sounds, event)

    cond do
      path = find.("terminal-notifier") ->
        {path,
         ["-title", defuse(title), "-message", defuse(body)] ++
           if(sound == "", do: [], else: ["-sound", sound])}

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

  @doc false
  def locate(name, dirs) do
    dirs
    |> Enum.map(&Path.join(&1, name))
    |> Enum.find(&executable?/1)
  end

  defp find(name), do: System.find_executable(name) || locate(name, @homebrew)

  defp executable?(path) do
    match?(
      {:ok, %File.Stat{type: :regular, mode: mode}} when (mode &&& 0o111) != 0,
      File.stat(path)
    )
  end

  defp display do
    "if item 3 of argv is \"\" then\n" <>
      "display notification (item 2 of argv) with title (item 1 of argv)\n" <>
      "else\n" <>
      "display notification (item 2 of argv) with title (item 1 of argv) " <>
      "sound name (item 3 of argv)\n" <>
      "end if"
  end

  defp clean(text), do: String.replace(text, <<0>>, "")

  defp defuse(text) do
    case clean(text) do
      "" -> "\u200B"
      t -> if String.trim_leading(t) =~ ~r/\A[-({<"']/, do: "\u200B" <> t, else: t
    end
  end

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
