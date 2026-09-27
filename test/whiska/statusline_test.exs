defmodule Whiska.StatuslineTest do
  @moduledoc """
  The whole statusline: the owl's state always, the whiskas on the machine
  when there is more than one, the mice alive here, the questions waiting
  here, and the whiskas elsewhere with something waiting (ADR-0027).

  The owl is found in the process table, faked here through `:owl_pids` the
  way `Whiska.Doctor` fakes it.

  Everything live comes from one herdr pane list, faked at the boundary
  (ADR-0031); houses are real SQLite files under a tmp root.
  """
  use ExUnit.Case, async: false

  import Mox

  alias Whiska.Doorstep
  alias Whiska.Doorstep.Entry
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

  defp leave(main, text, age_seconds) do
    {:ok, _} =
      Doorstep.leave(main, %Entry{
        mouse_id: "m1",
        branch: "feat-a",
        worktree_root: "/w/a",
        stamped_at: DateTime.add(DateTime.utc_now(), -age_seconds, :second),
        text: text
      })
  end

  defp pane(id, cwd, agent \\ "claude"),
    do: %{pane_id: id, cwd: cwd, agent: agent, agent_status: "idle"}

  # The owl is up unless a test says otherwise.
  defp summary!(main, opts) do
    {:ok, summary} = Statusline.summary(main, Keyword.put_new(opts, :owl_pids, fn -> [4242] end))
    summary
  end

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

      summary = summary!(main, herdr_socket: "/sock")

      assert Statusline.render(summary) ==
               "🦉 watching · 🐈 3 whiskas · 🐭 2 mice · 🐱 2 questions waiting · ⚡ api-service waiting"
    end

    test "several whiskas waiting elsewhere become a count", %{root: root, main: main} do
      others = for name <- ~w(one two three), do: house!(root, name)
      for other <- others, do: seed(other, fn -> ask("x") end)

      expect(Herdr, :list_panes, fn _ -> {:ok, Enum.map(others, &pane(&1, &1))} end)

      summary = summary!(main, herdr_socket: "/sock")

      assert Statusline.render(summary) ==
               "🦉 watching · 🐈 4 whiskas · ⚡ 3 whiskas waiting elsewhere"
    end

    test "one mouse is singular, and this repo is never 'elsewhere'", %{main: main} do
      expect(Herdr, :list_panes, fn _ ->
        {:ok, [pane("p1", main), pane("p2", "#{main}/worktrees/feat-a")]}
      end)

      summary = summary!(main, herdr_socket: "/sock")
      assert Statusline.render(summary) == "🦉 watching · 🐭 1 mouse"
    end

    test "a whiska elsewhere with nothing waiting adds no elsewhere segment, only a head",
         %{root: root, main: main} do
      other = house!(root, "api-service")
      expect(Herdr, :list_panes, fn _ -> {:ok, [pane("p1", other)]} end)

      summary = summary!(main, herdr_socket: "/sock")
      assert Statusline.render(summary) == "🦉 watching · 🐈 2 whiskas"
    end

    test "without herdr, the owl and what the house knows are shown", %{main: main} do
      seed(main, fn -> ask("[worktree-status: needs-decision] pick one") end)

      summary = summary!(main, herdr_socket: nil)
      assert summary.whiskas == nil
      assert Statusline.render(summary) == "🦉 watching · 🐱 feat-a: pick one"

      expect(Herdr, :list_panes, fn _ -> {:error, :econnrefused} end)
      summary = summary!(main, herdr_socket: "/sock")
      assert Statusline.render(summary) == "🦉 watching · 🐱 feat-a: pick one"
    end
  end

  describe "the owl's state is always shown (ADR-0027 addendum)" do
    test "a quiet laptop reads just the owl watching", %{main: main} do
      expect(Herdr, :list_panes, fn _ -> {:ok, [pane("p1", main)]} end)

      summary = summary!(main, herdr_socket: "/sock")
      assert summary.owl == :watching
      assert Statusline.render(summary) == "🦉 watching"
    end

    test "no owl process is owl down, with the doorstep count even when it is zero",
         %{main: main} do
      expect(Herdr, :list_panes, fn _ -> {:ok, [pane("p1", main)]} end)

      {:ok, summary} = Statusline.summary(main, herdr_socket: "/sock", owl_pids: fn -> [] end)
      assert summary.owl == :down
      assert Statusline.render(summary) == "🦉 owl down · 0 waiting"
    end

    test "an owl that is not collecting past the backstop is down, whatever the process table says",
         %{main: main} do
      leave(main, "old", 120)
      leave(main, "newer", 90)
      expect(Herdr, :list_panes, fn _ -> {:ok, [pane("p1", main)]} end)

      summary = summary!(main, herdr_socket: "/sock")
      assert Statusline.render(summary) == "🦉 owl down · 2 waiting"
    end

    test "owl down comes first, before everything else", %{root: root, main: main} do
      other = house!(root, "api-service")
      seed(other, fn -> ask("c") end)
      expect(Herdr, :list_panes, fn _ -> {:ok, [pane("p1", main), pane("p2", other)]} end)

      {:ok, summary} = Statusline.summary(main, herdr_socket: "/sock", owl_pids: fn -> [] end)

      assert Statusline.render(summary) ==
               "🦉 owl down · 0 waiting · 🐈 2 whiskas · ⚡ api-service waiting"
    end
  end

  describe "the whiska headcount (ADR-0027 addendum)" do
    test "this repo always counts as one, even when its only pane is in a worktree",
         %{root: root, main: main} do
      other = house!(root, "api-service")

      expect(Herdr, :list_panes, fn _ ->
        {:ok, [pane("p1", "#{main}/worktrees/feat-a"), pane("p2", other)]}
      end)

      summary = summary!(main, herdr_socket: "/sock")
      assert summary.whiskas == 2
      assert Statusline.render(summary) == "🦉 watching · 🐈 2 whiskas · 🐭 1 mouse"
    end

    test "one whiska is not worth a segment", %{main: main} do
      expect(Herdr, :list_panes, fn _ -> {:ok, [pane("p1", main), pane("p2", "/nowhere")]} end)

      summary = summary!(main, herdr_socket: "/sock")
      assert summary.whiskas == 1
      assert Statusline.render(summary) == "🦉 watching"
    end
  end

  describe "the owl in the process table" do
    test "Whiska.Owl.pids/0 is the one probe the doctor and the statusline share" do
      pids = Whiska.Owl.pids()
      assert is_list(pids)
      assert Enum.all?(pids, &is_integer/1)
    end
  end
end
