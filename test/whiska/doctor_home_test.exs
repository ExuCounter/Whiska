defmodule Whiska.DoctorHomeTest do
  @moduledoc """
  The doctor's checks that read a home from the global `:home` / `:user_home`
  settings. Each test points one at a folder of its own, which no other test
  may see, so this file runs serially.
  """
  use ExUnit.Case, async: false

  import Mox

  alias Whiska.Doctor
  alias Whiska.Doctor.Check
  alias Whiska.Herdr.Mock, as: Herdr
  alias Whiska.Install

  setup :verify_on_exit!

  @stripped_path "/usr/bin:/bin"

  defp find(checks, name), do: Enum.find(checks, &(&1.name == name))

  defp script(tmp, name, body) do
    path = Path.join(tmp, name)
    File.write!(path, body)
    File.chmod!(path, 0o755)
    path
  end

  describe "tab_bar/2 — the herdr entry that draws the owl's line (ADR-0048)" do
    test "the tilde form of the path counts: herdr runs the entry through a login shell" do
      whiska_home = Path.join(Whiska.ServiceManager.user_home(), ".whiska")
      previous = Application.get_env(:whiska, :home)
      Application.put_env(:whiska, :home, whiska_home)
      on_exit(fn -> Application.put_env(:whiska, :home, previous) end)

      config = String.replace(Install.tab_bar_right_snippet(), whiska_home, "~/.whiska")

      assert config =~ ~s(command = "~/.whiska/herdr-status.sh")
      assert %Check{status: :ok} = Doctor.tab_bar(config, true)
    end
  end

  describe "run/2 — a repo covered by the global install, with no `.claude` of its own" do
    setup do
      previous = Application.get_env(:whiska, :user_home)

      root =
        Path.join(System.tmp_dir!(), "whiska-doctor-global-#{System.unique_integer([:positive])}")

      home = Path.join(root, "home")
      main = Path.join(root, "myrepo")
      File.mkdir_p!(Path.join(main, ".git"))
      File.mkdir_p!(Path.join(home, ".claude/hooks"))
      Application.put_env(:whiska, :user_home, home)

      File.write!(
        Path.join(home, ".claude/settings.json"),
        JSON.encode!(Install.merge(%{}, :global))
      )

      File.write!(Path.join(home, Install.shim_path()), Install.shim(:global))
      File.chmod!(Path.join(home, Install.shim_path()), 0o755)

      whiska = script(root, "whiska", "#!/bin/sh\nexit 0\n")
      escript = script(root, "escript", ~s|#!/bin/sh\nexec "$@"\n|)

      env = %{
        "WHISKA_BIN" => whiska,
        "WHISKA_ESCRIPT" => escript,
        "PATH" => @stripped_path,
        "HOME" => home,
        "HERDR_SOCKET_PATH" => Path.join(root, "herdr.sock")
      }

      stub(Herdr, :notify, fn _socket, _notification -> {:ok, :shown} end)
      stub(Herdr, :list_panes, fn _ -> {:error, :econnrefused} end)

      on_exit(fn ->
        Application.put_env(:whiska, :user_home, previous)
        File.rm_rf!(root)
      end)

      {:ok, main: main, env: env}
    end

    test "the shim is found where the global install put it", %{main: main, env: env} do
      report = Doctor.run(main, env: env, owl_pids: fn -> [] end)

      assert %Check{status: :ok} = find(report.checks, "shim")
    end

    test "the hooks are probed for real — a repo-shaped shim check skipped them", %{
      main: main,
      env: env
    } do
      report = Doctor.run(main, env: env, owl_pids: fn -> [] end)

      assert %Check{status: :ok} = find(report.checks, "hook pre-tool-use")
      assert %Check{status: :ok} = find(report.checks, "hook stop")
    end

    test "the session-start and prompt hooks are run too, and the rules must come back", %{
      main: main,
      env: env
    } do
      root = Path.dirname(main)

      whiska =
        script(root, "whiska-rules", """
        #!/bin/sh
        case "$*" in
          *"session-start --global"*) echo '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"# Whiska: rules"}}' ;;
        esac
        exit 0
        """)

      report = Doctor.run(main, env: %{env | "WHISKA_BIN" => whiska}, owl_pids: fn -> [] end)

      assert %Check{status: :ok} = find(report.checks, "hook session-start")
      assert %Check{status: :ok} = find(report.checks, "hook user-prompt-submit")

      silent = Doctor.run(main, env: env, owl_pids: fn -> [] end)

      assert %Check{status: :fail, detail: detail} = find(silent.checks, "hook session-start")
      assert detail =~ "no rules"
    end

    test "a binary that knows no hook fails every hook run — none is skipped by the shim's early exits",
         %{main: main, env: env} do
      root = Path.dirname(main)

      broken =
        script(root, "whiska-old", "#!/bin/sh\necho 'Usage: whiska <command>' >&2\nexit 1\n")

      # A doctor run from a Claude session in the main checkout inherits this.
      previous = System.get_env("CLAUDE_PROJECT_DIR")
      System.put_env("CLAUDE_PROJECT_DIR", main)

      on_exit(fn ->
        if previous,
          do: System.put_env("CLAUDE_PROJECT_DIR", previous),
          else: System.delete_env("CLAUDE_PROJECT_DIR")
      end)

      report =
        Doctor.run(main,
          env: Map.merge(env, %{"WHISKA_BIN" => broken, "HERDR_ENV" => "0"}),
          owl_pids: fn -> [] end
        )

      for hook <- ["pre-tool-use", "stop", "session-start", "user-prompt-submit"] do
        assert %Check{status: :fail} = find(report.checks, "hook #{hook}"), hook
      end
    end

    test "the global state names skill files that differ from this build, and retired ones still there" do
      home = Application.get_env(:whiska, :user_home)

      for {rel, body} <- Install.skills(:global) do
        File.mkdir_p!(Path.dirname(Path.join(home, rel)))
        File.write!(Path.join(home, rel), body)
      end

      [{stale, _} | _] = Install.skills(:global)
      File.write!(Path.join(home, stale), "an older skill\n")

      [retired | _] = Install.retired_skills()
      File.mkdir_p!(Path.dirname(Path.join(home, retired)))
      File.write!(Path.join(home, retired), "retired\n")

      state = Install.global_state()

      assert state.skills?
      assert state.stale_skills == [stale]
      assert state.retired_present == [retired]
    end

    test "a skill file the person symlinked is theirs, never called stale" do
      home = Application.get_env(:whiska, :user_home)
      [{rel, _} | _] = Install.skills(:global)
      own = Path.join(home, "their-own.md")
      File.write!(own, "the person's version\n")
      File.mkdir_p!(Path.dirname(Path.join(home, rel)))
      File.ln_s!(own, Path.join(home, rel))

      assert Install.global_state().stale_skills == []
    end

    test "a skill under a symlinked folder is the person's too, never called stale or retired" do
      home = Application.get_env(:whiska, :user_home)
      theirs = Path.join(Path.dirname(home), "dotfiles-skills")
      File.mkdir_p!(theirs)

      for {rel, _body} <- Install.skills(:global) do
        target = Path.join(theirs, Path.relative_to(rel, ".claude/skills"))
        File.mkdir_p!(Path.dirname(target))
        File.write!(target, "the person's version\n")
      end

      [retired | _] = Install.retired_skills()
      retired_target = Path.join(theirs, Path.relative_to(retired, ".claude/skills"))
      File.mkdir_p!(Path.dirname(retired_target))
      File.write!(retired_target, "kept on purpose\n")

      File.mkdir_p!(Path.join(home, ".claude"))
      File.ln_s!(theirs, Path.join(home, ".claude/skills"))

      state = Install.global_state()
      assert state.stale_skills == []
      assert state.retired_present == []
    end
  end
end
