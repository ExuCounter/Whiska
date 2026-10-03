defmodule Whiska.SessionTest do
  @moduledoc """
  Which session this is — answered from where it started and which pane it runs
  in, never from where its shell currently stands (ADR-0053).
  """
  # Serial: the tests set HERDR_PANE_ID in the OS env.
  use ExUnit.Case, async: false

  alias Whiska.Layout
  alias Whiska.Session

  setup do
    root = Path.join(System.tmp_dir!(), "whiska-session-#{System.unique_integer([:positive])}")
    main = Path.join(root, "myrepo")
    worktree = Path.join(main, "worktrees/feat-thing")
    File.mkdir_p!(Path.join(main, ".git"))
    File.mkdir_p!(Path.join(worktree, "lib"))
    File.write!(Path.join(worktree, ".git"), "gitdir: #{main}/.git/worktrees/feat-thing\n")

    was = System.get_env("HERDR_PANE_ID")
    System.delete_env("HERDR_PANE_ID")

    on_exit(fn ->
      File.rm_rf!(root)
      if was, do: System.put_env("HERDR_PANE_ID", was), else: System.delete_env("HERDR_PANE_ID")
    end)

    {:ok, root: root, main: main, worktree: worktree}
  end

  defp transcript(dir, cwds) do
    path = Path.join(dir, "transcript-#{System.unique_integer([:positive])}.jsonl")
    File.write!(path, Enum.map_join(cwds, "\n", &JSON.encode!(%{"type" => "user", "cwd" => &1})))
    path
  end

  describe "worktree/1" do
    test "a main session that cd'd into a worktree is still the main session", %{
      root: root,
      main: main,
      worktree: worktree
    } do
      path = transcript(root, [main, worktree])

      assert Session.worktree(%{"cwd" => worktree, "transcript_path" => path}) ==
               {:error, :not_a_mouse}
    end

    test "a mouse that cd'd out of its worktree is still that mouse", %{
      root: root,
      main: main,
      worktree: worktree
    } do
      path = transcript(root, [worktree, main])

      assert {:ok, %Layout{worktree_root: ^worktree, branch_label: "feat-thing"}} =
               Session.worktree(%{"cwd" => main, "transcript_path" => path})
    end

    test "a session started in a subfolder belongs to the worktree above it", %{
      root: root,
      worktree: worktree
    } do
      path = transcript(root, [Path.join(worktree, "lib")])

      assert {:ok, %Layout{worktree_root: ^worktree}} =
               Session.worktree(%{"cwd" => "/", "transcript_path" => path})
    end

    test "falls back to the payload's own directory with no transcript", %{worktree: worktree} do
      assert {:ok, %Layout{worktree_root: ^worktree}} = Session.worktree(%{"cwd" => worktree})
    end

    test "falls back when the transcript is gone or names no directory", %{
      root: root,
      worktree: worktree
    } do
      gone = Path.join(root, "gone.jsonl")
      silent = Path.join(root, "silent.jsonl")
      File.write!(silent, JSON.encode!(%{"type" => "mode"}))

      for path <- [gone, silent] do
        assert {:ok, %Layout{worktree_root: ^worktree}} =
                 Session.worktree(%{"cwd" => worktree, "transcript_path" => path})
      end
    end

    test "the main checkout itself is no mouse", %{main: main} do
      assert Session.worktree(%{"cwd" => main}) == {:error, :not_a_mouse}
    end
  end

  describe "main_pane?/1" do
    test "the pane this hook is running in, as the house recorded it" do
      System.put_env("HERDR_PANE_ID", "w1:p2")

      assert Session.main_pane?("w1:p2")
      refute Session.main_pane?("w1:p3")
      refute Session.main_pane?(nil)
    end

    test "no herdr pane around means no claim either way" do
      refute Session.main_pane?("w1:p2")
    end
  end
end
