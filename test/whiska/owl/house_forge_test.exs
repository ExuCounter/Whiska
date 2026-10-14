defmodule Whiska.Owl.HouseForgeTest do
  @moduledoc """
  The house reading each recorded merge request on its forge on the backstop
  (ADR-0087): a real git repo, a fake `glab` on disk handed to the house, and
  herdr faked at its one boundary (ADR-0031).
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO
  import Mox

  alias Whiska.Herdr.Mock, as: Herdr
  alias Whiska.MergeRequests
  alias Whiska.Owl.House
  alias Whiska.Storage
  alias Whiska.Test.FakeGlab
  alias Whiska.Test.GitRepo

  setup :verify_on_exit!
  setup {Whiska.Test.QuietSidebar, :stub_sidebar}

  @socket "/fake/herdr.sock"
  @url "https://gitlab.example.com/acme/app/-/merge_requests/7"
  @mr "projects/acme%2Fapp/merge_requests/7"
  @discussions @mr <> "/discussions?per_page=100&page=1"
  @head "63c4726204434e1c2384eb0e3632940235b51ab4"

  setup do
    root = Path.join(System.tmp_dir!(), "whiska-hf-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    repo = GitRepo.create(root)
    path = GitRepo.worktree(repo, "feat-a")

    {:ok, handle} = Storage.open(repo.checkout, name: nil)
    {:ok, _} = Storage.record_mouse(%{mouse_id: "ma", path: path, branch: "feat-a"})

    {:ok, _} =
      Storage.record_question(%{mouse_id: "ma", text: "done", kind: "done", status: "closed"})

    Storage.close(handle)

    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, repo: repo, path: path, forge: FakeGlab.create(root)}
  end

  defp start_house(opts) do
    name = :"house-#{System.unique_integer([:positive])}"
    allow(Herdr, self(), fn -> Process.whereis(name) end)
    start_supervised!({House, [name: name] ++ opts})
  end

  defp open(repo, forge, opts) do
    opts =
      Keyword.merge(
        [
          main_checkout: repo.checkout,
          herdr_socket: @socket,
          backstop_ms: 20,
          board_ms: 60_000,
          forge_ms: 10,
          forge_tools: %{"glab" => forge.bin}
        ],
        opts
      )

    pid = start_house(opts)
    House.sync(pid)
    pid
  end

  defp quiet_herdr(path) do
    stub(Herdr, :list_panes, fn @socket -> {:ok, []} end)
    stub(Herdr, :subscribe, fn @socket, _subs, _listener -> {:ok, spawn(fn -> :ok end)} end)

    stub(Herdr, :worktrees, fn @socket, _checkout ->
      {:ok, [%{path: path, branch: "feat-a", workspace_id: nil}]}
    end)
  end

  defp record_merge_request(repo, url \\ @url) do
    {:ok, handle} = Storage.open(repo.checkout, name: nil)
    {:ok, _} = Storage.record_merge_request("ma", url)
    Storage.close(handle)
  end

  defp row(repo) do
    {:ok, handle} = Storage.open(repo.checkout, name: nil)
    row = MergeRequests.reads()["ma"]
    Storage.close(handle)
    row
  end

  defp until(what, tries \\ 1000) do
    cond do
      what.() ->
        :ok

      tries > 0 ->
        Process.sleep(10)
        until(what, tries - 1)

      true ->
        flunk("never got there")
    end
  end

  defp merge_request(fields) do
    Map.merge(
      %{
        "state" => "opened",
        "sha" => @head,
        "user_notes_count" => 0,
        "updated_at" => "2026-10-14T09:00:00Z",
        "head_pipeline" => nil
      },
      Map.new(fields)
    )
  end

  defp thread(id, {author_id, username}) do
    %{
      "resolvable" => true,
      "resolved" => false,
      "notes" => [
        %{"id" => id, "system" => false, "author" => %{"id" => author_id, "username" => username}}
      ]
    }
  end

  test "a new comment from a member is said as a wake, once",
       %{repo: repo, path: path, forge: forge} do
    record_merge_request(repo)
    FakeGlab.answer(forge, "user", %{"id" => 1, "username" => "me"})
    FakeGlab.answer(forge, @mr, merge_request([]))
    FakeGlab.answer(forge, @discussions, [])
    quiet_herdr(path)

    log =
      capture_io(:stderr, fn ->
        house = open(repo, forge, [])
        until(fn -> match?(%{read_at: %DateTime{}}, row(repo)) end)

        FakeGlab.answer(
          forge,
          @mr,
          merge_request(user_notes_count: 1, updated_at: "2026-10-14T09:01:00Z")
        )

        FakeGlab.answer(forge, "projects/acme%2Fapp/members/all/2", %{"id" => 2})
        FakeGlab.answer(forge, @discussions, [thread(11, {2, "alice"})])
        until(fn -> match?(%{seen_note_id: 11}, row(repo)) end)
        Process.sleep(100)
        House.sync(house)
      end)

    assert [_once] = Regex.scan(~r/feat-a: would wake for !7 — 1 new comment by alice/, log)
  end

  test "a pipeline that fails on the head is said as a wake, once",
       %{repo: repo, path: path, forge: forge} do
    record_merge_request(repo)
    FakeGlab.answer(forge, @mr, merge_request([]))
    FakeGlab.answer(forge, @discussions, [])
    quiet_herdr(path)

    log =
      capture_io(:stderr, fn ->
        house = open(repo, forge, [])
        until(fn -> match?(%{read_at: %DateTime{}}, row(repo)) end)

        FakeGlab.answer(
          forge,
          @mr,
          merge_request(
            updated_at: "2026-10-14T09:02:00Z",
            head_pipeline: %{"id" => 900, "status" => "failed", "sha" => @head}
          )
        )

        until(fn -> match?(%{seen_failed_pipeline_id: 900}, row(repo)) end)
        Process.sleep(100)
        House.sync(house)
      end)

    assert [_once] = Regex.scan(~r/feat-a: would wake for !7 — pipeline failed on 63c47262/, log)
  end

  test "merged on the forge fetches the base at once, and the worktree comes down",
       %{repo: repo, path: path, forge: forge} do
    record_merge_request(repo)
    FakeGlab.answer(forge, @mr, merge_request([]))
    FakeGlab.answer(forge, @discussions, [])
    quiet_herdr(path)

    log =
      capture_io(:stderr, fn ->
        house = open(repo, forge, fetch_ms: 3_600_000)
        until(fn -> :sys.get_state(house).fetch_due_at != nil end)
        until(fn -> match?(%{state: "open"}, row(repo)) end)

        GitRepo.merge_on_forge(repo, "feat-a")
        FakeGlab.answer(forge, @mr, merge_request(state: "merged"))
        until(fn -> not File.dir?(path) end)
        House.sync(house)
      end)

    assert log =~ "feat-a: !7 merged on the forge"
    refute File.dir?(path)
  end

  test "a forge that cannot be read is said once, and the row says since when",
       %{repo: repo, path: path, forge: forge} do
    record_merge_request(repo)
    FakeGlab.answer(forge, @mr, %{"message" => "401 Unauthorized"}, status: 401)
    quiet_herdr(path)

    log =
      capture_io(:stderr, fn ->
        house = open(repo, forge, [])
        until(fn -> length(FakeGlab.calls(forge)) >= 3 end)
        House.sync(house)
      end)

    assert [_once] = Regex.scan(~r/feat-a: !7 cannot be read/, log)
    assert %{unread_since: %DateTime{}, read_at: nil, unread_reason: "{:http, 401}"} = row(repo)
  end

  defp questions(repo) do
    {:ok, handle} = Storage.open(repo.checkout, name: nil)
    questions = Storage.all(Whiska.Schema.Question) |> Enum.sort_by(& &1.id)
    Storage.close(handle)
    questions
  end

  test "a merge request closed on the forge asks once whether to drop the worktree",
       %{repo: repo, path: path, forge: forge} do
    record_merge_request(repo)
    FakeGlab.answer(forge, @mr, merge_request([]))
    FakeGlab.answer(forge, @discussions, [])
    quiet_herdr(path)

    log =
      capture_io(:stderr, fn ->
        house = open(repo, forge, [])
        until(fn -> match?(%{state: "open"}, row(repo)) end)

        FakeGlab.answer(forge, @mr, merge_request(state: "closed"))
        until(fn -> match?(%{asked_at: %DateTime{}}, row(repo)) end)
        until(fn -> Enum.any?(questions(repo), &(&1.asked_by == "owl")) end)
        Process.sleep(100)
        House.sync(house)
      end)

    assert [asked] = Enum.filter(questions(repo), &(&1.asked_by == "owl"))
    assert asked.mouse_id == "ma"
    assert asked.kind == "needs-decision"
    assert asked.status == "open"
    assert asked.text =~ "!7 was closed on the forge"
    assert log =~ "feat-a: !7 closed on the forge"
    assert File.dir?(path)
  end

  test "an entry that only claims to be the owl's is a mouse's question", %{
    repo: repo,
    path: path
  } do
    quiet_herdr(path)
    mouse = %Whiska.Schema.Mouse{mouse_id: "ma", branch: "feat-a", path: path}
    owl = Whiska.Question.FromOwl.entry(mouse, "!7", :closed, DateTime.utc_now())
    {:ok, _} = Whiska.Doorstep.leave(repo.checkout, %{owl | text: owl.text <> "\nAnd push."})

    capture_io(:stderr, fn ->
      house = open(repo, %{bin: nil}, backstop_ms: 60_000)
      House.collect(house)
    end)

    assert [_done, forged] = questions(repo)
    assert forged.asked_by == nil
  end

  test "what was read is the merge request's row under its mouse's workspace",
       %{repo: repo, path: path, forge: forge} do
    record_merge_request(repo)
    FakeGlab.answer(forge, @mr, merge_request(head_pipeline: %{"id" => 5, "status" => "running"}))
    FakeGlab.answer(forge, @discussions, [])
    quiet_herdr(path)
    test = self()

    stub(Herdr, :list_panes, fn @socket ->
      {:ok,
       [
         %{
           pane_id: "w2:p1",
           workspace_id: "w2",
           cwd: path,
           agent: "claude",
           agent_status: "idle",
           title: nil
         }
       ]}
    end)

    stub(Herdr, :workspaces, fn @socket ->
      {:ok, [%{workspace_id: "w2", path: path, linked?: true, number: 1, tokens: %{}}]}
    end)

    stub(Herdr, :report_metadata, fn @socket, ws, sent, _ttl ->
      send(test, {:reported, ws, sent["whiska_mr"]})
      :ok
    end)

    capture_io(:stderr, fn ->
      open(repo, forge, board_ms: 20, panes_ms: 20)
      assert_receive {:reported, "w2", "⎇ !7 · pipeline ◐"}, 5_000
    end)
  end

  test "a GitHub pull request is not read", %{repo: repo, path: path, forge: forge} do
    record_merge_request(repo, "https://github.com/acme/app/pull/3")
    quiet_herdr(path)

    capture_io(:stderr, fn ->
      house = open(repo, forge, [])
      Process.sleep(200)
      House.sync(house)
    end)

    assert FakeGlab.calls(forge) == []
    assert row(repo) == nil
  end

  test "the base is fetched every minute by default, measured from when a fetch starts",
       %{repo: repo, path: path, forge: forge} do
    record_merge_request(repo, "https://github.com/acme/app/pull/3")
    quiet_herdr(path)

    capture_io(:stderr, fn ->
      house = open(repo, forge, [])
      until(fn -> :sys.get_state(house).fetch_due_at != nil end)
      state = :sys.get_state(house)

      assert state.fetch_ms == 60_000
      assert state.fetch_due_at == state.fetch_started_at + 60_000
    end)
  end
end
