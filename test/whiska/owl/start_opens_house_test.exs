defmodule Whiska.Owl.StartOpensHouseTest do
  @moduledoc """
  `whiska start` opens its house in the owl already running, over the hook
  socket's `open` request (ADR-0033), and writes the open-houses record itself
  when no owl answers (ADR-0039).
  """
  # Serial: the owl is one named process per VM, and these tests set
  # HERDR_* and WHISKA_HOOK_SOCKET in the VM's own environment.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import Mox

  alias Whiska.CLI
  alias Whiska.Herdr.Mock, as: Herdr
  alias Whiska.OpenHouses
  alias Whiska.Owl
  alias Whiska.Storage

  setup :set_mox_global
  setup {Whiska.Test.QuietSidebar, :stub_sidebar}

  @herdr "/fake/herdr.sock"

  setup do
    root = Path.join(System.tmp_dir!(), "whiska-sopen-#{Whiska.Test.Unique.id()}")
    main = Path.join(root, "myrepo")
    File.mkdir_p!(Path.join(main, ".git"))

    # macOS caps a socket's path at 104 bytes, and the temp dir alone can eat
    # half of that.
    sockets = Path.join("/tmp", "wso-#{System.unique_integer([:positive])}")
    File.mkdir_p!(sockets)

    vars = ~w(HERDR_PANE_ID HERDR_SOCKET_PATH WHISKA_HOOK_SOCKET)
    was = Map.new(vars, &{&1, System.get_env(&1)})
    System.put_env("HERDR_PANE_ID", "w1:p2")
    System.put_env("HERDR_SOCKET_PATH", @herdr)
    System.put_env("WHISKA_HOOK_SOCKET", Path.join(sockets, "hook.sock"))

    on_exit(fn ->
      File.rm_rf!(root)
      File.rm_rf!(sockets)
      OpenHouses.remove(main)

      Enum.each(was, fn
        {var, nil} -> System.delete_env(var)
        {var, value} -> System.put_env(var, value)
      end)
    end)

    stub(Herdr, :list_panes, fn _ -> {:ok, []} end)
    stub(Herdr, :subscribe, fn _, _, _ -> {:ok, spawn(fn -> receive do: (:stop -> :ok) end)} end)

    # The pane is already running the main session's Claude, so `whiska start`
    # records and starts nothing (ADR-0066).
    stub(Herdr, :pane, fn @herdr, pane ->
      {:ok, %{pane_id: pane, cwd: main, agent: "claude", agent_status: "idle"}}
    end)

    stub(Herdr, :processes, fn @herdr, _pane ->
      brief = Path.join(main, ".git/whiska/main.md")
      {:ok, [%{name: "claude", argv: ["claude" | Whiska.Brief.claude_args(brief)]}]}
    end)

    {:ok, main: main, sockets: sockets}
  end

  defp start_owl(sockets) do
    start_supervised!({Owl, herdr_socket: @herdr, sockets: sockets})
  end

  defp run(argv, cwd) do
    {{status, stdout}, stderr} =
      with_io(:stderr, fn ->
        with_io(fn -> CLI.run(argv, cwd) end)
      end)

    {status, stdout, stderr}
  end

  describe "whiska start with an owl running" do
    test "opens this repo in the owl already running", %{main: main, sockets: sockets} do
      start_owl(sockets)

      {0, out, _} = run(["start", "--no-claude"], main)

      assert {:ok, _} = Owl.house(main)
      assert main in OpenHouses.read()
      assert out =~ "delivered here"
    end

    test "a repo already open stays open, and is said to be delivered to", c do
      start_owl(c.sockets)
      {:ok, _} = Owl.open_house(c.main)

      {0, out, _} = run(["start", "--no-claude"], c.main)

      assert {:ok, _} = Owl.house(c.main)
      assert out =~ "delivered here"
    end
  end

  describe "whiska start with no owl answering" do
    test "no socket: the record is written and the owl is said to be down", %{main: main} do
      {0, out, err} = run(["start", "--no-claude"], main)

      assert main in OpenHouses.read()
      assert err =~ "owl is not running"
      refute out =~ "delivered here"
    end

    test "an owl that hangs up on `open`: the record is written and a restart named", c do
      path = Path.join(c.sockets, "hook.sock")

      {:ok, listen} =
        :gen_tcp.listen(0, [:binary, packet: :line, active: false, ifaddr: {:local, path}])

      spawn_link(fn ->
        {:ok, socket} = :gen_tcp.accept(listen)
        {:ok, _line} = :gen_tcp.recv(socket, 0, 2_000)
        :gen_tcp.close(socket)
      end)

      {0, out, err} = run(["start", "--no-claude"], c.main)

      assert c.main in OpenHouses.read()
      assert err =~ "whiska owl stop && whiska owl start"
      refute out =~ "delivered here"
    end
  end

  describe "whiska start with a socket path it cannot use" do
    test "an empty WHISKA_HOOK_SOCKET is unset, as the shim reads it", %{main: main} do
      System.put_env("WHISKA_HOOK_SOCKET", "")

      {0, _out, err} = run(["start", "--no-claude"], main)

      assert main in OpenHouses.read()
      assert err =~ "owl is not running"
    end

    test "a path too long for a socket is no owl, and start still succeeds", %{main: main} do
      System.put_env("WHISKA_HOOK_SOCKET", "/tmp/" <> String.duplicate("x", 200))

      {0, _out, err} = run(["start", "--no-claude"], main)

      assert err =~ "owl is not running"
    end
  end

  describe "an owl that takes `open` and does not answer in time" do
    test "is told apart from an owl too old to know it", %{sockets: sockets} do
      path = Path.join(sockets, "hook.sock")

      {:ok, listen} =
        :gen_tcp.listen(0, [:binary, packet: :line, active: false, ifaddr: {:local, path}])

      spawn_link(fn ->
        {:ok, socket} = :gen_tcp.accept(listen)
        {:ok, _line} = :gen_tcp.recv(socket, 0, 2_000)
        Process.sleep(1_000)
      end)

      assert {:error, :no_answer} = Owl.ask_open("/somewhere", path, 100)
    end
  end

  describe "the open request" do
    setup %{sockets: sockets} do
      start_owl(sockets)
      :ok
    end

    test "refuses a path that is not absolute", %{sockets: sockets} do
      assert {:error, {:refused, _}} =
               Owl.ask_open("myrepo", Path.join(sockets, "hook.sock"))
    end

    test "refuses a checkout with no house on disk, and creates none", c do
      assert {:error, {:refused, _}} = Owl.ask_open(c.main, Path.join(c.sockets, "hook.sock"))
      refute File.exists?(Storage.database_path(c.main))
      assert {:error, :shut} = Owl.house(c.main)
    end

    test "opens a path holding spaces", c do
      spaced = Path.join(Path.dirname(c.main), "my repo")
      File.mkdir_p!(Path.join(spaced, ".git"))
      {:ok, handle} = Storage.open(spaced, name: :seed)
      Storage.close(handle)
      on_exit(fn -> OpenHouses.remove(spaced) end)

      assert :ok = Owl.ask_open(spaced, Path.join(c.sockets, "hook.sock"))
      assert {:ok, _} = Owl.house(spaced)
    end
  end
end
