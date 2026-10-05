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
  end
end
