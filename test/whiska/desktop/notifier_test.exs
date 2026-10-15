defmodule Whiska.Desktop.NotifierTest do
  @moduledoc """
  The desktop notifier Whiska raises every hoot with (ADR-0062):
  terminal-notifier on macOS where it is installed, osascript where it is not,
  notify-send on Linux.

  A branch name and a pointer line are somebody else's text — anything in the
  repo can write the doorstep file they come from — and here they reach a
  command line. These tests are about that: every piece of text arrives at the
  program as one argument, byte for byte, and none of it is ever read as shell
  or AppleScript, or as an option. The round-trip tests spawn a real process, so the claim is
  checked through the operating system rather than on a list in memory.
  """
  use ExUnit.Case, async: true

  alias Whiska.Desktop.Notifier

  @nasty ~S|feat/x"; rm -rf ~; echo 'pwned' `whoami` $(id) \" end|

  setup do
    dir = Path.join(System.tmp_dir!(), "whiska-notifier-#{Whiska.Test.Unique.id()}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  defp hoot(attrs \\ []) do
    Map.merge(
      %{title: "🐱 whiska · feat-a needs a decision", body: "#12", sound: :request},
      Map.new(attrs)
    )
  end

  defp only(name, path),
    do: fn
      ^name -> path
      _ -> nil
    end

  # A stand-in for the notifier that writes every argument it received to a
  # file, NUL-separated, so the test reads back exactly what the OS handed it.
  defp recorder(dir, name) do
    path = Path.join(dir, name)
    out = Path.join(dir, "#{name}.args")
    File.write!(path, "#!/bin/sh\nfor a in \"$@\"; do printf '%s\\0' \"$a\"; done > '#{out}'\n")
    File.chmod!(path, 0o755)
    {path, out}
  end

  defp received(out), do: out |> File.read!() |> String.split(<<0>>, trim: true)

  describe "command/2 — the program and its arguments, never a shell string" do
    test "osascript's script is fixed text, and never holds the text" do
      title = "🐱 whiska · #{@nasty} needs a decision"
      body = ~s(#12 · "#{@nasty}")

      assert {"/usr/bin/osascript", args} =
               Notifier.command(
                 hoot(title: title, body: body),
                 only("osascript", "/usr/bin/osascript")
               )

      {script, [^title, ^body, "Ping"]} = Enum.split(args, length(args) - 3)

      refute Enum.join(script, "\n") =~ "feat/x"
      assert "on run argv" in script
    end

    test "terminal-notifier raises it on macOS where it is installed" do
      find = fn
        "terminal-notifier" -> "/opt/homebrew/bin/terminal-notifier"
        "osascript" -> "/usr/bin/osascript"
      end

      assert {"/opt/homebrew/bin/terminal-notifier", args} = Notifier.command(hoot(), find)

      assert args == [
               "-title",
               "🐱 whiska · feat-a needs a decision",
               "-message",
               "#12",
               "-sound",
               "Ping"
             ]
    end

    test "terminal-notifier's sound follows the event, and :none asks for none" do
      tn = only("terminal-notifier", "/tn")

      assert {_, args} = Notifier.command(hoot(sound: :done), tn)
      assert ["-sound", "Glass"] == Enum.take(args, -2)

      assert {_, args} = Notifier.command(hoot(sound: :none), tn)
      refute "-sound" in args
    end

    test "a click jumps to the main session, and brings kitty forward while it runs" do
      opts = [running: fn "kitty" -> true end, whiska: ["/e/escript", "/w/whiska"]]

      assert {_, args} =
               Notifier.command(
                 hoot(jump: "/Users/me/repo"),
                 only("terminal-notifier", "/tn"),
                 opts
               )

      assert ["-activate", "net.kovidgoyal.kitty", "-execute", execute] = Enum.take(args, -4)
      assert execute == "'/e/escript' '/w/whiska' 'jump' '/Users/me/repo'"
    end

    test "a click only jumps when kitty is not running" do
      opts = [running: fn "kitty" -> false end, whiska: ["/w/whiska"]]

      assert {_, args} =
               Notifier.command(hoot(jump: "/repo"), only("terminal-notifier", "/tn"), opts)

      refute "-activate" in args
      assert ["-execute", "'/w/whiska' 'jump' '/repo'"] == Enum.take(args, -2)
    end

    test "a hoot with nowhere to jump has no click" do
      opts = [running: fn _ -> true end, whiska: ["/w/whiska"]]
      assert {_, args} = Notifier.command(hoot(), only("terminal-notifier", "/tn"), opts)
      refute "-execute" in args
      refute "-activate" in args
    end

    test "the click's shell string reads a path with quotes as one argument, never as shell",
         %{dir: dir} do
      path = "/Users/me/it's here; touch #{dir}/pwned $(id)"
      opts = [running: fn _ -> false end, whiska: ["/usr/bin/printf", "%s|"]]

      {_, args} =
        Notifier.command(hoot(jump: path), only("terminal-notifier", "/tn"), opts)

      execute = List.last(args)
      assert {out, 0} = System.cmd("/bin/sh", ["-c", execute])
      assert out == "jump|#{path}|"
      refute File.exists?(Path.join(dir, "pwned"))
    end

    # terminal-notifier reads each value as a property list: one that starts
    # with ( { or < is parsed as an array, dictionary or data and the program
    # never returns (checked against 2.0.0 on macOS). An invisible zero-width
    # space in front makes it plain text.
    test "a title or text that a property list would read as structure is made plain" do
      tn = only("terminal-notifier", "/tn")

      for text <- ["(a, b)", "{x = y;}", "<616263>", " (a)", "\t(a)", "\n{a}"] do
        assert {_, ["-title", title, "-message", body | _]} =
                 Notifier.command(hoot(title: text, body: text), tn)

        assert String.starts_with?(title, "​")
        assert String.starts_with?(body, "​")
        assert String.ends_with?(body, String.trim_leading(text))
      end

      assert {_, ["-title", "-e", "-message", "[x]" | _]} =
               Notifier.command(hoot(title: "-e", body: "[x]"), tn)
    end

    test "a NUL byte is dropped from terminal-notifier's text too" do
      assert {_, ["-title", "ab", "-message", "cd" | _]} =
               Notifier.command(
                 hoot(title: "a\0b", body: "c\0d"),
                 only("terminal-notifier", "/tn")
               )
    end

    test "notify-send is the Linux notifier, with the title and text after a --" do
      title = "🐱 whiska · #{@nasty} needs a decision"

      assert {"/usr/bin/notify-send", args} =
               Notifier.command(hoot(title: title), only("notify-send", "/usr/bin/notify-send"))

      assert args == [
               "--app-name=Whiska",
               "--hint=string:sound-name:message-new-instant",
               "--",
               title,
               "#12"
             ]
    end

    test "notify-send's sound is a freedesktop sound name, and :none asks for none" do
      assert {_, args} = Notifier.command(hoot(sound: :done), only("notify-send", "/n"))
      assert "--hint=string:sound-name:complete" in args

      assert {_, args} = Notifier.command(hoot(sound: :none), only("notify-send", "/n"))
      refute Enum.any?(args, &String.starts_with?(&1, "--hint"))
    end

    test "a title of -e, or a NUL, reaches notify-send as data" do
      {_, args} = Notifier.command(hoot(title: "-e", body: "a\0b"), only("notify-send", "/n"))
      assert ["--", "-e", "ab"] == Enum.take(args, -3)
    end

    test "notify-send's text is escaped, since a notification server may render it as markup" do
      body = ~s(#12 · <a href="https://evil.example">Approve</a> & <b>now</b>)

      {_, args} = Notifier.command(hoot(body: body), only("notify-send", "/n"))

      assert List.last(args) ==
               ~s(#12 · &lt;a href="https://evil.example"&gt;Approve&lt;/a&gt; &amp; &lt;b&gt;now&lt;/b&gt;)
    end

    test "osascript wins where it is there" do
      find = fn
        "osascript" -> "/usr/bin/osascript"
        "notify-send" -> "/usr/bin/notify-send"
        _ -> nil
      end

      assert {"/usr/bin/osascript", _} = Notifier.command(hoot(), find)
    end

    test "no notifier at all is no command" do
      assert Notifier.command(hoot(), fn _ -> nil end) == nil
    end

    test "a finished branch takes the other sound, and :none takes no sound at all" do
      assert {_, args} = Notifier.command(hoot(sound: :done), only("osascript", "/o"))
      assert List.last(args) == "Glass"

      assert {_, args} = Notifier.command(hoot(sound: :none), only("osascript", "/o"))
      assert List.last(args) == ""
    end

    test "osascript's data follows a --, so a title of -e is never more script" do
      {_, args} = Notifier.command(hoot(title: "-e"), only("osascript", "/o"))

      assert ["--", "-e", "#12", "Ping"] == Enum.take(args, -4)
    end

    test "a NUL byte, which no argument can carry, is dropped rather than crashing" do
      {_, args} = Notifier.command(hoot(body: "a\0b"), only("osascript", "/o"))
      assert Enum.at(args, -2) == "ab"
    end
  end

  describe "notify/2 — through a real process" do
    test "the same branch reaches osascript intact, after the fixed script", %{dir: dir} do
      {path, out} = recorder(dir, "osascript")
      title = "🐱 whiska · #{@nasty} needs a decision"

      assert {:ok, "osascript"} =
               Notifier.notify(hoot(title: title), find: only("osascript", path))

      assert Enum.take(received(out), -3) == [title, "#12", "Ping"]
      # Nothing ran: no shell ever saw the text, so `rm`, `whoami` and `id` are
      # just characters in an argument.
      refute File.exists?(Path.join(dir, "pwned"))
    end

    test "the same branch reaches terminal-notifier intact, as the value after its flag",
         %{dir: dir} do
      {path, out} = recorder(dir, "terminal-notifier")
      title = "🐱 whiska · #{@nasty} needs a decision"

      assert {:ok, "terminal-notifier"} =
               Notifier.notify(hoot(title: title), find: only("terminal-notifier", path))

      assert Enum.take(received(out), 4) == ["-title", title, "-message", "#12"]
      refute File.exists?(Path.join(dir, "pwned"))
    end

    test "a terminal-notifier that fails is followed by osascript, so the hoot is not lost",
         %{dir: dir} do
      tn = Path.join(dir, "terminal-notifier")
      File.write!(tn, "#!/bin/sh\nexit 1\n")
      File.chmod!(tn, 0o755)
      {osa, out} = recorder(dir, "osascript")

      find = fn
        "terminal-notifier" -> tn
        "osascript" -> osa
        _ -> nil
      end

      assert {:ok, "osascript"} = Notifier.notify(hoot(), find: find)

      assert Enum.take(received(out), -3) ==
               ["🐱 whiska · feat-a needs a decision", "#12", "Ping"]
    end

    test "a failing terminal-notifier with nothing after it is its own error", %{dir: dir} do
      tn = Path.join(dir, "terminal-notifier")
      File.write!(tn, "#!/bin/sh\nexit 1\n")
      File.chmod!(tn, 0o755)

      assert {:error, {"terminal-notifier", {:exit, 1}}} =
               Notifier.notify(hoot(), find: only("terminal-notifier", tn))
    end

    test "the same branch reaches notify-send intact", %{dir: dir} do
      {path, out} = recorder(dir, "notify-send")
      title = "🐱 whiska · #{@nasty} needs a decision"

      assert {:ok, "notify-send"} =
               Notifier.notify(hoot(title: title), find: only("notify-send", path))

      assert Enum.take(received(out), -3) == ["--", title, "#12"]
    end

    @tag :notify_send
    test "the real notify-send reads a title of --help as the title, not an option", %{
      dir: dir
    } do
      # Read as an option, --help prints the usage and exits 0. Read as the
      # title, it is sent, and with no session bus to reach that fails instead.
      notify_send = System.find_executable("notify-send")

      {path, args} =
        Notifier.command(hoot(title: "--help", body: "x"), only("notify-send", notify_send))

      {out, status} =
        System.cmd(path, args,
          stderr_to_stdout: true,
          env: [{"DBUS_SESSION_BUS_ADDRESS", "unix:path=#{dir}/no-bus"}]
        )

      refute out =~ ~r/usage/i
      refute status == 0
    end

    test "the real osascript reads the text as data, not as AppleScript", %{dir: dir} do
      # The script's own prologue, with `display notification` swapped for
      # handing the arguments back — the one part of the real script that
      # touches the text, run by the real interpreter, without drawing anything.
      if osascript = System.find_executable("osascript") do
        pwned = Path.join(dir, "pwned")

        for {title, body} <- [
              {"🐱 whiska · #{@nasty} needs a decision", ~s{#12 · "#{@nasty}"}},
              {"-e", ~s{property p : (do shell script "touch #{pwned}")}}
            ] do
          args =
            Notifier.osascript_args(
              ~s[return (item 1 of argv) & linefeed & (item 2 of argv)],
              title,
              body,
              "Ping"
            )

          {out, 0} = System.cmd(osascript, args)

          assert out == title <> "\n" <> body <> "\n"
        end

        refute File.exists?(pwned)
      end
    end

    test "no notifier is an answer, not a crash" do
      assert Notifier.notify(hoot(), find: fn _ -> nil end) == {:error, :no_notifier}
    end

    test "a notifier that fails says how, and does not raise", %{dir: dir} do
      path = Path.join(dir, "osascript")
      File.write!(path, "#!/bin/sh\necho broken >&2\nexit 3\n")
      File.chmod!(path, 0o755)

      assert {:error, {"osascript", {:exit, 3}}} =
               Notifier.notify(hoot(), find: only("osascript", path))
    end

    test "a notifier that hangs is given up on and killed, not left running", %{dir: dir} do
      path = Path.join(dir, "osascript")
      seconds = "30.#{System.unique_integer([:positive])}"
      File.write!(path, "#!/bin/sh\nexec sleep #{seconds}\n")
      File.chmod!(path, 0o755)

      assert {:error, {"osascript", :timeout}} =
               Notifier.notify(hoot(), find: only("osascript", path), timeout_ms: 300)

      assert {_, 1} = System.cmd("pgrep", ["-f", "sleep #{seconds}"])
    end

    test "a notifier that exits at once is an answer, never a raise" do
      # Finished before its pid can be asked for: Linux, under load, hits this
      # on an ordinary run.
      instant = System.find_executable("true")

      answers =
        1..200
        |> Task.async_stream(
          fn _ -> Notifier.notify(hoot(), find: only("notify-send", instant)) end,
          max_concurrency: 16
        )
        |> Enum.map(fn {:ok, answer} -> answer end)

      assert Enum.uniq(answers) == [{:ok, "true"}]
    end

    test "a notifier that vanished after it was found is an answer, even unsupervised" do
      parent = self()

      spawn(fn ->
        send(
          parent,
          {:answer, Notifier.notify(hoot(), find: only("osascript", "/nope/osascript"))}
        )
      end)

      assert_receive {:answer, {:error, {"osascript", _}}}, 2_000
    end
  end

  # Draws a real notification on the screen. Off by default; run it with
  # `mix test --include live_desktop` and look.
  @tag :live_desktop
  test "a hoot appears on this Mac" do
    assert {:ok, _} =
             Notifier.notify(%{
               title: "🐱 whiska · #{@nasty} needs a decision",
               body: "#0 · live test from the notifier suite",
               sound: :request
             })
  end
end
