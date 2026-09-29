defmodule Whiska.InstallStatuslineBoardTest do
  @moduledoc """
  The statusline script as bash actually runs it (ADR-0051): it prints the
  board the owl left on disk, and starts nothing.
  """
  use ExUnit.Case, async: false

  alias Whiska.Install
  alias Whiska.Watch.Snapshot

  setup do
    root = Path.join(System.tmp_dir!(), "whiska-slb-#{System.unique_integer([:positive])}")
    home = Path.join(root, "home")
    whiska_home = Path.join(home, ".whiska")
    main = Path.join(root, "myrepo")
    script = Path.join(root, "whiska-statusline.sh")

    File.mkdir_p!(Path.join(main, "worktrees/feat-a"))
    File.mkdir_p!(home)
    File.write!(script, Install.statusline_script())
    File.chmod!(script, 0o755)

    previous = Application.get_env(:whiska, :home)
    Application.put_env(:whiska, :home, whiska_home)

    on_exit(fn ->
      Application.put_env(:whiska, :home, previous)
      File.rm_rf!(root)
    end)

    {:ok, root: root, home: home, main: main, script: script}
  end

  defp run(%{script: script, home: home}, cwd) do
    payload = JSON.encode!(%{"workspace" => %{"current_dir" => cwd}})

    {out, status} =
      System.cmd("sh", ["-c", "printf '%s' '#{payload}' | bash #{script}"],
        cd: cwd,
        env: [{"HOME", home}, {"WHISKA_HOME", Path.join(home, ".whiska")}],
        stderr_to_stdout: false
      )

    assert status == 0
    out
  end

  defp age_file(path, seconds) do
    File.touch!(path, System.os_time(:second) - seconds)
  end

  test "prints the board the owl wrote for this repo", context do
    :ok = Snapshot.write(context.main, "🐭 feat-a  working  Edit lib/auth.ex")

    assert run(context, context.main) =~ "🐭 feat-a  working  Edit lib/auth.ex"
  end

  test "starts nothing of Whiska's own" do
    script = Install.statusline_script()

    refute script =~ "escript"
    refute script =~ "statusline --here"
  end

  test "a session inside a worktree draws no board", context do
    :ok = Snapshot.write(context.main, "🐭 feat-a  working  Edit lib/auth.ex")

    assert run(context, Path.join(context.main, "worktrees/feat-a")) == ""
  end

  test "finds the board from a subdirectory of the repo", context do
    lib = Path.join(context.main, "lib")
    File.mkdir_p!(lib)
    :ok = Snapshot.write(context.main, "🐭 feat-a  working")

    assert run(context, lib) =~ "🐭 feat-a"
  end

  test "a board a few seconds behind is still drawn as it is", context do
    :ok = Snapshot.write(context.main, "🐭 feat-a  working")
    age_file(Snapshot.path(context.main), 8)

    out = run(context, context.main)

    assert out =~ "🐭 feat-a"
    refute out =~ "stale"
  end

  test "a board going stale says so, and dims what it still shows", context do
    :ok = Snapshot.write(context.main, "🐭 feat-a  working")
    age_file(Snapshot.path(context.main), 40)

    out = run(context, context.main)

    assert out =~ "🦉 owl down · 40s stale"
    assert out =~ "🐭 feat-a"
    assert out =~ "\e[2m"
  end

  test "a board nobody has touched for a minute is not shown at all", context do
    :ok = Snapshot.write(context.main, "🐭 feat-a  working")
    age_file(Snapshot.path(context.main), 300)

    assert run(context, context.main) == ""
  end

  test "a quiet repo draws nothing", context do
    :ok = Snapshot.write(context.main, "")

    assert run(context, context.main) == ""
  end

  test "a repo the owl has never opened draws nothing", context do
    assert run(context, context.main) == ""
  end

  test "the person's own global statusline still comes first", context do
    settings = Path.join(context.home, ".claude/settings.json")
    File.mkdir_p!(Path.dirname(settings))
    File.write!(settings, JSON.encode!(%{"statusLine" => %{"command" => "printf 'my line'"}}))
    :ok = Snapshot.write(context.main, "🐭 feat-a  working")

    out = run(context, context.main)

    assert [first, second] = String.split(String.trim_trailing(out), "\n")
    assert first == "my line"
    assert second =~ "🐭 feat-a"
  end

  test "is redrawn often enough to be live" do
    assert Install.statusline_refresh_interval() == 2
  end
end
