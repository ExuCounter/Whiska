defmodule Whiska.RetiredReviewLoopTest do
  @moduledoc """
  What is left of `.claude/hooks/review-loop.sh` once finishing is the mouse's own
  pipeline (ADR-0049).

  Whiska writes no such file and chains no such file. One that is already on disk is
  still the repo's: the doctor says it is retired and nothing removes it (ADR-0038,
  ADR-0007).
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Whiska.CLI
  alias Whiska.Doctor.Check
  alias Whiska.Install

  setup do
    root = Path.join(System.tmp_dir!(), "whiska-retired-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, ".git"))
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  describe "whiska init" do
    test "writes no review loop", %{root: root} do
      capture_io(fn -> CLI.run(["init"], root) end)

      refute File.exists?(Path.join(root, Install.review_loop_path()))
    end

    test "leaves one that is already there exactly as it is", %{root: root} do
      path = Path.join(root, Install.review_loop_path())
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "#!/usr/bin/env bash\nCHECK='make ci'\n")

      capture_io(fn -> CLI.run(["init"], root) end)

      assert File.read!(path) == "#!/usr/bin/env bash\nCHECK='make ci'\n"
    end
  end

  describe "the shim" do
    test "runs nothing before whiska hook stop" do
      refute Install.shim() =~ Path.basename(Install.review_loop_path())
    end

    test "an entry an older version wrote is still recognised as ours" do
      stale = %{
        "hooks" => %{
          "Stop" => [
            %{
              "hooks" => [
                %{
                  "type" => "command",
                  "command" => ~s|bash "$CLAUDE_PROJECT_DIR/#{Install.review_loop_path()}"|
                }
              ]
            }
          ]
        }
      }

      assert Install.merge(stale) == Install.merge(%{})
    end
  end

  describe "whiska doctor" do
    test "says nothing when there is no review loop", %{root: root} do
      assert %Check{status: :ok} = Whiska.Doctor.review_loop(root)
    end

    test "a repo without one gets no line in the report at all", %{root: root} do
      report = Whiska.Doctor.run(root, env: %{"HOME" => root}, owl_pids: fn -> [] end)

      refute Enum.find(report.checks, &(&1.name == "review loop"))
    end

    test "a leftover file is one warning in the report", %{root: root} do
      path = Path.join(root, Install.review_loop_path())
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "#!/usr/bin/env bash\n")

      report = Whiska.Doctor.run(root, env: %{"HOME" => root}, owl_pids: fn -> [] end)

      assert %Check{status: :warn} = Enum.find(report.checks, &(&1.name == "review loop"))
    end

    test "names it retired, and the command that removes it", %{root: root} do
      path = Path.join(root, Install.review_loop_path())
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "#!/usr/bin/env bash\n")

      assert %Check{status: :warn, detail: detail, fix: fix} = Whiska.Doctor.review_loop(root)
      assert detail =~ "retired"
      # The doctor is run from any worktree but checks the main checkout, so a
      # relative path would name a different file in the pane it is pasted into.
      assert fix == "rm #{path}"
      assert File.exists?(path), "the doctor never repairs (ADR-0038)"
    end
  end
end
