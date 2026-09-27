defmodule Whiska.StatuslineTest do
  @moduledoc """
  The whole statusline: the owl, the mice alive here, the questions waiting
  here, and the whiskas elsewhere with something waiting (ADR-0027).

  Everything live comes from one herdr pane list, faked at the boundary
  (ADR-0031); houses are real SQLite files under a tmp root.
  """
  use ExUnit.Case, async: false

  import Mox

  alias Whiska.Herdr.Mock, as: Herdr
  alias Whiska.Statusline
  alias Whiska.Storage

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    root = Path.join(System.tmp_dir!(), "whiska-sl-#{System.unique_integer([:positive])}")
    main = house!(root, "myrepo")
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root, main: main}
  end

  # A repo with a house: a `.git` and an opened (hence existing) database.
  defp house!(root, name) do
    main = Path.join(root, name)
    File.mkdir_p!(Path.join(main, ".git"))
    {:ok, handle} = Storage.open(main)
    Storage.close(handle)
    main
  end

  defp seed(main, fun) do
    {:ok, handle} = Storage.open(main)
    {:ok, _} = Storage.record_mouse(%{mouse_id: "m1", path: "/w/a", branch: "feat-a"})
    fun.()
    Storage.close(handle)
  end

  defp ask(text) do
    {:ok, _} =
      Storage.record_question(%{
        mouse_id: "m1",
        text: text,
        kind: "needs-decision",
        status: "open"
      })
  end

  defp pane(id, cwd, agent \\ "claude"),
    do: %{pane_id: id, cwd: cwd, agent: agent, agent_status: "idle"}

  describe "mice_here/2 — live agent panes in this repo's worktrees" do
    test "counts distinct worktrees with a live agent pane, not panes (ADR-0023)", %{main: main} do
      panes = [
        pane("p1", "#{main}/worktrees/feat-a/lib"),
        pane("p2", "#{main}/worktrees/feat-a"),
        pane("p3", "#{main}/worktrees/feat-b"),
        pane("p4", "#{main}/worktrees/feat-c", nil),
        pane("p5", main),
        pane("p6", "/elsewhere/worktrees/feat-z")
      ]

      assert Statusline.mice_here(panes, main) == 2
    end
  end

  describe "whiskas/1 — live agent panes sitting in a repo root that has a house" do
    test "one per repo with a house, none for a repo without", %{root: root, main: main} do
      other = house!(root, "api-service")
      bare = Path.join(root, "no-house")
      File.mkdir_p!(Path.join(bare, ".git"))

      panes = [
        pane("p1", main),
        pane("p2", Path.join(main, "lib")),
        pane("p3", other),
        pane("p4", bare),
        pane("p5", "#{main}/worktrees/feat-a"),
        pane("p6", other, nil)
      ]

      assert Enum.sort(Statusline.whiskas(panes)) == Enum.sort([main, other])
    end
  end

  describe "summary/2 and render/1" do
    test "mice here, questions here, and the one whiska waiting elsewhere is named",
         %{root: root, main: main} do
      other = house!(root, "api-service")
      quiet = house!(root, "quiet")

      seed(main, fn ->
        ask("a")
        ask("b")
      end)

      seed(other, fn -> ask("c") end)

      expect(Herdr, :list_panes, fn "/sock" ->
        {:ok,
         [
           pane("p1", main),
           pane("p2", "#{main}/worktrees/feat-a"),
           pane("p3", "#{main}/worktrees/feat-b"),
           pane("p4", other),
           pane("p5", quiet)
         ]}
      end)

      {:ok, summary} = Statusline.summary(main, herdr_socket: "/sock")

      assert Statusline.render(summary) ==
               "🐭 2 mice · 🐱 2 questions waiting · ⚡ api-service waiting"
    end

    test "several whiskas waiting elsewhere become a count", %{root: root, main: main} do
      others = for name <- ~w(one two three), do: house!(root, name)
      for other <- others, do: seed(other, fn -> ask("x") end)

      expect(Herdr, :list_panes, fn _ -> {:ok, Enum.map(others, &pane(&1, &1))} end)

      {:ok, summary} = Statusline.summary(main, herdr_socket: "/sock")
      assert Statusline.render(summary) == "⚡ 3 whiskas waiting elsewhere"
    end

    test "one mouse is singular, and this repo is never 'elsewhere'", %{main: main} do
      expect(Herdr, :list_panes, fn _ ->
        {:ok, [pane("p1", main), pane("p2", "#{main}/worktrees/feat-a")]}
      end)

      {:ok, summary} = Statusline.summary(main, herdr_socket: "/sock")
      assert Statusline.render(summary) == "🐭 1 mouse"
    end

    test "a whiska elsewhere with nothing waiting adds nothing", %{root: root, main: main} do
      other = house!(root, "api-service")
      expect(Herdr, :list_panes, fn _ -> {:ok, [pane("p1", other)]} end)

      {:ok, summary} = Statusline.summary(main, herdr_socket: "/sock")
      assert Statusline.render(summary) == ""
    end

    test "without herdr, only what the house knows is shown", %{main: main} do
      seed(main, fn -> ask("[worktree-status: needs-decision] pick one") end)

      {:ok, summary} = Statusline.summary(main, herdr_socket: nil)
      assert Statusline.render(summary) == "🐱 feat-a: pick one"

      expect(Herdr, :list_panes, fn _ -> {:error, :econnrefused} end)
      {:ok, summary} = Statusline.summary(main, herdr_socket: "/sock")
      assert Statusline.render(summary) == "🐱 feat-a: pick one"
    end
  end
end
