defmodule Whiska.Desktop.Notifier do
  @moduledoc """
  Raises a notification with `terminal-notifier` when it is installed, and with
  `osascript` when it is not (ADR-next-a-hoot-reaches-you-without-herdr).
  Neither — Linux, or a Mac with osascript removed — is `{:error,
  :no_notifier}`, never a crash.

  The text is somebody else's: a branch name and a pointer line arrive from a
  doorstep file anything in the repo can write. So the program is run directly
  with an argument list and no shell, and osascript's script is fixed text that
  reads the title and body from `argv` — the branch never becomes AppleScript
  source. Two things a single argument still carries are defused: a NUL byte,
  which no argument can hold, is dropped; and a leading `-`, `(`, `{`, `<` or
  quote, which terminal-notifier's argument parsing would read as an option or
  a property list, gets a zero-width space in front of it.
  """

  @behaviour Whiska.Desktop

  # A notifier that does not come back is given up on: the owl's house runs
  # this inline, and a hoot is never worth holding delivery for.
  @default_timeout_ms 5_000

  @sounds %{request: "Ping", done: "Glass", none: ""}

  @doc """
  Options: `:find` (how a program is looked up, `System.find_executable/1` by
  default), `:timeout_ms`.
  """
  @impl true
  def notify(notification, opts \\ []) do
    find = Keyword.get(opts, :find, &System.find_executable/1)
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

    case command(notification, find) do
      nil -> {:error, :no_notifier}
      {path, args} -> run(path, args, timeout)
    end
  end

  @doc "The program to run and its arguments, or `nil` when there is none."
  @spec command(Whiska.Herdr.notification(), (String.t() -> String.t() | nil)) ::
          {String.t(), [String.t()]} | nil
  def command(%{title: title, body: body, sound: sound}, find) do
    sound = Map.fetch!(@sounds, sound)

    cond do
      path = find.("terminal-notifier") ->
        {path,
         ["-title", defuse(title), "-message", defuse(body)] ++
           if(sound == "", do: [], else: ["-sound", sound])}

      path = find.("osascript") ->
        {path, script(display()) ++ [clean(title), clean(body), sound]}

      true ->
        nil
    end
  end

  @doc false
  # The fixed script, around one line that uses `argv`. Public so a test can
  # run the real interpreter over the same prologue without drawing anything.
  def script(action), do: ["-e", "on run argv", "-e", action, "-e", "end run"]

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
      "" -> "​"
      <<c, _::binary>> = t when c in ~c"-({<\"'" -> "​" <> t
      t -> t
    end
  end

  defp run(path, args, timeout) do
    name = Path.basename(path)
    task = Task.async(fn -> System.cmd(path, args, stderr_to_stdout: true) end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {_out, 0}} -> {:ok, name}
      {:ok, {_out, status}} -> {:error, {name, {:exit, status}}}
      {:exit, reason} -> {:error, {name, {:raised, reason}}}
      nil -> {:error, {name, :timeout}}
    end
  end
end
