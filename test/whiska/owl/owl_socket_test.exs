defmodule Whiska.Owl.OwlSocketTest do
  @moduledoc """
  The owl's read-only socket, asked the way the person's own scripts ask it:
  one line through `nc -U`, one line back (ADR-0025).
  """
  # Serial: the owl is one named process per VM.
  use ExUnit.Case, async: false

  import Mox

  alias Whiska.Herdr.Mock, as: Herdr
  alias Whiska.Owl
  alias Whiska.Storage
  alias Whiska.Waiting

  setup :set_mox_global
  setup {Whiska.Test.QuietSidebar, :stub_sidebar}

  setup do
    root = Path.join(System.tmp_dir!(), "whiska-owlsock-#{System.unique_integer([:positive])}")
    main = Path.join(root, "myrepo")
    File.mkdir_p!(Path.join(main, ".git"))
    record = Path.join(root, "houses")
    File.write!(record, main <> "\n")
    away = Path.join(root, "away")

    sockets = Path.join("/tmp", "wsk-#{System.unique_integer([:positive])}")
    File.mkdir_p!(sockets)

    on_exit(fn ->
      File.rm_rf!(root)
      File.rm_rf!(sockets)
    end)

    stub(Herdr, :list_panes, fn _ -> {:ok, []} end)
    stub(Herdr, :subscribe, fn _, _, _ -> {:ok, spawn(fn -> receive do: (:stop -> :ok) end)} end)

    start_supervised!(
      {Owl,
       herdr_socket: "/fake/herdr.sock",
       sockets: sockets,
       answers: [open_houses: record, away_path: away]}
    )

    {:ok, root: root, main: main, record: record, away: away, sockets: sockets}
  end

  defp ask(sockets, request) do
    {out, 0} =
      System.cmd("bash", [
        "-c",
        ~s|printf '%s\\n' "$1" \| nc -w 2 -U "$2"|,
        "ask",
        request,
        Path.join(sockets, "owl.sock")
      ])

    out
  end

  defp ask_json(sockets, request), do: sockets |> ask(request) |> JSON.decode!()

  defp question(main, text, opts \\ []) do
    {:ok, handle} = Storage.open(main)

    try do
      {:ok, _} =
        Storage.record_mouse(%{
          mouse_id: "m-1",
          path: Path.join(main, "worktrees/feat-x"),
          branch: "feat-x"
        })

      if Keyword.get(opts, :held, false), do: {:ok, _} = Storage.hold("m-1")

      {:ok, q} = Storage.record_question(%{mouse_id: "m-1", text: text, kind: "needs-decision"})
      q
    after
      Storage.close(handle)
    end
  end

  describe "waiting" do
    test "lists what whiska waiting --json lists, wrapped with a version", c do
      question(c.main, "Two ways.\n\n[worktree-status: needs-decision] which store?")

      assert %{"version" => 1, "waiting" => [row]} = ask_json(c.sockets, "waiting")

      [expected] =
        [open_houses: c.record, away_path: c.away]
        |> Waiting.list()
        |> Waiting.json()
        |> JSON.decode!()

      assert Map.delete(row, "age_seconds") == Map.delete(expected, "age_seconds")
      assert is_integer(row["age_seconds"])

      assert Map.keys(row) |> Enum.sort() ==
               ~w(age_seconds branch held id kind main_checkout pane pointer repo status waits)
    end

    test "is an empty list when nothing waits", c do
      assert ask_json(c.sockets, "waiting") == %{"version" => 1, "waiting" => []}
    end
  end

  describe "show" do
    test "gives one question's whole text, found by its id and its repo's main checkout", c do
      text = "Two ways.\n\nA, or B?\n\n[worktree-status: needs-decision] which store?"
      q = question(c.main, text)

      assert %{"version" => 1, "question" => question} =
               ask_json(c.sockets, "show #{q.id} #{c.main}")

      assert question["id"] == q.id
      assert question["text"] == text
      assert question["repo"] == "myrepo"
      assert question["main_checkout"] == c.main
      assert question["branch"] == "feat-x"
      assert question["kind"] == "needs-decision"
      assert question["status"] == "open"
      assert question["pointer"] == "which store?"
      assert {:ok, _, _} = DateTime.from_iso8601(question["asked_at"])
    end

    test "takes a main checkout with spaces in it", c do
      spaced = Path.join(c.root, "my repo")
      File.mkdir_p!(Path.join(spaced, ".git"))
      File.write!(c.record, c.main <> "\n" <> spaced <> "\n")
      q = question(spaced, "A question.")

      assert %{"question" => %{"text" => "A question."}} =
               ask_json(c.sockets, "show #{q.id} #{spaced}")
    end

    test "says so for an id the house does not have", c do
      question(c.main, "A question.")

      assert ask_json(c.sockets, "show 999 #{c.main}") ==
               %{"version" => 1, "error" => "no such question"}
    end

    test "says so for a house whose database will not open", c do
      File.mkdir_p!(Path.dirname(Storage.database_path(c.main)))
      File.write!(Storage.database_path(c.main), "not a database")

      assert ask_json(c.sockets, "show 1 #{c.main}") ==
               %{"version" => 1, "error" => "unreadable house"}
    end

    test "answers only for a recorded house, and never creates one", c do
      other = Path.join(c.root, "other")
      File.mkdir_p!(Path.join(other, ".git"))

      assert ask_json(c.sockets, "show 1 #{other}") ==
               %{"version" => 1, "error" => "no such house"}

      File.write!(c.record, c.main <> "\n" <> other <> "\n")

      assert ask_json(c.sockets, "show 1 #{other}") ==
               %{"version" => 1, "error" => "no such house"}

      refute File.exists?(Storage.database_path(other))
    end
  end

  describe "line" do
    test "is the tab bar's line, and the owl that answers is watching", c do
      assert ask(c.sockets, "line") == "🦉 watching\n"
    end

    test "names the one repo with something waiting", c do
      question(c.main, "A question.")
      assert ask(c.sockets, "line") == "🦉 watching · 🐱 myrepo\n"
    end

    test "adds the jump key it is given, only when something waits", c do
      assert ask(c.sockets, "line ⌃a space") == "🦉 watching\n"

      question(c.main, "A question.")
      assert ask(c.sockets, "line ⌃a space") == "🦉 watching · 🐱 myrepo · ⌃a space\n"
    end

    test "leaves the jump key off when all that waits is held", c do
      question(c.main, "A question.", held: true)
      assert ask(c.sockets, "line ⌃a space") == "🦉 watching\n"
    end
  end

  test "anything else is an error, not silence", c do
    assert ask_json(c.sockets, "projects") == %{"version" => 1, "error" => "unknown request"}
  end

  test "both sockets are the person's alone", c do
    for name <- ["owl.sock", "hook.sock"] do
      %File.Stat{mode: mode} = File.stat!(Path.join(c.sockets, name))
      assert Bitwise.band(mode, 0o077) == 0, "#{name} is open to others"
    end
  end

  test "the doctor's probe gets its answer from a real owl", c do
    paths = %{owl: Path.join(c.sockets, "owl.sock"), hook: Path.join(c.sockets, "hook.sock")}

    assert [%Whiska.Doctor.Check{status: :ok, name: "sockets"}] =
             Whiska.Doctor.sockets([1], paths)
  end

  test "a socket file left by an owl that crashed is taken over", c do
    path = Path.join(c.sockets, "stale.sock")
    {:ok, listen} = :gen_tcp.listen(0, [:binary, ifaddr: {:local, path}])
    :ok = :gen_tcp.close(listen)
    assert File.exists?(path)

    start_supervised!(
      {Whiska.Owl.Listener, path: path, handler: Whiska.Owl.Answers, handler_opts: []}
    )

    {out, 0} = System.cmd("bash", ["-c", ~s|printf 'line\\n' \| nc -w 2 -U "$0"|, path])
    assert out =~ "🦉"
  end

  test "a second owl leaves a socket that still answers to the first", c do
    path = Path.join(c.sockets, "owl.sock")

    assert :ignore =
             Whiska.Owl.Listener.start_link(path: path, handler: Whiska.Owl.Answers)

    assert ask(c.sockets, "line") == "🦉 watching\n"
  end

  test "an owl that stops takes its sockets with it", c do
    stop_supervised!(Owl)

    refute File.exists?(Path.join(c.sockets, "owl.sock"))
    refute File.exists?(Path.join(c.sockets, "hook.sock"))
  end
end
