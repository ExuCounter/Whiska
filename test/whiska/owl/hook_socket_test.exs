defmodule Whiska.Owl.HookSocketTest do
  @moduledoc """
  The hook socket, as its one client uses it: the real shim, run by bash, against
  an owl running in this VM (ADR-0033, ADR-0036).

  The shim's fallback is a stub standing in for Whiska, so a test can tell an
  answer the owl gave from one the escript would have given: the stub is called
  only when the owl did not answer.
  """
  # Serial: the owl is one named process per VM, and these tests set
  # HERDR_PANE_ID in the VM's own environment on purpose.
  use ExUnit.Case, async: false

  import Mox

  alias Whiska.AnswerFlag
  alias Whiska.Doorstep
  alias Whiska.Doorstep.Entry
  alias Whiska.Herdr.Mock, as: Herdr
  alias Whiska.Install
  alias Whiska.Marker
  alias Whiska.Owl
  alias Whiska.Storage

  setup :set_mox_global
  setup {Whiska.Test.QuietSidebar, :stub_sidebar}

  setup do
    root = Path.join(System.tmp_dir!(), "whiska-hooksock-#{System.unique_integer([:positive])}")
    main = Path.join(root, "myrepo")
    worktree = Path.join(main, "worktrees/feat-thing")
    File.mkdir_p!(Path.join(main, ".git/worktrees/feat-thing"))
    File.mkdir_p!(Path.join(worktree, "lib"))
    File.write!(Path.join(worktree, ".git"), "gitdir: #{main}/.git/worktrees/feat-thing\n")

    # macOS caps a socket's path at 104 bytes, and the temp dir alone can eat
    # half of that.
    sockets = Path.join("/tmp", "wsk-#{System.unique_integer([:positive])}")
    File.mkdir_p!(sockets)

    was = System.get_env("HERDR_PANE_ID")

    on_exit(fn ->
      File.rm_rf!(root)
      File.rm_rf!(sockets)
      if was, do: System.put_env("HERDR_PANE_ID", was), else: System.delete_env("HERDR_PANE_ID")
    end)

    stub(Herdr, :list_panes, fn _ -> {:ok, []} end)
    stub(Herdr, :subscribe, fn _, _, _ -> {:ok, spawn(fn -> receive do: (:stop -> :ok) end)} end)

    {:ok, root: root, main: main, worktree: worktree, sockets: sockets}
  end

  defp start_owl(sockets) do
    start_supervised!({Owl, herdr_socket: "/fake/herdr.sock", sockets: sockets})
  end

  defp sniff_mouse(main, worktree) do
    {:ok, mouse_id} = Marker.read_or_mint(worktree)
    {:ok, handle} = Storage.open(main)
    Storage.record_mouse(%{mouse_id: mouse_id, path: worktree, branch: "feat-thing"})
    {:ok, _} = Storage.shape(mouse_id, "sniff", nil, nil)
    Storage.close(handle)
    mouse_id
  end

  defp main_pane(main, pane) do
    {:ok, handle} = Storage.open(main)
    :ok = Storage.set_main_pane(pane)
    Storage.close(handle)
  end

  describe "the owl decides with the hook's environment, never its own" do
    # An owl started by hand in the main session's pane inherits that pane's
    # id. Read from the owl's own environment, every mouse would look like the
    # main session: every edit allowed, every question dropped.
    setup %{main: main, worktree: worktree, sockets: sockets} do
      sniff_mouse(main, worktree)
      main_pane(main, "w1:p2")
      System.put_env("HERDR_PANE_ID", "w1:p2")
      start_owl(sockets)
      :ok
    end

    test "a sniff mouse's write is denied", %{root: root, worktree: worktree, sockets: sockets} do
      result =
        shim(root, sockets, "pre-tool-use", worktree, %{
          "cwd" => worktree,
          "hook_event_name" => "PreToolUse",
          "tool_name" => "Write",
          "tool_input" => %{"file_path" => Path.join(worktree, "lib/a.ex"), "content" => "x"}
        })

      assert result.called == [], "the escript ran: #{inspect(result)}"

      assert %{"hookSpecificOutput" => %{"permissionDecision" => "deny"}} =
               JSON.decode!(result.out)
    end

    test "a finished turn is left on the doorstep", %{
      root: root,
      main: main,
      worktree: worktree,
      sockets: sockets
    } do
      result =
        shim(root, sockets, "stop", worktree, %{
          "cwd" => worktree,
          "hook_event_name" => "Stop",
          "last_assistant_message" => "All done.\n\n[worktree-status: done]"
        })

      assert result.called == [], "the escript ran: #{inspect(result)}"
      assert [{_, %Entry{text: "All done.\n\n[worktree-status: done]"}}] = Doorstep.waiting(main)
    end
  end

  describe "two repos at once" do
    test "a hook for one house is not thrown off by another house open in the owl's VM", %{
      root: root,
      main: main,
      worktree: worktree,
      sockets: sockets
    } do
      sniff_mouse(main, worktree)
      start_owl(sockets)

      other = Path.join(root, "other")
      File.mkdir_p!(Path.join(other, ".git"))
      {:ok, handle} = Storage.open(other)

      try do
        result =
          shim(root, sockets, "pre-tool-use", worktree, %{
            "cwd" => worktree,
            "tool_name" => "Write",
            "tool_input" => %{"file_path" => Path.join(worktree, "lib/a.ex"), "content" => "x"}
          })

        assert result.called == []

        assert %{"hookSpecificOutput" => %{"permissionDecision" => "deny"}} =
                 JSON.decode!(result.out)
      after
        Storage.close(handle)
      end
    end
  end

  describe "when the owl does not answer, the escript does" do
    setup %{main: main, worktree: worktree} do
      sniff_mouse(main, worktree)
      :ok
    end

    @write %{"tool_name" => "Write", "tool_input" => %{"file_path" => "x", "content" => "y"}}

    test "a socket file nobody listens on", %{root: root, sockets: sockets, worktree: worktree} do
      path = Path.join(sockets, "hook.sock")
      {:ok, listen} = :gen_tcp.listen(0, [:binary, ifaddr: {:local, path}])
      :ok = :gen_tcp.close(listen)
      assert File.exists?(path)

      payload = Map.put(@write, "cwd", worktree)
      result = shim(root, sockets, "pre-tool-use", worktree, payload)

      assert [%{args: ["hook", "pre-tool-use"], stdin: stdin}] = result.called
      assert JSON.decode!(stdin) == payload
    end

    test "an owl that takes the call and never answers costs about two seconds", %{
      root: root,
      sockets: sockets,
      worktree: worktree
    } do
      path = Path.join(sockets, "hook.sock")
      {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, ifaddr: {:local, path}])
      hung = spawn(fn -> hang(listen) end)

      {micros, result} =
        :timer.tc(fn ->
          shim(root, sockets, "stop", worktree, %{
            "cwd" => worktree,
            "last_assistant_message" => "x"
          })
        end)

      Process.exit(hung, :kill)
      :gen_tcp.close(listen)

      assert [%{args: ["hook", "stop"]}] = result.called
      assert micros < 4_000_000
    end
  end

  describe "a house the owl cannot reach is left to the escript" do
    setup %{main: main, worktree: worktree, sockets: sockets} do
      sniff_mouse(main, worktree)
      start_owl(sockets)
      :ok
    end

    test "a tool call in a house whose database will not open", c do
      # A folder where the database should be, and no write-ahead log beside
      # it for SQLite to read the old rows back out of.
      db = Storage.database_path(c.main)
      for f <- [db, db <> "-wal", db <> "-shm"], do: File.rm_rf!(f)
      File.mkdir_p!(db)

      payload = %{
        "cwd" => c.worktree,
        "tool_name" => "Write",
        "tool_input" => %{"file_path" => Path.join(c.worktree, "lib/a.ex"), "content" => "x"}
      }

      result = shim(c.root, c.sockets, "pre-tool-use", c.worktree, payload)
      assert [%{args: ["hook", "pre-tool-use"]}] = result.called
    end

    test "a finished turn the owl could not write down", c do
      doorstep = Doorstep.path(c.main)
      File.rm_rf!(doorstep)
      File.mkdir_p!(Path.dirname(doorstep))
      File.write!(doorstep, "a file where the doorstep should be")

      payload = %{"cwd" => c.worktree, "last_assistant_message" => "done"}
      result = shim(c.root, c.sockets, "stop", c.worktree, payload)

      assert [%{args: ["hook", "stop"]}] = result.called
    end
  end

  describe "a finished turn in an open house" do
    test "is collected the moment the owl leaves it", c do
      sniff_mouse(c.main, c.worktree)
      start_owl(c.sockets)
      {:ok, _house} = Owl.open_house(c.main)
      on_exit(fn -> Whiska.OpenHouses.remove(c.main) end)

      payload = %{"cwd" => c.worktree, "last_assistant_message" => "Which store?"}
      result = shim(c.root, c.sockets, "stop", c.worktree, payload)
      assert result.called == []

      assert eventually(fn -> Doorstep.waiting(c.main) == [] end)
      assert eventually(fn -> recorded?(c.main, "Which store?") end)
    end
  end

  defp recorded?(main, text) do
    Storage.within(main, fn -> Enum.any?(Storage.questions(), &(&1.text == text)) end)
  end

  describe "an answer handed over through the owl" do
    setup %{main: main, worktree: worktree, sockets: sockets} do
      mouse_id = sniff_mouse(main, worktree)

      {:ok, handle} = Storage.open(main)

      {:ok, q} =
        Storage.record_question(%{mouse_id: mouse_id, text: "Which?", kind: "needs-decision"})

      {:ok, _} = Storage.answer(q.id, "SQLite.")
      Storage.close(handle)
      :ok = AnswerFlag.set(worktree)

      start_owl(sockets)
      {:ok, id: q.id}
    end

    test "reaches the session and is stamped taken", %{
      root: root,
      main: main,
      worktree: worktree,
      sockets: sockets,
      id: id
    } do
      result =
        shim(root, sockets, "user-prompt-submit", worktree, %{"cwd" => worktree, "prompt" => "go"})

      assert result.called == []

      assert %{"hookSpecificOutput" => %{"additionalContext" => context}} =
               JSON.decode!(result.out)

      assert context =~ "SQLite."
      assert eventually(fn -> taken_at(main, id) end)
      assert eventually(fn -> not AnswerFlag.set?(worktree) end)
    end

    test "the same request, read to the end, is stamped taken", c do
      socket = raw_prompt(c.sockets, c.worktree)
      assert {:ok, "ok 0\n" <> _} = :gen_tcp.recv(socket, 0, 2_000)
      :gen_tcp.close(socket)

      assert eventually(fn -> taken_at(c.main, c.id) end)
    end

    test "is not stamped taken when the answer could not be sent", c do
      socket = raw_prompt(c.sockets, c.worktree)
      :ok = :gen_tcp.close(socket)

      # Long enough for the owl to have read the request and tried to answer:
      # the test beside this one shows the same bytes are stamped within it.
      Process.sleep(500)

      refute taken_at(c.main, c.id)
      assert AnswerFlag.set?(c.worktree)
    end
  end

  # The bytes the shim sends for a prompt in this worktree, sent by hand so the
  # test can hang up before the answer.
  defp raw_prompt(sockets, worktree) do
    payload = JSON.encode!(%{"cwd" => worktree, "prompt" => "go"})

    {:ok, socket} =
      :gen_tcp.connect({:local, Path.join(sockets, "hook.sock")}, 0, [:binary, active: false])

    :ok =
      :gen_tcp.send(socket, [
        "hook 1 user-prompt-submit #{byte_size(payload)}\n",
        "HERDR_PANE_ID=w9:p9\nHOME=#{System.user_home!()}\n\n",
        payload
      ])

    socket
  end

  defp eventually(check, tries \\ 40) do
    cond do
      value = check.() -> value
      tries == 0 -> nil
      true -> Process.sleep(50) && eventually(check, tries - 1)
    end
  end

  defp taken_at(main, id) do
    {:ok, handle} = Storage.open(main)

    try do
      Storage.question(id).taken_at
    after
      Storage.close(handle)
    end
  end

  describe "the rules a session starts with, through the owl" do
    setup %{main: main, worktree: worktree, sockets: sockets} do
      sniff_mouse(main, worktree)
      start_owl(sockets)
      :ok
    end

    test "a mouse gets a mouse's rules from the repo's own shim", c do
      result = shim(c.root, c.sockets, "session-start", c.worktree, %{"cwd" => c.worktree})

      assert result.called == []
      assert rules(result.out) =~ "# Whiska: rules for a mouse"
    end

    # A part the repo's CLAUDE.md holds back is left out by the repo's own
    # install and not by the global one (ADR-0081): only a scope that reached
    # the owl intact tells the two apart.
    test "the global copy's scope reaches the owl", c do
      File.write!(Path.join(c.worktree, "CLAUDE.md"), """
      <!-- whiska:finish:start keep -->
      <!-- whiska:finish:end -->
      """)

      payload = %{"cwd" => c.worktree}
      repo = shim(c.root, c.sockets, "session-start", c.worktree, payload)
      global = shim(c.root, c.sockets, "session-start --global", c.worktree, payload, :global)

      assert repo.called == [] and global.called == []
      refute rules(repo.out) =~ "## Before a turn is done"
      assert rules(global.out) =~ "## Before a turn is done"
    end
  end

  defp rules(out) do
    assert %{"hookSpecificOutput" => %{"additionalContext" => rules}} = JSON.decode!(out)
    rules
  end

  defp home(root) do
    home = Path.join(root, "home")
    File.mkdir_p!(Path.join(home, ".claude"))
    home
  end

  # Accepts and reads, and never answers.
  defp hang(listen) do
    {:ok, socket} = :gen_tcp.accept(listen)
    _ = :gen_tcp.recv(socket, 0)
    Process.sleep(:infinity)
  end

  # Runs the real shim with a stub Whiska behind it. The stub records being
  # called, so `called` is empty exactly when the owl answered.
  defp shim(root, sockets, hook, worktree, payload, scope \\ :repo) do
    n = System.unique_integer([:positive])
    dir = Path.join(root, "shim-#{n}")
    File.mkdir_p!(dir)
    shim = Path.join(dir, "whiska.sh")
    whiska = Path.join(dir, "fake-whiska")
    escript = Path.join(dir, "fake-escript")
    log = Path.join(dir, "calls")
    payload_file = Path.join(dir, "payload.json")
    err_file = Path.join(dir, "err.txt")

    File.write!(shim, Install.shim(scope))

    File.write!(whiska, """
    #!/usr/bin/env bash
    cat > "#{log}.stdin"
    printf '%s\\n' "$@" > "#{log}"
    """)

    File.write!(escript, """
    #!/usr/bin/env bash
    exec "$@"
    """)

    for f <- [shim, whiska, escript], do: File.chmod!(f, 0o755)
    File.write!(payload_file, JSON.encode!(payload))

    env = [
      {"WHISKA_BIN", whiska},
      {"WHISKA_ESCRIPT", escript},
      {"WHISKA_HOOK_SOCKET", Path.join(sockets, "hook.sock")},
      {"CLAUDE_PROJECT_DIR", worktree},
      {"HERDR_ENV", "1"},
      {"HERDR_PANE_ID", "w9:p9"},
      {"HOME", home(root)}
    ]

    # The oldest bash the shim must run under: macOS ships 3.2 as /bin/bash,
    # and a hook's PATH may find nothing newer.
    {out, status} =
      System.cmd(
        "/bin/bash",
        ["-c", ~s|/bin/bash "#{shim}" #{hook} < "#{payload_file}" 2> "#{err_file}"|],
        env: env
      )

    called =
      case File.read(log) do
        {:ok, args} ->
          [%{args: String.split(args, "\n", trim: true), stdin: File.read!(log <> ".stdin")}]

        {:error, _} ->
          []
      end

    %{out: String.trim(out), err: File.read!(err_file), status: status, called: called}
  end
end
