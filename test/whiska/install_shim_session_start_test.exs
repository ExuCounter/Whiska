defmodule Whiska.InstallShimSessionStartTest do
  @moduledoc """
  The global shim's `session-start` path (ADR-next-rules-arrive-by-role): the
  command `merge/2` writes reaches `whiska hook session-start` and what it
  prints reaches Claude Code — unless the session is outside herdr, or the repo
  wires Whiska itself, when the global copy starts nothing at all.

  Runs the real shim with a stub binary standing in for Whiska, because the
  path only exists in shell.
  """
  use ExUnit.Case, async: true

  alias Whiska.Install

  @rules ~s|{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"rules"}}|

  setup do
    root = Path.join(System.tmp_dir!(), "whiska-start-shim-#{System.unique_integer([:positive])}")
    home = Path.join(root, "home")
    repo = Path.join(root, "myrepo")
    File.mkdir_p!(Path.join(home, ".claude/hooks"))
    File.mkdir_p!(Path.join(repo, ".git"))
    on_exit(fn -> File.rm_rf!(root) end)

    shim = Path.join(home, Install.shim_path())
    whiska = Path.join(root, "fake-whiska")
    escript = Path.join(root, "fake-escript")
    log = Path.join(root, "calls")

    File.write!(shim, Install.shim(:global))

    File.write!(whiska, """
    #!/usr/bin/env bash
    cat > /dev/null
    printf '%s\\n' "$@" > "#{log}"
    printf '%s' '#{@rules}'
    """)

    File.write!(escript, """
    #!/usr/bin/env bash
    exec "$@"
    """)

    for f <- [shim, whiska, escript], do: File.chmod!(f, 0o755)

    {:ok, root: root, home: home, repo: repo, whiska: whiska, escript: escript, log: log}
  end

  # The command exactly as settings.json carries it, run the way Claude Code
  # runs a hook: through a shell, with HOME and CLAUDE_PROJECT_DIR set.
  defp start(c, herdr_env) do
    command = Install.merge(%{}, :global)["hooks"]["SessionStart"] |> hd()
    [%{"command" => command}] = command["hooks"]
    File.rm(c.log)

    {out, status} =
      System.cmd("bash", ["-c", command <> ~s| <<< '{"cwd":"#{c.repo}"}'|],
        env: [
          {"HOME", c.home},
          {"CLAUDE_PROJECT_DIR", c.repo},
          {"HERDR_ENV", herdr_env},
          {"WHISKA_BIN", c.whiska},
          {"WHISKA_ESCRIPT", c.escript}
        ],
        stderr_to_stdout: true
      )

    %{out: out, status: status, args: read_args(c.log)}
  end

  defp read_args(log) do
    case File.read(log) do
      {:ok, args} -> String.split(args, "\n", trim: true)
      {:error, _} -> nil
    end
  end

  test "in a main checkout, the hook runs, told it is the global copy, and what it prints passes through",
       c do
    assert %{out: @rules, status: 0, args: ["hook", "session-start", "--global"]} = start(c, "1")
  end

  test "the committed per-repo shim starts nothing outside herdr either", c do
    shim = Path.join(c.repo, Install.shim_path())
    File.mkdir_p!(Path.dirname(shim))
    File.write!(shim, Install.shim())
    File.rm(c.log)

    {out, 0} =
      System.cmd("bash", [shim, "session-start"],
        env: [
          {"CLAUDE_PROJECT_DIR", c.repo},
          {"HERDR_ENV", nil},
          {"WHISKA_BIN", c.whiska},
          {"WHISKA_ESCRIPT", c.escript}
        ]
      )

    assert out == ""
    assert read_args(c.log) == nil
  end

  test "outside herdr the global copy starts nothing and prints nothing", c do
    assert %{out: "", status: 0, args: nil} = start(c, nil)
  end

  test "in a repo that wires its own shim, the global copy stands down", c do
    File.mkdir_p!(Path.join(c.repo, ".claude/hooks"))
    File.write!(Path.join(c.repo, Install.shim_path()), "#!/usr/bin/env bash\n")

    File.write!(
      Path.join(c.repo, ".claude/settings.json"),
      JSON.encode!(Install.merge(%{}))
    )

    assert %{out: "", status: 0, args: nil} = start(c, "1")
  end
end
