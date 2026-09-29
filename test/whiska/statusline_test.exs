defmodule Whiska.StatuslineTest do
  @moduledoc """
  Two lines, drawn in two places (ADR-0048, amended).

  `summary/1` and `render/1` are herdr's tab bar: the owl's state, always, and
  what is waiting on the whole machine. Machine-wide, so nothing there is
  scoped to a repo.

  `house/2` and `render_house/1` are the Claude Code statusline of one repo:
  what is waiting *here* and how many mice are alive here, and no owl — the
  owl's state is machine-wide and the tab bar's.

  The owl is found in the process table, faked here through `:owl_pids` the way
  `Whiska.Doctor` fakes it; the mice come from one herdr pane list, faked at the
  boundary (ADR-0031). Houses are real SQLite files under a tmp root.
  """
  use ExUnit.Case, async: false

  import Mox

  alias Whiska.Doorstep
  alias Whiska.Doorstep.Entry
  alias Whiska.Herdr.Mock, as: Herdr
  alias Whiska.OpenHouses
  alias Whiska.Statusline
  alias Whiska.Storage

  setup :set_mox_global

  setup do
    root = Path.join(System.tmp_dir!(), "whiska-sl-#{System.unique_integer([:positive])}")
    record = Path.join(root, "dot-whiska/houses")
    main = open!(root, "myrepo", record)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root, main: main, record: record}
  end

  # A house the owl has open: exists on disk and is in the record (ADR-0039).
  defp open!(root, name, record) do
    main = house!(root, name)
    OpenHouses.add(main, record)
    main
  end

  # A repo with a house: a `.git` and an opened (hence existing) database.
  defp house!(root, name) do
    main = Path.join(root, name)
    File.mkdir_p!(Path.join(main, ".git"))
    {:ok, handle} = Storage.open(main)
    Storage.close(handle)
    main
  end

  defp seed(main, branch, fun) do
    {:ok, handle} = Storage.open(main)

    {:ok, _} =
      Storage.record_mouse(%{mouse_id: "m-#{branch}", path: "/w/#{branch}", branch: branch})

    fun.(branch)
    Storage.close(handle)
  end

  defp ask(branch, text) do
    {:ok, _} =
      Storage.record_question(%{
        mouse_id: "m-#{branch}",
        text: text,
        kind: "needs-decision",
        status: "open"
      })
  end

  defp leave(main, branch, text, age_seconds) do
    {:ok, _} =
      Doorstep.leave(main, %Entry{
        mouse_id: "m-#{branch}",
        branch: branch,
        worktree_root: "/w/#{branch}",
        stamped_at: DateTime.add(DateTime.utc_now(), -age_seconds, :second),
        text: text
      })
  end

  # The owl is up unless a test says otherwise, and the record is this test's.
  defp summary(opts, record) do
    opts
    |> Keyword.put_new(:owl_pids, fn -> [4242] end)
    |> Keyword.put(:open_houses, record)
    |> Statusline.summary()
  end

  defp line(opts, record), do: opts |> summary(record) |> Statusline.render()

  defp pane(cwd) do
    %{
      pane_id: "w1:p#{System.unique_integer([:positive])}",
      cwd: cwd,
      agent: "claude",
      agent_status: "working"
    }
  end

  defp here(main, panes, opts \\ []) do
    stub(Herdr, :list_panes, fn _ -> {:ok, panes} end)

    main
    |> Statusline.house(Keyword.put_new(opts, :herdr_socket, "/fake/herdr.sock"))
    |> Statusline.render_house()
  end

  defp worktree!(main, branch) do
    root = Path.join(main, "worktrees/#{branch}")
    File.mkdir_p!(root)
    root
  end

  describe "the owl's state is always shown (ADR-0027 addendum)" do
    test "a quiet machine reads just the owl watching", %{record: record} do
      assert summary([], record).owl == :watching
      assert line([], record) == "🦉 watching"
    end

    test "no owl process is owl down, and with nothing waiting it says only that", %{
      record: record
    } do
      assert line([owl_pids: fn -> [] end], record) == "🦉 owl down"
    end

    test "an owl that is not collecting past the backstop is down, whatever the process table says",
         %{main: main, record: record} do
      leave(main, "feat-a", "old", 120)
      leave(main, "feat-b", "newer", 90)

      assert line([], record) == "🦉 owl down · 🐱 myrepo"
    end

    test "a doorstep entry younger than the backstop is the normal race, not an outage", %{
      main: main,
      record: record
    } do
      leave(main, "feat-a", "just left", 2)

      assert line([], record) == "🦉 watching · 🐱 myrepo"
    end
  end

  describe "what is waiting, machine-wide (ADR-0048)" do
    test "one whiska with something waiting is named by its repo", %{main: main, record: record} do
      # The person jumps to a whiska, never straight to a mouse (ADR-0043), so
      # the name on the bar is the repo's, and two questions in one repo are
      # still one place to go.
      seed(main, "feat-auth", &ask(&1, "[worktree-status: needs-decision] pick one"))
      seed(main, "feat-rates", &ask(&1, "and this"))

      assert line([], record) == "🦉 watching · 🐱 myrepo"
    end

    test "several whiskas become a count of whiskas, not of questions", %{
      root: root,
      main: main,
      record: record
    } do
      other = open!(root, "api-service", record)
      seed(main, "feat-auth", &ask(&1, "a"))
      seed(other, "feat-rates", &ask(&1, "b"))
      leave(other, "feat-rates", "c", 5)

      assert line([], record) == "🦉 watching · 🐱 2 whiskas"
    end

    test "a house with nothing waiting adds nothing", %{root: root, record: record} do
      open!(root, "quiet", record)

      assert line([], record) == "🦉 watching"
    end

    test "a repo with a house on disk but not in the record is not read", %{
      root: root,
      record: record
    } do
      crew = house!(root, "crew")
      seed(crew, "feat-x", &ask(&1, "ignored"))

      assert line([], record) == "🦉 watching"
    end

    test "with the owl down, what is waiting is still counted — the record is read either way",
         %{root: root, main: main, record: record} do
      other = open!(root, "api-service", record)
      seed(main, "feat-auth", &ask(&1, "a"))
      leave(other, "feat-rates", "b", 5)

      assert line([owl_pids: fn -> [] end], record) == "🦉 owl down · 🐱 2 whiskas"
    end
  end

  describe "the owl in the process table" do
    test "Whiska.Owl.pids/0 is the one probe the doctor and the statusline share" do
      pids = Whiska.Owl.pids()
      assert is_list(pids)
      assert Enum.all?(pids, &is_integer/1)
    end
  end

  describe "the repo-scoped line the Claude statusline appends (ADR-0048, amended)" do
    test "a quiet repo says nothing at all — the global statusline is what shows", %{main: main} do
      assert here(main, []) == ""
    end

    test "one thing waiting here is named by its mouse's branch", %{main: main} do
      seed(main, "feat-auth", &ask(&1, "[worktree-status: needs-decision] pick one"))

      assert here(main, []) == "🐱 feat-auth"
    end

    test "several become a count of what waits here", %{main: main} do
      seed(main, "feat-auth", &ask(&1, "a"))
      seed(main, "feat-rates", &ask(&1, "b"))
      leave(main, "feat-logs", "c", 5)

      assert here(main, []) == "🐱 3 waiting"
    end

    test "two questions from one mouse are one branch, not two", %{main: main} do
      seed(main, "feat-auth", fn b ->
        ask(b, "first")
        ask(b, "second")
      end)

      assert here(main, []) == "🐱 feat-auth"
    end

    test "a doorstep entry counts, so the line and whiska waiting cannot disagree", %{main: main} do
      leave(main, "feat-auth", "still uncollected", 5)

      assert here(main, []) == "🐱 feat-auth"
    end

    test "another repo's waiting never appears here", %{root: root, main: main, record: record} do
      other = open!(root, "api-service", record)
      seed(other, "feat-rates", &ask(&1, "not this repo's"))

      assert here(main, []) == ""
    end

    test "the owl never appears here: its state is machine-wide and the tab bar's", %{main: main} do
      leave(main, "feat-auth", "old enough to be an outage", 120)

      refute here(main, []) =~ "🦉"
    end
  end

  describe "the mice segment (ADR-0027, mice come from herdr, not the house)" do
    test "one mouse alive in a worktree of this repo", %{main: main} do
      assert here(main, [pane(worktree!(main, "feat-auth"))]) == "🐭 1 mouse"
    end

    test "several are a count", %{main: main} do
      panes = [pane(worktree!(main, "feat-auth")), pane(worktree!(main, "feat-rates"))]

      assert here(main, panes) == "🐭 2 mice"
    end

    test "two panes in one worktree are one mouse (ADR-0023)", %{main: main} do
      root = worktree!(main, "feat-auth")

      assert here(main, [pane(root), pane(root)]) == "🐭 1 mouse"
    end

    test "a pane in another repo's worktree is not a mouse here", %{
      root: root,
      main: main,
      record: record
    } do
      other = open!(root, "api-service", record)

      assert here(main, [pane(worktree!(other, "feat-rates"))]) == ""
    end

    test "a repo reached through a symlink still finds its mice", %{root: root, main: main} do
      worktree = worktree!(main, "feat-auth")
      link = Path.join(root, "link-to-repo")
      File.ln_s!(main, link)

      assert here(link, [pane(worktree)]) == "🐭 1 mouse"
    end

    test "the main checkout's own pane is a whiska, not a mouse", %{main: main} do
      assert here(main, [pane(main)]) == ""
    end

    test "no herdr socket leaves the mice out rather than guessing", %{main: main} do
      _ = worktree!(main, "feat-auth")

      assert Statusline.house(main, herdr_socket: nil).mice == nil
      assert Statusline.render_house(Statusline.house(main, herdr_socket: nil)) == ""
    end

    test "what waits comes first, then what is running", %{main: main} do
      seed(main, "feat-auth", &ask(&1, "a"))

      assert here(main, [pane(worktree!(main, "feat-auth"))]) == "🐱 feat-auth · 🐭 1 mouse"
    end
  end
end
