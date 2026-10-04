defmodule Whiska.Desktop.NotifierTest do
  @moduledoc """
  The macOS notifier Whiska raises a hoot with when herdr will not show it
  (ADR-next-a-hoot-reaches-you-without-herdr).

  A branch name and a pointer line are somebody else's text — anything in the
  repo can write the doorstep file they come from — and here they reach a
  command line. These tests are about that: every piece of text arrives at the
  program as one argument, byte for byte, and none of it is ever read as shell
  or AppleScript. The round-trip tests spawn a real process, so the claim is
  checked through the operating system rather than on a list in memory.
  """
  use ExUnit.Case, async: true

  alias Whiska.Desktop.Notifier

  @nasty ~S|feat/x"; rm -rf ~; echo 'pwned' `whoami` $(id) \" end|

  setup do
    dir = Path.join(System.tmp_dir!(), "whiska-notifier-#{System.unique_integer([:positive])}")
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
    test "terminal-notifier gets the title and the text as arguments of their own" do
      title = "🐱 whiska · #{@nasty} needs a decision"

      assert {"/bin/tn", args} =
               Notifier.command(hoot(title: title), only("terminal-notifier", "/bin/tn"))

      assert args == ["-title", title, "-message", "#12", "-sound", "Ping"]
    end

    test "osascript is the fallback, and its script never holds the text" do
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

    test "terminal-notifier wins when both are there" do
      find = fn
        "terminal-notifier" -> "/bin/tn"
        "osascript" -> "/usr/bin/osascript"
      end

      assert {"/bin/tn", _} = Notifier.command(hoot(), find)
    end

    test "no notifier at all is no command, which is how Linux degrades" do
      assert Notifier.command(hoot(), fn _ -> nil end) == nil
    end

    test "a finished branch takes the other sound, and :none takes no sound at all" do
      assert {_, args} = Notifier.command(hoot(sound: :done), only("terminal-notifier", "/t"))
      assert ["-sound", "Glass"] == Enum.take(args, -2)

      assert {_, args} = Notifier.command(hoot(sound: :none), only("terminal-notifier", "/t"))
      refute "-sound" in args

      assert {_, args} = Notifier.command(hoot(sound: :none), only("osascript", "/o"))
      assert List.last(args) == ""
    end

    test "a title gets the same defusing as the text, and leading whitespace does not hide one" do
      for start <- [" (a, b)", "\n<array/>", "\t{a = b;}", "-execute"] do
        {_, args} =
          Notifier.command(hoot(title: start, body: start), only("terminal-notifier", "/t"))

        assert Enum.at(args, 1) == "\u200B" <> start
        assert Enum.at(args, 3) == "\u200B" <> start
      end
    end

    test "osascript's data follows a --, so a title of -e is never more script" do
      {_, args} = Notifier.command(hoot(title: "-e"), only("osascript", "/o"))

      assert ["--", "-e", "#12", "Ping"] == Enum.take(args, -4)
    end

    test "text that terminal-notifier would read as an option or a plist is defused" do
      for start <- ["-remove ALL", "(a, b)", "{a = b;}", "<data>"] do
        {_, args} = Notifier.command(hoot(body: start), only("terminal-notifier", "/t"))
        message = Enum.at(args, 3)

        assert message == "​" <> start
      end
    end

    test "a NUL byte, which no argument can carry, is dropped rather than crashing" do
      {_, args} = Notifier.command(hoot(body: "a\0b"), only("terminal-notifier", "/t"))
      assert Enum.at(args, 3) == "ab"
    end

    test "an empty text is never sent empty: terminal-notifier would wait on stdin" do
      {_, args} = Notifier.command(hoot(body: ""), only("terminal-notifier", "/t"))
      assert Enum.at(args, 3) != ""
    end
  end

  describe "notify/2 — through a real process" do
    test "a branch with quotes, backticks and a semicolon reaches terminal-notifier intact", %{
      dir: dir
    } do
      {path, out} = recorder(dir, "terminal-notifier")
      title = "🐱 whiska · #{@nasty} needs a decision"
      body = ~s(#12 · "#{@nasty}")

      assert {:ok, "terminal-notifier"} =
               Notifier.notify(hoot(title: title, body: body),
                 find: only("terminal-notifier", path)
               )

      assert received(out) == ["-title", title, "-message", body, "-sound", "Ping"]
      # Nothing ran: no shell ever saw the text, so `rm`, `whoami` and `id` are
      # just characters in an argument.
      refute File.exists?(Path.join(dir, "pwned"))
    end

    test "the same branch reaches osascript intact, after the fixed script", %{dir: dir} do
      {path, out} = recorder(dir, "osascript")
      title = "🐱 whiska · #{@nasty} needs a decision"

      assert {:ok, "osascript"} =
               Notifier.notify(hoot(title: title), find: only("osascript", path))

      assert Enum.take(received(out), -3) == [title, "#12", "Ping"]
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

    test "a notifier outside the owl's PATH is still found where Homebrew puts it", %{dir: dir} do
      path = Path.join(dir, "terminal-notifier")
      File.write!(path, "#!/bin/sh\n")
      File.chmod!(path, 0o755)

      assert Notifier.locate("terminal-notifier", [Path.join(dir, "missing"), dir]) == path
      assert Notifier.locate("osascript-not-here", [dir]) == nil
    end

    test "no notifier is an answer, not a crash" do
      assert Notifier.notify(hoot(), find: fn _ -> nil end) == {:error, :no_notifier}
    end

    test "a notifier that fails says how, and does not raise", %{dir: dir} do
      path = Path.join(dir, "terminal-notifier")
      File.write!(path, "#!/bin/sh\necho broken >&2\nexit 3\n")
      File.chmod!(path, 0o755)

      assert {:error, {"terminal-notifier", {:exit, 3}}} =
               Notifier.notify(hoot(), find: only("terminal-notifier", path))
    end

    test "a notifier that hangs is given up on and killed, not left running", %{dir: dir} do
      path = Path.join(dir, "terminal-notifier")
      seconds = "30.#{System.unique_integer([:positive])}"
      File.write!(path, "#!/bin/sh\nexec sleep #{seconds}\n")
      File.chmod!(path, 0o755)

      assert {:error, {"terminal-notifier", :timeout}} =
               Notifier.notify(hoot(), find: only("terminal-notifier", path), timeout_ms: 300)

      assert {_, 1} = System.cmd("pgrep", ["-f", "sleep #{seconds}"])
    end

    test "a notifier that vanished after it was found is an answer, even unsupervised" do
      parent = self()

      spawn(fn ->
        send(
          parent,
          {:answer, Notifier.notify(hoot(), find: only("terminal-notifier", "/nope/tn"))}
        )
      end)

      assert_receive {:answer, {:error, {"tn", _}}}, 2_000
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
