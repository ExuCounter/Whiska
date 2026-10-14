defmodule Whiska.MergeRequestsTest do
  @moduledoc """
  What one read of a merge request makes of the last: the row the owl keeps,
  and what it says happened.
  """
  use ExUnit.Case, async: true

  alias Whiska.MergeRequests
  alias Whiska.Schema.MergeRequestRead
  alias Whiska.Schema.Mouse
  alias Whiska.Storage
  alias Whiska.Test.FakeGlab

  @url "https://gitlab.example.com/acme/app/-/merge_requests/7"
  @head "63c4726204434e1c2384eb0e3632940235b51ab4"
  @now ~U[2026-10-14 09:00:00Z]

  defp mouse(fields \\ []) do
    struct(
      %Mouse{
        mouse_id: "m1",
        branch: "feat-a",
        merge_request_url: @url,
        merge_request_at: ~U[2026-10-14 08:00:00Z]
      },
      fields
    )
  end

  defp snapshot(fields \\ []) do
    Map.merge(
      %{
        state: :open,
        head_sha: @head,
        pipeline: %{id: 100, status: :passed, sha: @head},
        notes_count: 3,
        updated_at: "2026-10-14T08:59:00Z",
        ready?: false
      },
      Map.new(fields)
    )
  end

  defp seen(fields \\ []) do
    Map.merge(
      %{snapshot: snapshot(), threads_open: 2, max_note_id: 30, new_comments: []},
      Map.new(fields)
    )
  end

  defp read(attrs) do
    struct(
      %MergeRequestRead{
        mouse_id: "m1",
        url: @url,
        state: "open",
        head_sha: @head,
        pipeline_id: 100,
        pipeline: "passed",
        threads_open: 2,
        notes_count: 3,
        forge_updated_at: "2026-10-14T08:59:00Z",
        seen_note_id: 30,
        missing_reads: 0,
        read_at: ~U[2026-10-14 08:59:00Z]
      },
      attrs
    )
  end

  describe "the first read" do
    test "takes everything already there as seen, so none of it counts" do
      failed = snapshot(pipeline: %{id: 101, status: :failed, sha: @head})

      {attrs, events} =
        MergeRequests.next(nil, mouse(), {:ok, seen(snapshot: failed, max_note_id: 44)}, @now)

      assert events == []
      assert attrs.mouse_id == "m1"
      assert attrs.url == @url
      assert attrs.state == "open"
      assert attrs.seen_note_id == 44
      assert attrs.seen_failed_pipeline_id == 101
      assert attrs.threads_open == 2
      assert attrs.pipeline == "failed"
      assert attrs.read_at == @now
    end

    test "with no notes at all, the cursor still starts, at nothing" do
      {attrs, []} = MergeRequests.next(nil, mouse(), {:ok, seen(max_note_id: nil)}, @now)
      assert attrs.seen_note_id == 0
    end

    test "a new link starts afresh, whatever was read for the old one" do
      old = read(url: "https://gitlab.example.com/acme/app/-/merge_requests/6", state: "closed")

      {attrs, events} =
        MergeRequests.next(old, mouse(), {:ok, seen(max_note_id: 50)}, @now)

      assert events == []
      assert attrs.url == @url
      assert attrs.seen_note_id == 50
    end
  end

  describe "a later read" do
    test "new comments are a wake, named by their authors, and move the cursor" do
      comments = [
        %{id: 31, author: "alice"},
        %{id: 32, author: "bob"},
        %{id: 33, author: "alice"}
      ]

      {attrs, events} =
        MergeRequests.next(
          read([]),
          mouse(),
          {:ok, seen(max_note_id: 33, new_comments: comments)},
          @now
        )

      assert events == [{:would_wake, %{comments: 3, authors: ["alice", "bob"], failed_on: nil}}]
      assert attrs.seen_note_id == 33
    end

    test "the cursor never moves back" do
      {attrs, []} =
        MergeRequests.next(read(seen_note_id: 40), mouse(), {:ok, seen(max_note_id: 33)}, @now)

      assert attrs.seen_note_id == 40
    end

    test "a read that did not need the notes keeps the cursor and the thread count" do
      {attrs, []} =
        MergeRequests.next(
          read(seen_note_id: 40, threads_open: 5),
          mouse(),
          {:ok, seen(max_note_id: nil, threads_open: nil)},
          @now
        )

      assert attrs.seen_note_id == 40
      assert attrs.threads_open == 5
    end

    test "a pipeline failed on the head is a wake once" do
      failed = snapshot(pipeline: %{id: 101, status: :failed, sha: @head})

      {attrs, events} = MergeRequests.next(read([]), mouse(), {:ok, seen(snapshot: failed)}, @now)
      assert events == [{:would_wake, %{comments: 0, authors: [], failed_on: "63c47262"}}]
      assert attrs.seen_failed_pipeline_id == 101

      assert {_, []} =
               MergeRequests.next(
                 read(seen_failed_pipeline_id: 101),
                 mouse(),
                 {:ok, seen(snapshot: failed)},
                 @now
               )
    end

    test "a pipeline failed on an older commit is no wake" do
      stale = snapshot(pipeline: %{id: 101, status: :failed, sha: "0000000000000000"})
      assert {_, []} = MergeRequests.next(read([]), mouse(), {:ok, seen(snapshot: stale)}, @now)
    end

    test "comments and a failure in one read are one wake" do
      failed = snapshot(pipeline: %{id: 101, status: :failed, sha: @head})

      {_, events} =
        MergeRequests.next(
          read([]),
          mouse(),
          {:ok,
           seen(snapshot: failed, new_comments: [%{id: 31, author: "alice"}], max_note_id: 31)},
          @now
        )

      assert events == [{:would_wake, %{comments: 1, authors: ["alice"], failed_on: "63c47262"}}]
    end

    test "a log line carries only a name's plain characters" do
      wake = %{comments: 1, authors: ["al\e[31mice\nfake line"], failed_on: nil}

      assert MergeRequests.line({:would_wake, wake}, "feat-a", "!7") ==
               "feat-a: would wake for !7 — 1 new comment by al31micefakeline"
    end

    test "merged and closed are said once, as the state moves" do
      {attrs, events} =
        MergeRequests.next(
          read([]),
          mouse(),
          {:ok, seen(snapshot: snapshot(state: :merged))},
          @now
        )

      assert events == [:merged]
      assert attrs.state == "merged"

      assert {_, [:closed]} =
               MergeRequests.next(
                 read([]),
                 mouse(),
                 {:ok, seen(snapshot: snapshot(state: :closed))},
                 @now
               )

      assert {_, []} =
               MergeRequests.next(
                 read(state: "closed"),
                 mouse(),
                 {:ok, seen(snapshot: snapshot(state: :closed))},
                 @now
               )
    end

    test "a merge request open again after a close is said, and may be asked about again" do
      {attrs, events} =
        MergeRequests.next(read(state: "closed", asked_at: @now), mouse(), {:ok, seen()}, @now)

      assert events == [:reopened]
      assert attrs.state == "open"
      assert attrs.asked_at == nil
    end
  end

  describe "a merge request the forge does not have" do
    test "is gone only after three reads in a row" do
      {attrs, []} = MergeRequests.next(read([]), mouse(), {:missing, true}, @now)
      assert attrs.missing_reads == 1
      assert attrs.state == "open"

      {attrs, []} = MergeRequests.next(read(missing_reads: 1), mouse(), {:missing, true}, @now)
      assert attrs.missing_reads == 2

      {attrs, [:gone]} =
        MergeRequests.next(read(missing_reads: 2), mouse(), {:missing, true}, @now)

      assert attrs.state == "gone"

      assert {_, []} =
               MergeRequests.next(
                 read(missing_reads: 3, state: "gone"),
                 mouse(),
                 {:missing, true},
                 @now
               )
    end

    test "a read that finds it again starts the count over" do
      {attrs, []} = MergeRequests.next(read(missing_reads: 2), mouse(), {:ok, seen()}, @now)
      assert attrs.missing_reads == 0
    end
  end

  describe "a read that fails" do
    test "keeps what was last read, marks when it started failing, and says so once" do
      {attrs, events} = MergeRequests.next(read([]), mouse(), {:unknown, {:http, 401}, nil}, @now)
      assert events == [{:unreadable, {:http, 401}}]
      assert attrs.unread_since == @now
      assert attrs.unread_reason == "{:http, 401}"
      refute Map.has_key?(attrs, :state)
      refute Map.has_key?(attrs, :seen_note_id)

      later = DateTime.add(@now, 120)
      failing = read(unread_since: @now, unread_reason: "{:http, 401}")

      assert {%{unread_since: @now}, []} =
               MergeRequests.next(failing, mouse(), {:unknown, :timeout, nil}, later)
    end

    test "the read after it is said as readable again" do
      failing = read(unread_since: @now, unread_reason: "timeout")
      {attrs, events} = MergeRequests.next(failing, mouse(), {:ok, seen()}, @now)

      assert events == [:readable_again]
      assert attrs.unread_since == nil
      assert attrs.unread_reason == nil
    end

    test "a first read that fails still leaves a row, with nothing read" do
      {attrs, [{:unreadable, :no_tool}]} =
        MergeRequests.next(nil, mouse(), {:unknown, :no_tool, nil}, @now)

      assert attrs.url == @url
      assert attrs.unread_since == @now
      assert attrs.read_at == nil
    end
  end

  describe "how long until the next read" do
    test "a read that worked waits the interval" do
      assert MergeRequests.wait_ms(read([]), nil, 60_000, @now) == 60_000
    end

    test "a failing one waits as long as it has been failing, up to 15 minutes" do
      failing = read(unread_since: @now)
      assert MergeRequests.wait_ms(failing, nil, 60_000, DateTime.add(@now, 10)) == 60_000
      assert MergeRequests.wait_ms(failing, nil, 60_000, DateTime.add(@now, 300)) == 300_000
      assert MergeRequests.wait_ms(failing, nil, 60_000, DateTime.add(@now, 7_200)) == 900_000
    end

    test "and never sooner than the forge asked" do
      assert MergeRequests.wait_ms(read(unread_since: @now), 1_200_000, 60_000, @now) == 1_200_000
    end

    test "up to an hour, however long the forge asked" do
      assert MergeRequests.wait_ms(nil, 1_000_000_000_000_000, 60_000, @now) == 3_600_000
    end
  end

  describe "which merge requests are read" do
    setup do
      root = Path.join(System.tmp_dir!(), "whiska-mr-#{System.unique_integer([:positive])}")
      main = Path.join(root, "repo")
      File.mkdir_p!(Path.join(main, ".git"))
      on_exit(fn -> File.rm_rf!(root) end)
      {:ok, handle} = Storage.open(main, name: nil)
      on_exit(fn -> Storage.close(handle) end)
      :ok
    end

    defp record(id, url) do
      {:ok, _} = Storage.record_mouse(%{mouse_id: id, path: "/w/#{id}", branch: id})
      if url, do: {:ok, _} = Storage.record_merge_request(id, url)
      :ok
    end

    test "a waiting GitLab link is read; no link, a GitHub link or a landed branch is not" do
      record("a", @url)
      record("b", nil)
      record("c", "https://github.com/acme/app/pull/3")
      record("d", "https://gitlab.example.com/acme/app/-/merge_requests/9")
      {:ok, _} = Storage.mark_landed("d")

      assert [{%Mouse{mouse_id: "a"}, nil}] = MergeRequests.watched()
    end

    test "a dropped branch is read while its merge request was last read open" do
      record("a", @url)
      {:ok, _} = Storage.mark_removed("a")
      assert MergeRequests.watched() == []

      :ok = MergeRequests.save(%{mouse_id: "a", url: @url, unread_since: @now})
      assert MergeRequests.watched() == []

      :ok = MergeRequests.save(%{mouse_id: "a", url: @url, state: "open"})
      assert [{_, %MergeRequestRead{state: "open"}}] = MergeRequests.watched()

      :ok = MergeRequests.save(%{mouse_id: "a", state: "closed"})
      assert MergeRequests.watched() == []
    end

    test "a row is kept per mouse, and saved over" do
      record("a", @url)
      :ok = MergeRequests.save(%{mouse_id: "a", url: @url, state: "open", seen_note_id: 3})
      :ok = MergeRequests.save(%{mouse_id: "a", seen_note_id: 9, unread_since: @now})

      assert %MergeRequestRead{url: @url, state: "open", seen_note_id: 9, unread_since: @now} =
               MergeRequests.reads()["a"]
    end
  end

  describe "reading the forge" do
    @mr "projects/acme%2Fapp/merge_requests/7"

    setup do
      root = Path.join(System.tmp_dir!(), "whiska-mr-read-#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf!(root) end)
      fake = FakeGlab.create(root)
      {:ok, fake: fake, context: MergeRequests.context(root, 5_000, %{"glab" => fake.bin})}
    end

    defp gitlab_mr(notes_count, updated_at) do
      %{
        "state" => "opened",
        "source_branch" => "feat-a",
        "sha" => @head,
        "user_notes_count" => notes_count,
        "updated_at" => updated_at,
        "head_pipeline" => nil
      }
    end

    defp thread(notes), do: %{"resolvable" => true, "resolved" => false, "notes" => notes}

    defp note(id, author_id, username, system \\ false),
      do: %{
        "id" => id,
        "system" => system,
        "author" => %{"id" => author_id, "username" => username}
      }

    defp discussions(fake, threads),
      do: FakeGlab.answer(fake, @mr <> "/discussions?per_page=100&page=1", threads)

    defp paths(fake), do: fake |> FakeGlab.calls() |> Enum.map(&List.last/1)

    test "a first read takes the notes for the cursor and asks nobody about them", ctx do
      FakeGlab.answer(ctx.fake, @mr, gitlab_mr(2, "t1"))
      discussions(ctx.fake, [thread([note(5, 2, "alice"), note(6, 3, "bob")])])

      assert {{:ok, seen}, _} = MergeRequests.read(mouse(), nil, ctx.context)
      assert seen.max_note_id == 6
      assert seen.threads_open == 1
      assert seen.new_comments == []
      assert paths(ctx.fake) == [@mr, @mr <> "/discussions?per_page=100&page=1"]
    end

    test "nothing moved and no thread open, so the discussions are not read", ctx do
      FakeGlab.answer(ctx.fake, @mr, gitlab_mr(3, "2026-10-14T08:59:00Z"))

      assert {{:ok, %{max_note_id: nil, threads_open: nil}}, _} =
               MergeRequests.read(mouse(), read(threads_open: 0), ctx.context)

      assert paths(ctx.fake) == [@mr]
    end

    test "open threads are read again though nothing moved, so one resolved is seen", ctx do
      FakeGlab.answer(ctx.fake, @mr, gitlab_mr(3, "2026-10-14T08:59:00Z"))
      discussions(ctx.fake, [])

      assert {{:ok, %{threads_open: 0}}, _} = MergeRequests.read(mouse(), read([]), ctx.context)
    end

    test "a merge request from another branch is not this mouse's, so nothing more is read",
         ctx do
      FakeGlab.answer(ctx.fake, @mr, Map.put(gitlab_mr(2, "t1"), "source_branch", "feat-b"))

      assert {{:unknown, :other_branch, nil}, _} = MergeRequests.read(mouse(), nil, ctx.context)
      assert paths(ctx.fake) == [@mr]
    end

    test "discussions in a shape it does not know count for nothing, and the read stands", ctx do
      FakeGlab.answer(ctx.fake, @mr, gitlab_mr(2, "t1"))

      discussions(ctx.fake, [
        1,
        "x",
        %{"resolvable" => true, "notes" => [1, %{"id" => "y"}]},
        thread([note(5, 2, "alice")])
      ])

      assert {{:ok, seen}, _} = MergeRequests.read(mouse(), nil, ctx.context)
      assert seen.threads_open == 2
      assert seen.max_note_id == 5
    end

    test "a forge that asks to wait is not called again in the same round", ctx do
      FakeGlab.answer(ctx.fake, @mr, %{}, status: 429, headers: %{"Retry-After" => "120"})

      other =
        mouse(
          mouse_id: "m2",
          branch: "feat-b",
          merge_request_url: "https://gitlab.example.com/acme/app/-/merge_requests/8"
        )

      waited = {:unknown, {:http, 429}, 120_000}

      assert {[{_, nil, ^waited}, {%Mouse{mouse_id: "m2"}, nil, ^waited}], _} =
               MergeRequests.read_each([{mouse(), nil}, {other, nil}], ctx.context)

      assert paths(ctx.fake) == [@mr]
    end

    test "only a member's new comment counts: never a system note, the account's own, or an outsider's",
         ctx do
      FakeGlab.answer(ctx.fake, @mr, gitlab_mr(8, "t2"))

      discussions(ctx.fake, [
        thread([note(29, 2, "alice"), note(31, 2, "alice"), note(32, 1, "me")]),
        thread([note(33, 9, "drive-by"), note(34, 2, "alice", true), note(35, 3, "bob")])
      ])

      FakeGlab.answer(ctx.fake, "user", %{"id" => 1, "username" => "me"})
      FakeGlab.answer(ctx.fake, "projects/acme%2Fapp/members/all/2", %{"id" => 2})
      FakeGlab.answer(ctx.fake, "projects/acme%2Fapp/members/all/3", %{"id" => 3})

      assert {{:ok, seen}, context} = MergeRequests.read(mouse(), read([]), ctx.context)

      assert seen.new_comments == [
               %{id: 31, author: "alice"},
               %{id: 35, author: "bob"}
             ]

      assert seen.max_note_id == 35
      assert context.members[{"gitlab.example.com", "acme/app", 9}] == false
      assert context.me["gitlab.example.com"] == %{id: 1, username: "me"}
    end

    test "the account and membership are asked once, then remembered", ctx do
      FakeGlab.answer(ctx.fake, @mr, gitlab_mr(8, "t2"))
      discussions(ctx.fake, [thread([note(31, 2, "alice")])])
      FakeGlab.answer(ctx.fake, "user", %{"id" => 1, "username" => "me"})
      FakeGlab.answer(ctx.fake, "projects/acme%2Fapp/members/all/2", %{"id" => 2})

      {{:ok, _}, context} = MergeRequests.read(mouse(), read([]), ctx.context)
      {{:ok, seen}, _} = MergeRequests.read(mouse(), read([]), context)

      assert seen.new_comments == [%{id: 31, author: "alice"}]
      asked = paths(ctx.fake)
      assert Enum.count(asked, &(&1 == "user")) == 1
      assert Enum.count(asked, &String.ends_with?(&1, "members/all/2")) == 1
    end

    test "membership that cannot be read makes the read unknown, so the cursor stays", ctx do
      FakeGlab.answer(ctx.fake, @mr, gitlab_mr(8, "t2"))
      discussions(ctx.fake, [thread([note(31, 2, "alice")])])
      FakeGlab.answer(ctx.fake, "user", %{"id" => 1, "username" => "me"})
      FakeGlab.answer(ctx.fake, "projects/acme%2Fapp/members/all/2", %{}, status: 503)

      assert {{:unknown, {:http, 503}, nil}, _} =
               MergeRequests.read(mouse(), read([]), ctx.context)
    end

    test "a 404 is missing only while the project still reads", ctx do
      assert {{:unknown, :project_unreadable, nil}, _} =
               MergeRequests.read(mouse(), read([]), ctx.context)

      FakeGlab.answer(ctx.fake, "projects/acme%2Fapp", %{"id" => 4})
      assert {{:missing, true}, _} = MergeRequests.read(mouse(), read([]), ctx.context)
    end
  end
end
