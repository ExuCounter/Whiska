defmodule Whiska.OwlTest do
  @moduledoc "The one owl: opening and shutting houses inside it (ADR-0001, ADR-0003)."
  # Serial: the owl is one named process per VM, and the houses it opens call
  # herdr from their own processes, which is why the mock is global.
  use ExUnit.Case, async: false

  import Mox

  alias Whiska.Herdr.Mock, as: Herdr
  alias Whiska.Owl
  alias Whiska.Storage

  setup :set_mox_global
  setup :verify_on_exit!
  setup {Whiska.Test.QuietSidebar, :stub_sidebar}

  setup do
    root = Path.join(System.tmp_dir!(), "whiska-owl-#{System.unique_integer([:positive])}")
    a = Path.join(root, "alpha")
    b = Path.join(root, "beta")
    File.mkdir_p!(Path.join(a, ".git"))
    File.mkdir_p!(Path.join(b, ".git"))
    on_exit(fn -> File.rm_rf!(root) end)

    stub(Herdr, :list_panes, fn _ -> {:ok, []} end)
    stub(Herdr, :subscribe, fn _, _, _ -> {:ok, spawn(fn -> receive do: (:stop -> :ok) end)} end)

    start_supervised!({Owl, herdr_socket: "/fake/herdr.sock"})
    {:ok, a: a, b: b}
  end

  test "starts with no house open" do
    assert Owl.open_houses() == []
  end

  test "opens a house per repo and lists them", %{a: a, b: b} do
    assert {:ok, pid_a} = Owl.open_house(a)
    assert {:ok, pid_b} = Owl.open_house(b)
    assert pid_a != pid_b
    assert Enum.sort(Owl.open_houses()) == Enum.sort([a, b])
  end

  test "opening an already-open house is a no-op that names the same house", %{a: a} do
    {:ok, pid} = Owl.open_house(a)
    assert {:ok, ^pid} = Owl.open_house(a)
    assert Owl.open_houses() == [a]
  end

  test "finds an open house by its main checkout", %{a: a} do
    {:ok, pid} = Owl.open_house(a)
    assert Owl.house(a) == {:ok, pid}
    assert Owl.house("/nowhere") == {:error, :shut}
  end

  test "shutting a house leaves it on disk and the others open", %{a: a, b: b} do
    {:ok, pid} = Owl.open_house(a)
    {:ok, _} = Owl.open_house(b)
    ref = Process.monitor(pid)

    assert :ok = Owl.shut_house(a)

    assert_receive {:DOWN, ^ref, :process, ^pid, _}
    assert Owl.open_houses() == [b]
    assert File.exists?(Storage.database_path(a))
  end

  test "shutting a house that is not open says so", %{a: a} do
    assert {:error, :shut} = Owl.shut_house(a)
  end

  test "nothing under the owl reaches across houses (ADR-0044)", %{a: a, b: b} do
    {:ok, _} = Owl.open_house(a)
    {:ok, _} = Owl.open_house(b)

    houses = Owl.open_houses() |> Enum.map(&elem(Owl.house(&1), 1)) |> MapSet.new()

    others =
      Whiska.Owl.Houses
      |> DynamicSupervisor.which_children()
      |> Enum.map(fn {_, pid, _, _} -> pid end)
      |> MapSet.new()
      |> MapSet.difference(houses)

    assert MapSet.size(others) == 0

    # The owl itself is the registry and the houses, and nothing else: the
    # cross-house nudge is gone, and the statusline's own timer redraws the
    # elsewhere segment instead.
    assert Owl
           |> Supervisor.which_children()
           |> Enum.map(fn {id, _, _, _} -> id end)
           |> Enum.sort() == Enum.sort([Whiska.Owl.Registry, Whiska.Owl.Houses])
  end

  test "a house that crashes is reopened by the owl", %{a: a} do
    {:ok, pid} = Owl.open_house(a)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

    # Give the supervisor a moment to restart it.
    Process.sleep(50)
    assert {:ok, new} = Owl.house(a)
    assert new != pid
  end

  describe "started_at/1 — how long the running owl has been running" do
    test "reads the elapsed time ps prints, in each of its three widths" do
      now = ~U[2026-10-02 12:00:00Z]

      assert Owl.started_at(1, now, fn 1 -> "        12:34\n" end) ==
               ~U[2026-10-02 11:47:26Z]

      assert Owl.started_at(1, now, fn 1 -> "01:02:03\n" end) == ~U[2026-10-02 10:57:57Z]
      assert Owl.started_at(1, now, fn 1 -> "2-01:00:00\n" end) == ~U[2026-09-30 11:00:00Z]
    end

    test "a pid ps knows nothing about, or output it cannot read, is nil" do
      now = ~U[2026-10-02 12:00:00Z]

      assert Owl.started_at(1, now, fn 1 -> nil end) == nil
      assert Owl.started_at(1, now, fn 1 -> "" end) == nil
      assert Owl.started_at(1, now, fn 1 -> "not a time\n" end) == nil
      assert Owl.started_at(1, now, fn 1 -> "900\n" end) == nil
    end

    test "the owl running these tests is not it, but this process has a real start time" do
      self = String.to_integer(System.pid())

      assert %DateTime{} = at = Owl.started_at(self)
      assert DateTime.compare(at, DateTime.utc_now()) == :lt
    end
  end
end
