defmodule Whiska.Owl.HerdrStatusTest do
  @moduledoc """
  The script herdr's tab bar runs (ADR-0048), run the way herdr runs it, against
  an owl in this VM: it asks the owl's socket and starts nothing.
  """
  # Serial: the owl is one named process per VM.
  use ExUnit.Case, async: false

  import Mox

  alias Whiska.Herdr.Mock, as: Herdr
  alias Whiska.Install
  alias Whiska.Owl
  alias Whiska.Storage

  setup :set_mox_global
  setup {Whiska.Test.QuietSidebar, :stub_sidebar}

  setup do
    root = Path.join(System.tmp_dir!(), "whiska-tabbar-#{System.unique_integer([:positive])}")
    main = Path.join(root, "myrepo")
    File.mkdir_p!(Path.join(main, ".git"))
    record = Path.join(root, "houses")
    File.write!(record, main <> "\n")

    # The script finds the socket in the whiska home, which has to be short
    # enough for a socket's path.
    home = Path.join("/tmp", "wsk-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    script = Path.join(root, "herdr-status.sh")
    File.write!(script, Install.herdr_status_script())
    File.chmod!(script, 0o755)

    # Stands in for Whiska, and says so if anything runs it.
    whiska = Path.join(root, "fake-whiska")
    File.write!(whiska, "#!/usr/bin/env bash\ntouch #{root}/whiska-ran\n")
    File.chmod!(whiska, 0o755)

    on_exit(fn ->
      File.rm_rf!(root)
      File.rm_rf!(home)
    end)

    stub(Herdr, :list_panes, fn _ -> {:ok, []} end)
    stub(Herdr, :subscribe, fn _, _, _ -> {:ok, spawn(fn -> receive do: (:stop -> :ok) end)} end)

    {:ok, root: root, main: main, record: record, home: home, script: script, whiska: whiska}
  end

  defp start_owl(c) do
    start_supervised!(
      {Owl,
       herdr_socket: "/fake/herdr.sock",
       sockets: c.home,
       answers: [open_houses: c.record, away_path: Path.join(c.root, "away")]}
    )
  end

  defp waiting(main) do
    {:ok, handle} = Storage.open(main)

    try do
      {:ok, _} = Storage.record_mouse(%{mouse_id: "m-1", path: main, branch: "feat-x"})

      {:ok, _} =
        Storage.record_question(%{mouse_id: "m-1", text: "Which?", kind: "needs-decision"})
    after
      Storage.close(handle)
    end
  end

  defp run(c, args \\ [], path \\ nil) do
    env = [
      {"WHISKA_HOME", c.home},
      {"WHISKA_BIN", c.whiska},
      {"PATH", path || System.get_env("PATH")}
    ]

    {out, 0} = System.cmd("/bin/bash", [c.script | args], env: env)
    out
  end

  test "draws the owl's line, asked over its socket, and starts nothing", c do
    start_owl(c)
    waiting(c.main)

    assert run(c) == "🦉 watching · 🐱 myrepo"
    refute File.exists?(Path.join(c.root, "whiska-ran"))
  end

  test "adds the jump key the person passed it, when something waits", c do
    start_owl(c)
    assert run(c, ["⌃a space"]) == "🦉 watching"

    waiting(c.main)
    assert run(c, ["⌃a space"]) == "🦉 watching · 🐱 myrepo · ⌃a space"
  end

  test "an owl that does not answer is down", c do
    assert run(c) == "🦉 owl down"

    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, ifaddr: {:local, Path.join(c.home, "owl.sock")}])

    :ok = :gen_tcp.close(listen)
    assert run(c) == "🦉 owl down"
  end

  test "says so when there is no nc to ask with", c do
    start_owl(c)
    bin = Path.join(c.root, "bin")
    File.mkdir_p!(bin)

    assert run(c, [], bin) == "🦉 nc missing"
  end

  # GNU netcat: there, and with no Unix sockets in it.
  test "an nc that cannot reach a Unix socket is not mistaken for a dead owl", c do
    start_owl(c)
    bin = Path.join(c.root, "bin")
    File.mkdir_p!(bin)
    nc = Path.join(bin, "nc")

    File.write!(nc, """
    #!/bin/sh
    if [ "$1" = "-h" ]; then echo "usage: nc [-46bCDdhklnrStuvZz] [-w timeout] host port"; exit 0; fi
    echo "nc: invalid option -- 'U'" >&2
    exit 1
    """)

    File.chmod!(nc, 0o755)

    assert run(c, [], bin <> ":/usr/bin:/bin") == "🦉 nc cannot reach the owl"
  end
end
