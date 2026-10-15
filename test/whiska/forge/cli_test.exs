defmodule Whiska.Forge.CLITest do
  @moduledoc """
  The one runner a forge's tool reads through: what it may be asked to run,
  and how it reads what comes back, against a fake `glab` on disk.
  """
  use ExUnit.Case, async: true

  alias Whiska.Forge.CLI
  alias Whiska.Test.FakeGlab

  setup do
    root = Path.join(System.tmp_dir!(), "whiska-forge-cli-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    fake = FakeGlab.create(root)
    {:ok, fake: fake, run: %{tool: fake.bin, cwd: root, timeout_ms: 60_000}}
  end

  # Both CLIs switch to POST as soon as a field flag is added, and take a
  # method of their own from `-X`: the read stays a read only because nothing
  # but the path is ever the caller's, and no path can pass for a flag.
  test "every read is a GET that no path can turn into a write" do
    paths = [
      "user",
      "projects/a%2Fb/merge_requests/7/discussions?per_page=100&page=2",
      "-f",
      "--method",
      "user -X POST",
      "user\n-F x=y",
      "--input=/etc/passwd",
      "user\t-XPOST",
      "",
      "../user",
      "user?x=1 -f a=b"
    ]

    for path <- paths do
      case CLI.argv("gitlab.com", path) do
        {:ok, args} ->
          assert args == ["api", "--method", "GET", "--include", "--hostname", "gitlab.com", path]
          refute String.starts_with?(path, "-")
          refute path =~ ~r/\s/
          refute path =~ ".."

        {:error, :unsafe_path} ->
          :ok
      end
    end

    assert {:ok, _} = CLI.argv("gitlab.com", "user")
    assert {:error, :unsafe_path} = CLI.argv("gitlab.com", "-f")
  end

  test "a host that could be read as anything but a host is refused" do
    assert {:ok, _} = CLI.argv("gitlab.example.com:8443", "user")

    for host <- ["", "-x", "gitlab.com user", "gitlab.com/x", "--hostname"],
        do: assert({:error, :unsafe_host} = CLI.argv(host, "user"))
  end

  test "a 2xx is its body, decoded, with its headers", %{fake: fake, run: run} do
    FakeGlab.answer(fake, "user", %{"id" => 1, "username" => "me"},
      headers: %{"X-Next-Page" => "2"}
    )

    assert {:ok, %{"id" => 1, "username" => "me"}, headers} = CLI.get(run, "gitlab.com", "user")
    assert headers["x-next-page"] == "2"

    assert [["api", "--method", "GET", "--include", "--hostname", "gitlab.com", "user"]] =
             FakeGlab.calls(fake)
  end

  test "a 404 is missing, never unknown", %{run: run} do
    assert :missing = CLI.get(run, "gitlab.com", "projects/a%2Fb/merge_requests/9")
  end

  test "a refusal, a rate limit and a server error are unknown, with the retry time the forge gave",
       %{fake: fake, run: run} do
    FakeGlab.answer(fake, "user", %{"message" => "401 Unauthorized"}, status: 401)
    assert {:unknown, {:http, 401}, nil} = CLI.get(run, "gitlab.com", "user")

    FakeGlab.answer(fake, "user", %{"message" => "slow down"},
      status: 429,
      headers: %{"Retry-After" => "30"}
    )

    assert {:unknown, {:http, 429}, 30_000} = CLI.get(run, "gitlab.com", "user")

    FakeGlab.answer(fake, "user", "<html>bad gateway</html>", status: 502)
    assert {:unknown, {:http, 502}, nil} = CLI.get(run, "gitlab.com", "user")
  end

  test "a body that is not JSON is unknown", %{fake: fake, run: run} do
    FakeGlab.answer(fake, "user", "not json")
    assert {:unknown, :unreadable_body, nil} = CLI.get(run, "gitlab.com", "user")
  end

  test "a tool that hangs past its deadline is killed and unknown", %{fake: fake, run: run} do
    FakeGlab.answer(fake, "user", %{"id" => 1}, sleep: 5)
    started = System.monotonic_time(:millisecond)

    assert {:unknown, :timeout, nil} = CLI.get(%{run | timeout_ms: 300}, "gitlab.com", "user")
    assert System.monotonic_time(:millisecond) - started < 3_000
  end

  test "no tool is unknown, and nothing runs", %{run: run} do
    assert {:unknown, :no_tool, nil} = CLI.get(%{run | tool: nil}, "gitlab.com", "user")

    assert {:unknown, :no_tool, nil} =
             CLI.get(%{run | tool: "/nowhere/glab"}, "gitlab.com", "user")
  end

  test "a tool named by a relative path is no tool, wherever it is run from",
       %{fake: fake, run: run} do
    relative = Path.relative_to(fake.bin, File.cwd!(), force: true)

    assert {:unknown, :no_tool, nil} = CLI.get(%{run | tool: relative}, "gitlab.com", "user")
    assert FakeGlab.calls(fake) == []
  end

  test "the person's PATH comes before the places a package manager puts a tool", %{run: run} do
    tool = Path.join(run.cwd, "echo-path")

    File.write!(tool, """
    #!/bin/sh
    printf 'HTTP/2.0 200 OK\r\nContent-Type: application/json\r\n\r\n"%s"' "$PATH"
    """)

    File.chmod!(tool, 0o755)

    assert {:ok, path, _headers} = CLI.get(%{run | tool: tool}, "gitlab.com", "user")
    assert [dir, first | _] = String.split(path, ":")
    assert dir == run.cwd
    assert first == "PATH" |> System.get_env() |> String.split(":") |> hd()
  end

  test "a reply too long to be one is unknown", %{run: run} do
    tool = Path.join(run.cwd, "endless")

    File.write!(tool, """
    #!/bin/sh
    printf 'HTTP/2.0 200 OK\r\nContent-Type: application/json\r\n\r\n'
    exec head -c 20000000 /dev/zero
    """)

    File.chmod!(tool, 0o755)

    assert {:unknown, :too_long, nil} = CLI.get(%{run | tool: tool}, "gitlab.com", "user")
  end

  test "an unsafe path never reaches the tool", %{fake: fake, run: run} do
    assert {:unknown, :unsafe_path, nil} = CLI.get(run, "gitlab.com", "-X POST")
    assert FakeGlab.calls(fake) == []
  end

  test "a tool on the PATH is found, and one missing is nil" do
    assert CLI.find("sh") == System.find_executable("sh")
    assert CLI.find("no-such-forge-tool-#{System.unique_integer([:positive])}") == nil
  end
end
