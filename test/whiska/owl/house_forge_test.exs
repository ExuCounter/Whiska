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
  alias Whiska.Schema.MergeRequestRead
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

    on_exit(fn -> remove(root) end)
    {:ok, repo: repo, path: path, forge: FakeGlab.create(root)}
  end

  # A git fetch or a glab the stopped house started can still be writing for a
  # moment after it, which a single rm_rf races.
  defp remove(root, tries \\ 50) do
    case File.rm_rf(root) do
      {:ok, _} ->
        :ok

      {:error, _, _} when tries > 0 ->
        Process.sleep(20)
        remove(root, tries - 1)

      {:error, reason, file} ->
        flunk("could not remove #{file}: #{inspect(reason)}")
    end
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

  defp in_house(house, fun) do
    Storage.point_at(House.repo(house))
    fun.()
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
        "source_branch" => "feat-a",
        "sha" => @head,
        "user_notes_count" => 0,
        "updated_at" => "2026-10-14T09:00:00Z",
        "head_pipeline" => nil
      },
      Map.new(fields)
    )
  end

  defp thread(id, {author_id, username}, discussion_id \\ "d0") do
    %{
      "id" => discussion_id,
      "notes" => [
        %{
          "id" => id,
          "system" => false,
          "resolvable" => true,
          "resolved" => false,
          "author" => %{"id" => author_id, "username" => username}
        }
      ]
    }
  end

  test "a new comment for a dead mouse that cannot be started is said once, and asked about",
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
        until(fn -> match?(%{review_asked_why: "start_failed"}, row(repo)) end)
        Process.sleep(100)
        House.sync(house)
      end)

    assert [_once] =
             Regex.scan(
               ~r/feat-a: review for !7 — 1 new comment by alice — starting a mouse/,
               log
             )

    assert [_once] = Regex.scan(~r/feat-a: could not start a mouse for !7's review/, log)

    assert %{pending: pending} = row(repo)

    assert %{comments: [%{id: 11, author: "alice"}]} =
             MergeRequestRead.pending(%{pending: pending})

    {:ok, handle} = Storage.open(repo.checkout, name: nil)
    asked = Enum.filter(Storage.questions_of("ma"), &(&1.asked_by == "owl"))
    Storage.close(handle)
    assert [%{status: "open", kind: "needs-decision"}] = asked
  end

  # A live mouse, idle in its own pane, with nothing in its prompt box.
  defp idle_mouse(path) do
    test = self()
    pane = %{pane_id: "w1:p1", cwd: path, agent: "claude", agent_status: "done"}

    stub(Herdr, :list_panes, fn @socket ->
      {:ok, [Map.merge(pane, %{title: nil, session: nil})]}
    end)

    stub(Herdr, :subscribe, fn @socket, _subs, _listener -> {:ok, spawn(fn -> :ok end)} end)

    stub(Herdr, :worktrees, fn @socket, _checkout ->
      {:ok, [%{path: path, branch: "feat-a", workspace_id: "ws-1"}]}
    end)

    stub(Herdr, :read_screen, fn _, _ -> {:error, :no_screen} end)
    stub(Herdr, :pane, fn _, _ -> {:error, :no_pane} end)

    stub(Herdr, :prompt, fn @socket, pane, line ->
      send(test, {:typed, pane, line})
      :ok
    end)
  end

  test "a new comment on a live idle mouse's merge request leaves it a letter and types the review line",
       %{repo: repo, path: path, forge: forge} do
    record_merge_request(repo)
    FakeGlab.answer(forge, "user", %{"id" => 1, "username" => "me"})
    FakeGlab.answer(forge, @mr, merge_request([]))
    FakeGlab.answer(forge, @discussions, [])
    idle_mouse(path)

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
        FakeGlab.answer(forge, @discussions, [thread(11, {2, "alice"}, "d11")])
        assert_receive {:typed, "w1:p1", line}, 5_000
        send(self(), {:line, line})
        House.sync(house)
      end)

    assert_received {:line, line}
    assert [letter] = Path.wildcard(Path.join(path, ".whiska-letters/*.md"))
    assert line == Whiska.ReviewRound.line(letter)
    text = File.read!(letter)
    assert text =~ @url <> "#note_11"
    assert text =~ "d11"
    assert log =~ ~r/feat-a: review for !7 — 1 new comment by alice — woke its mouse/
    assert %{pending: nil, round_at: %DateTime{}, rounds_unpushed: 0} = row(repo)
  end

  test "review kept for a busy mouse and review read in the same minute are each handed over once",
       %{repo: repo, path: path, forge: forge} do
    record_merge_request(repo)
    FakeGlab.answer(forge, "user", %{"id" => 1, "username" => "me"})
    FakeGlab.answer(forge, @mr, merge_request([]))
    FakeGlab.answer(forge, @discussions, [])
    idle_mouse(path)
    {:ok, status} = Agent.start_link(fn -> "working" end)

    stub(Herdr, :list_panes, fn @socket ->
      {:ok,
       [
         %{
           pane_id: "w1:p1",
           cwd: path,
           agent: "claude",
           agent_status: Agent.get(status, & &1),
           title: nil,
           session: nil
         }
       ]}
    end)

    kept = %{comments: [%{id: 9, author: "alice", discussion_id: "d9"}], pipeline: nil}

    capture_io(:stderr, fn ->
      house = open(repo, forge, [])
      until(fn -> match?(%{read_at: %DateTime{}}, row(repo)) end)

      in_house(house, fn ->
        :ok =
          MergeRequests.save(%{mouse_id: "ma", pending: MergeRequestRead.encode_pending(kept)})
      end)

      Process.sleep(100)

      FakeGlab.answer(
        forge,
        @mr,
        merge_request(user_notes_count: 1, updated_at: "2026-10-14T09:01:00Z")
      )

      FakeGlab.answer(forge, "projects/acme%2Fapp/members/all/2", %{"id" => 2})
      FakeGlab.answer(forge, @discussions, [thread(12, {2, "alice"}, "d12")])
      Agent.update(status, fn _ -> "done" end)

      until(fn ->
        path |> letters() |> Enum.join() |> String.contains?("#note_12")
      end)

      Process.sleep(200)
      House.sync(house)
    end)

    handed = path |> letters() |> Enum.join()
    assert [_once] = Regex.scan(~r/#note_9\b/, handed)
    assert [_once] = Regex.scan(~r/#note_12\b/, handed)
  end

  defp letters(path),
    do: path |> Path.join(".whiska-letters/*.md") |> Path.wildcard() |> Enum.map(&File.read!/1)

  test "a new comment for a dead mouse starts a review mouse in its worktree",
       %{repo: repo, path: path, forge: forge} do
    test = self()
    File.write!(Path.join(path, ".whiska-mouse"), "ma\n")
    record_merge_request(repo)
    FakeGlab.answer(forge, "user", %{"id" => 1, "username" => "me"})
    FakeGlab.answer(forge, @mr, merge_request([]))
    FakeGlab.answer(forge, @discussions, [])
    quiet_herdr(path)

    stub(Herdr, :open_worktree, fn @socket, ^path, false ->
      {:ok, %{workspace_id: "w9", pane_id: "w9:p1", already_open?: false}}
    end)

    stub(Herdr, :start_agent, fn @socket, "w9:p1", "feat-a", args -> {:ok, args} end)
    stub(Herdr, :prompt, fn @socket, "w9:p1", text -> send(test, {:kickoff, text}) && :ok end)

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
        FakeGlab.answer(forge, @discussions, [thread(11, {2, "alice"}, "d11")])
        until(fn -> match?(%{round_by: "started"}, row(repo)) end)
        House.sync(house)
      end)

    assert_received {:kickoff, "Your task:\n\n" <> line}
    assert [letter] = Path.wildcard(Path.join(path, ".whiska-letters/*.md"))
    assert line == Whiska.ReviewRound.line(letter)
    assert log =~ ~r/feat-a: review for !7 — 1 new comment by alice — starting a mouse/
    assert log =~ "feat-a: started a mouse for !7's review, in w9:p1"
    assert %{pending: nil, round_at: %DateTime{}} = row(repo)
  end

  test "after three rounds in a row that pushed nothing Whiska asks, and closing that lets the next one run",
       %{repo: repo, path: path, forge: forge} do
    record_merge_request(repo)
    FakeGlab.answer(forge, "user", %{"id" => 1, "username" => "me"})
    FakeGlab.answer(forge, @mr, merge_request([]))
    FakeGlab.answer(forge, @discussions, [])
    idle_mouse(path)

    capture_io(:stderr, fn ->
      house = open(repo, forge, [])
      until(fn -> match?(%{read_at: %DateTime{}}, row(repo)) end)

      in_house(house, fn ->
        :ok =
          MergeRequests.save(%{
            mouse_id: "ma",
            round_at: ~U[2026-10-14 08:00:00Z],
            round_by: "woke",
            round_head: @head,
            round_ref:
              GitRepo.git!(repo.checkout, ["rev-parse", "origin/feat-a"]) |> String.trim(),
            rounds_unpushed: 2
          })
      end)

      FakeGlab.answer(
        forge,
        @mr,
        merge_request(user_notes_count: 1, updated_at: "2026-10-14T09:01:00Z")
      )

      FakeGlab.answer(forge, "projects/acme%2Fapp/members/all/2", %{"id" => 2})
      FakeGlab.answer(forge, @discussions, [thread(11, {2, "alice"}, "d11")])
      until(fn -> match?(%{review_asked_why: "cap"}, row(repo)) end)
      refute_receive {:typed, _, _}, 200

      [asked] =
        in_house(house, fn -> Enum.filter(Storage.questions_of("ma"), &(&1.asked_by == "owl")) end)

      assert asked.text =~ "three rounds in a row"
      in_house(house, fn -> {:ok, _} = Storage.close_question(asked.id) end)

      assert_receive {:typed, "w1:p1", _line}, 5_000
      House.sync(house)
    end)

    assert %{review_asked_at: nil, rounds_unpushed: 0, round_by: "woke"} = row(repo)
  end

  test "a mouse the owl started that died without a word is asked about with no new review in",
       %{repo: repo, path: path, forge: forge} do
    record_merge_request(repo)
    FakeGlab.answer(forge, "user", %{"id" => 1, "username" => "me"})
    FakeGlab.answer(forge, @mr, merge_request([]))
    FakeGlab.answer(forge, @discussions, [])
    quiet_herdr(path)

    capture_io(:stderr, fn ->
      house = open(repo, forge, [])
      until(fn -> match?(%{read_at: %DateTime{}}, row(repo)) end)

      in_house(house, fn ->
        :ok =
          MergeRequests.save(%{
            mouse_id: "ma",
            round_at: DateTime.utc_now() |> DateTime.add(5) |> DateTime.truncate(:second),
            round_by: "started"
          })

        {:ok, _} = Storage.mark_dead("ma")
      end)

      until(fn -> match?(%{review_asked_why: "died"}, row(repo)) end)
      House.sync(house)
    end)

    {:ok, handle} = Storage.open(repo.checkout, name: nil)
    asked = Enum.filter(Storage.questions_of("ma"), &(&1.asked_by == "owl"))
    Storage.close(handle)
    assert [%{status: "open", text: text}] = asked
    assert text =~ "ended without asking or reporting anything"
  end

  test "Whiska's question about a review that never reached the house is asked again",
       %{repo: repo, path: path, forge: forge} do
    record_merge_request(repo)
    FakeGlab.answer(forge, "user", %{"id" => 1, "username" => "me"})
    FakeGlab.answer(forge, @mr, merge_request([]))
    FakeGlab.answer(forge, @discussions, [])
    quiet_herdr(path)
    kept = %{comments: [%{id: 9, author: "alice", discussion_id: "d9"}], pipeline: nil}
    long_ago = DateTime.utc_now() |> DateTime.add(-3600) |> DateTime.truncate(:second)

    capture_io(:stderr, fn ->
      house = open(repo, forge, [])
      until(fn -> match?(%{read_at: %DateTime{}}, row(repo)) end)

      in_house(house, fn ->
        :ok =
          MergeRequests.save(%{
            mouse_id: "ma",
            pending: MergeRequestRead.encode_pending(kept),
            round_at: long_ago,
            round_by: "woke",
            round_head: @head,
            round_ref:
              GitRepo.git!(repo.checkout, ["rev-parse", "origin/feat-a"]) |> String.trim(),
            rounds_unpushed: 2,
            review_asked_at: long_ago,
            review_asked_why: "cap"
          })
      end)

      until(fn ->
        match?(%{review_asked_at: %DateTime{} = at} when at != long_ago, row(repo))
      end)

      House.sync(house)
    end)

    {:ok, handle} = Storage.open(repo.checkout, name: nil)
    asked = Enum.filter(Storage.questions_of("ma"), &(&1.asked_by == "owl"))
    Storage.close(handle)
    assert [%{status: "open"}] = asked
  end

  test "a pipeline that fails on the head is said once",
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

    assert [_once] =
             Regex.scan(~r/feat-a: review for !7 — pipeline failed on 63c47262 — /, log)
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

  test "a close the owl saw but never asked about is asked at the next read",
       %{repo: repo, path: path, forge: forge} do
    record_merge_request(repo)
    {:ok, handle} = Storage.open(repo.checkout, name: nil)
    :ok = MergeRequests.save(%{mouse_id: "ma", url: @url, state: "closed", seen_note_id: 0})
    Storage.close(handle)
    FakeGlab.answer(forge, @mr, merge_request(state: "closed"))
    FakeGlab.answer(forge, @discussions, [])
    quiet_herdr(path)

    capture_io(:stderr, fn ->
      house = open(repo, forge, [])
      until(fn -> Enum.any?(questions(repo), &(&1.asked_by == "owl")) end)
      House.sync(house)
    end)

    assert %{asked_at: %DateTime{}} = row(repo)
  end

  test "a merge request reopened takes back the question the owl asked",
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
        until(fn -> Enum.any?(questions(repo), &(&1.asked_by == "owl")) end)
        FakeGlab.answer(forge, @mr, merge_request(state: "opened"))

        until(fn ->
          Enum.any?(questions(repo), &(&1.asked_by == "owl" and &1.status == "closed"))
        end)

        House.sync(house)
      end)

    assert log =~ "feat-a: !7 open again"
    assert File.dir?(path)
  end

  test "the owl's question collected after its worktree went is closed, not orphaned",
       %{repo: repo, path: path} do
    record_merge_request(repo)
    now = DateTime.truncate(DateTime.utc_now(), :second)
    {:ok, handle} = Storage.open(repo.checkout, name: nil)
    :ok = MergeRequests.save(%{mouse_id: "ma", url: @url, state: "closed", asked_at: now})
    mouse = Storage.mouse("ma")
    Storage.close(handle)

    {:ok, _} =
      Whiska.Doorstep.leave(
        repo.checkout,
        Whiska.Question.FromOwl.entry(mouse, "!7", :closed, now)
      )

    GitRepo.git!(repo.checkout, ["worktree", "remove", "--force", path])
    quiet_herdr(path)

    capture_io(:stderr, fn ->
      house = open(repo, %{bin: nil}, backstop_ms: 60_000)
      House.collect(house)
    end)

    assert [_done, %{asked_by: "owl", status: "closed"}] = questions(repo)
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
