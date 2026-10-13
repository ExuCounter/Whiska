defmodule Whiska.InstallStatuslineTest do
  @moduledoc """
  What `whiska init` writes for questions: herdr's tab bar script and its config
  entry (ADR-0048) — and the Claude Code statusline it takes out of an older
  install (ADR-0082).
  """
  # Serial: each test points the global `:home` at a folder of its own.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Whiska.CLI
  alias Whiska.Install

  setup do
    root = Path.join(System.tmp_dir!(), "whiska-inst-#{System.unique_integer([:positive])}")
    main = Path.join(root, "myrepo")
    home = Path.join(root, "dot-whiska")
    File.mkdir_p!(Path.join(main, ".git"))
    previous = Application.get_env(:whiska, :home)
    Application.put_env(:whiska, :home, home)

    on_exit(fn ->
      Application.put_env(:whiska, :home, previous)
      File.rm_rf!(root)
    end)

    {:ok, main: main, home: home}
  end

  describe "merge — the retired Claude Code statusline" do
    @ours_repo ~s|bash "${CLAUDE_PROJECT_DIR:-.}/.claude/hooks/whiska-statusline.sh"|
    @ours_global ~s|bash "$HOME/.claude/hooks/whiska-statusline.sh"|

    test "writes no statusLine" do
      refute Map.has_key?(Install.merge(%{}), "statusLine")
      refute Map.has_key?(Install.merge(%{}, :global), "statusLine")
    end

    test "takes out one an older init wrote, interval and all" do
      old = %{"type" => "command", "command" => @ours_repo, "refreshInterval" => 1}

      refute Map.has_key?(Install.merge(%{"statusLine" => old}), "statusLine")
    end

    test "puts the person's own line back where the global install displaced it" do
      old = %{"type" => "command", "command" => @ours_global, "refreshInterval" => 1}

      assert Install.merge(%{"statusLine" => old}, :global, "bash ~/my-line.sh")["statusLine"] ==
               %{"type" => "command", "command" => "bash ~/my-line.sh"}
    end

    test "leaves a statusLine that is not ours exactly alone" do
      mine = %{"type" => "command", "command" => "bash mine.sh", "refreshInterval" => 5}

      assert Install.merge(%{"statusLine" => mine})["statusLine"] == mine
      assert Install.merge(%{"statusLine" => mine}, :global, "bash old.sh")["statusLine"] == mine
    end

    test "a statusLine of a shape we do not recognise is left alone too" do
      for theirs <- ["bash mine.sh", %{"type" => "command"}, %{"command" => nil}] do
        assert Install.merge(%{"statusLine" => theirs})["statusLine"] == theirs
      end
    end
  end

  describe "retired_statusline/1 — what an older init left behind" do
    test "names the settings entry, the script and the kept line, where they are", %{main: main} do
      File.mkdir_p!(Path.join(main, ".claude/hooks"))
      File.write!(Path.join(main, ".claude/hooks/whiska-statusline.sh"), "#!/usr/bin/env bash\n")
      File.write!(Path.join(main, ".claude/whiska-base-statusline"), "bash ~/my-line.sh")

      File.write!(
        Path.join(main, ".claude/settings.json"),
        JSON.encode!(%{"statusLine" => %{"type" => "command", "command" => @ours_repo}})
      )

      assert Install.retired_statusline(main) == [
               ".claude/settings.json statusLine",
               ".claude/hooks/whiska-statusline.sh",
               ".claude/whiska-base-statusline"
             ]
    end

    test "is nothing where none of it is", %{main: main} do
      File.mkdir_p!(Path.join(main, ".claude"))

      File.write!(
        Path.join(main, ".claude/settings.json"),
        JSON.encode!(%{"statusLine" => %{"type" => "command", "command" => "bash mine.sh"}})
      )

      assert Install.retired_statusline(main) == []
    end
  end

  # What the script prints is driven for real in Whiska.Owl.HerdrStatusTest.
  describe "herdr_status_script/0 — what herdr's tab bar runs (ADR-0048)" do
    test "lives in the whiska home, not in any repo" do
      assert Install.herdr_status_path() == Path.join(Whiska.OpenHouses.home(), "herdr-status.sh")
    end
  end

  describe "tab_bar_right_snippet/0 — what the person commits in dotfiles" do
    test "is the herdr config entry that draws the line, naming the shipped script" do
      snippet = Install.tab_bar_right_snippet()

      assert snippet =~ "[ui]"
      assert snippet =~ "tab_bar_right"
      assert snippet =~ ~s(type = "command")
      assert snippet =~ ~s(command = "#{Install.herdr_status_path()} '⌃a space'")
      assert snippet =~ "interval_seconds = #{Install.herdr_status_interval()}"
      assert snippet =~ "timeout_seconds = #{Install.herdr_status_timeout()}"
    end

    test "an interval and timeout herdr accepts" do
      assert Install.herdr_status_interval() in 1..31_536_000
      assert Install.herdr_status_timeout() in 1..3_600
    end
  end

  describe "whiska owl install writes the script" do
    test "executable, in the whiska home", %{home: home} do
      script = Install.herdr_status_path()
      assert String.starts_with?(script, home)

      assert :ok = Install.write_herdr_status()
      assert File.read!(script) == Install.herdr_status_script()
      assert Bitwise.band(File.stat!(script).mode, 0o100) != 0
    end
  end

  describe "whiska init writes them" do
    test "no statusline", %{main: main} do
      capture_io(fn -> assert CLI.run(["init"], main) == 0 end)

      refute File.exists?(Path.join(main, Install.statusline_path()))
      settings = JSON.decode!(File.read!(Path.join(main, ".claude/settings.json")))
      refute Map.has_key?(settings, "statusLine")
    end

    test "takes out the statusline an earlier init wrote, and says so", %{main: main} do
      script = Path.join(main, Install.statusline_path())
      File.mkdir_p!(Path.dirname(script))
      File.write!(script, "#!/usr/bin/env bash\n# whiska-statusline: v4\n")

      File.write!(
        Path.join(main, ".claude/settings.json"),
        JSON.encode!(%{
          "statusLine" => %{"type" => "command", "command" => @ours_repo, "refreshInterval" => 1}
        })
      )

      said = capture_io(fn -> assert CLI.run(["init"], main) == 0 end)

      refute File.exists?(script)
      settings = JSON.decode!(File.read!(Path.join(main, ".claude/settings.json")))
      refute Map.has_key?(settings, "statusLine")
      assert said =~ Install.statusline_path()
      assert said =~ "herdr's sidebar"
    end

    test "names a leftover reached through a symlink, and leaves it where it lives", %{
      main: main
    } do
      elsewhere = Path.join(Path.dirname(main), "dotfiles/whiska-statusline.sh")
      File.mkdir_p!(Path.dirname(elsewhere))
      File.write!(elsewhere, "#!/usr/bin/env bash\n")
      File.mkdir_p!(Path.join(main, ".claude/hooks"))
      File.ln_s!(Path.dirname(elsewhere), Path.join(main, ".claude/hooks/linked"))
      File.ln_s!(elsewhere, Path.join(main, Install.statusline_path()))

      said = capture_io(fn -> assert CLI.run(["init"], main) == 0 end)

      assert File.exists?(elsewhere)
      assert said =~ "through a symlink"
      assert said =~ Install.statusline_path()
    end

    test "leaves somebody else's statusline, and their script, alone", %{main: main} do
      mine = %{"type" => "command", "command" => "bash .claude/hooks/mine.sh"}
      File.mkdir_p!(Path.join(main, ".claude/hooks"))
      File.write!(Path.join(main, ".claude/hooks/mine.sh"), "echo mine\n")
      File.write!(Path.join(main, ".claude/settings.json"), JSON.encode!(%{"statusLine" => mine}))

      capture_io(fn -> assert CLI.run(["init"], main) == 0 end)

      settings = JSON.decode!(File.read!(Path.join(main, ".claude/settings.json")))
      assert settings["statusLine"] == mine
      assert File.exists?(Path.join(main, ".claude/hooks/mine.sh"))
    end

    test "the shim itself is unchanged by this", %{main: main} do
      capture_io(fn -> assert CLI.run(["init"], main) == 0 end)
      assert File.read!(Path.join(main, Install.shim_path())) == Install.shim()
      assert Install.shim() =~ ~s(hook "$@")
    end
  end
end
