defmodule Whiska.Forge.GitLabTest do
  @moduledoc """
  Reading a GitLab merge request through `glab api`, against a fake `glab`
  answering bodies shaped as GitLab's API documents them.
  """
  use ExUnit.Case, async: true

  alias Whiska.Forge
  alias Whiska.Forge.GitLab
  alias Whiska.Test.FakeGlab

  @url "https://gitlab.example.com/acme/tools/app/-/merge_requests/7"
  @mr "projects/acme%2Ftools%2Fapp/merge_requests/7"

  setup do
    root = Path.join(System.tmp_dir!(), "whiska-gitlab-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    fake = FakeGlab.create(root)
    {:ok, ref} = GitLab.parse(@url)
    {:ok, fake: fake, ref: ref, run: %{tool: fake.bin, cwd: root, timeout_ms: 5_000}}
  end

  test "a merge request link is its host, project and number" do
    assert {:ok, ref} = GitLab.parse(@url)
    assert ref.forge == GitLab
    assert ref.host == "gitlab.example.com"
    assert ref.project == "acme/tools/app"
    assert ref.number == 7
    assert ref.url == @url
    assert GitLab.label(ref) == "!7"

    assert {:ok, %{number: 7}} = GitLab.parse(@url <> "/")
  end

  test "anything but a merge request link is not one" do
    for url <- [
          "https://gitlab.com/acme/app/-/issues/7",
          "https://gitlab.com/acme/app/-/merge_requests/7/diffs",
          "https://github.com/acme/app/pull/7",
          "http://gitlab.com/acme/app/-/merge_requests/7",
          "https://gitlab.com/-/merge_requests/7",
          "https://-gitlab.com/acme/app/-/merge_requests/7",
          "https://.gitlab.com/acme/app/-/merge_requests/7"
        ],
        do: assert(GitLab.parse(url) == :error)
  end

  test "the merge request reads as its state, head, pipeline and notes", %{fake: fake} = ctx do
    FakeGlab.answer(fake, @mr, merge_request())

    assert {:ok, snapshot} = GitLab.merge_request(ctx.ref, ctx.run)

    assert snapshot == %{
             state: :open,
             head_sha: "63c4726204434e1c2384eb0e3632940235b51ab4",
             pipeline: %{
               id: 2_943_542_884,
               status: :passed,
               sha: "63c4726204434e1c2384eb0e3632940235b51ab4"
             },
             notes_count: 11,
             updated_at: "2026-10-13T17:31:14.238Z",
             source_branch: "feat-a",
             ready?: false
           }
  end

  test "GitLab's states and pipeline statuses fold into Whiska's few", %{fake: fake} = ctx do
    for {gitlab, ours} <- [
          {"opened", :open},
          {"locked", :open},
          {"merged", :merged},
          {"closed", :closed}
        ] do
      FakeGlab.answer(fake, @mr, merge_request(%{"state" => gitlab}))
      assert {:ok, %{state: ^ours}} = GitLab.merge_request(ctx.ref, ctx.run)
    end

    for {gitlab, ours} <- [
          {"success", :passed},
          {"failed", :failed},
          {"running", :running},
          {"pending", :running},
          {"created", :running},
          {"canceled", :other},
          {"skipped", :other}
        ] do
      FakeGlab.answer(fake, @mr, merge_request(%{"head_pipeline" => pipeline(gitlab)}))
      assert {:ok, %{pipeline: %{status: ^ours}}} = GitLab.merge_request(ctx.ref, ctx.run)
    end

    FakeGlab.answer(fake, @mr, merge_request(%{"head_pipeline" => nil}))
    assert {:ok, %{pipeline: nil}} = GitLab.merge_request(ctx.ref, ctx.run)

    FakeGlab.answer(fake, @mr, merge_request(%{"detailed_merge_status" => "mergeable"}))
    assert {:ok, %{ready?: true}} = GitLab.merge_request(ctx.ref, ctx.run)
  end

  test "a merge request GitLab does not have is missing, and a refusal unknown",
       %{fake: fake} = ctx do
    assert :missing = GitLab.merge_request(ctx.ref, ctx.run)

    FakeGlab.answer(fake, @mr, %{"message" => "401 Unauthorized"}, status: 401)
    assert {:unknown, {:http, 401}, nil} = GitLab.merge_request(ctx.ref, ctx.run)

    FakeGlab.answer(fake, @mr, %{"no" => "state"})
    assert {:unknown, :unreadable_merge_request, nil} = GitLab.merge_request(ctx.ref, ctx.run)
  end

  test "the discussions are read page by page into open threads and notes", %{fake: fake} = ctx do
    FakeGlab.answer(
      fake,
      @mr <> "/discussions?per_page=100&page=1",
      [
        discussion("d1", true, false, [note(11, 2, "alice"), note(12, 1, "me")]),
        discussion("d2", true, true, [note(13, 3, "bob")])
      ],
      headers: %{"X-Next-Page" => "2"}
    )

    FakeGlab.answer(
      fake,
      @mr <> "/discussions?per_page=100&page=2",
      [
        discussion("d3", false, false, [note(14, 2, "alice", system: true)]),
        discussion("d4", true, false, [note(15, 4, "group_1_bot_abc")])
      ],
      headers: %{"X-Next-Page" => ""}
    )

    assert {:ok, %{threads_open: 2, notes: notes}} = GitLab.notes(ctx.ref, ctx.run)

    assert Enum.map(notes, &{&1.id, &1.author_id, &1.author, &1.system?}) == [
             {11, 2, "alice", false},
             {12, 1, "me", false},
             {13, 3, "bob", false},
             {14, 2, "alice", true},
             {15, 4, "group_1_bot_abc", false}
           ]
  end

  test "a page that cannot be read makes the whole read unknown", %{fake: fake} = ctx do
    FakeGlab.answer(fake, @mr <> "/discussions?per_page=100&page=1", [],
      headers: %{"X-Next-Page" => "2"}
    )

    FakeGlab.answer(fake, @mr <> "/discussions?per_page=100&page=2", %{}, status: 502)

    assert {:unknown, {:http, 502}, nil} = GitLab.notes(ctx.ref, ctx.run)
  end

  test "membership, the signed-in account and the project are read", %{fake: fake} = ctx do
    FakeGlab.answer(fake, "projects/acme%2Ftools%2Fapp/members/all/2", %{"id" => 2})
    assert {:ok, true} = GitLab.member?(ctx.ref, 2, ctx.run)
    assert {:ok, false} = GitLab.member?(ctx.ref, 3, ctx.run)

    FakeGlab.answer(fake, "user", %{"id" => 1, "username" => "me", "bot" => false})
    assert {:ok, %{id: 1, username: "me"}} = GitLab.me(ctx.ref, ctx.run)

    assert {:ok, false} = GitLab.project_readable?(ctx.ref, ctx.run)
    FakeGlab.answer(fake, "projects/acme%2Ftools%2Fapp", %{"id" => 99})
    assert {:ok, true} = GitLab.project_readable?(ctx.ref, ctx.run)
  end

  test "every call it made was a GET on the merge request's own host", %{fake: fake} = ctx do
    FakeGlab.answer(fake, @mr, merge_request())
    GitLab.merge_request(ctx.ref, ctx.run)
    GitLab.notes(ctx.ref, ctx.run)
    GitLab.member?(ctx.ref, 2, ctx.run)

    for call <- FakeGlab.calls(fake),
        do:
          assert(
            ["api", "--method", "GET", "--include", "--hostname", "gitlab.example.com", _] = call
          )
  end

  test "the forge for a link is picked by its shape" do
    assert {:ok, %{forge: GitLab, number: 7}} = Forge.for_url(@url)

    assert {:ok, %{forge: Forge.GitHub, number: 12} = github} =
             Forge.for_url("https://github.com/acme/app/pull/12")

    assert Forge.label(github) == "#12"
    assert Forge.reads?(github) == false
    assert Forge.for_url("https://example.com/whatever") == :error
  end

  defp merge_request(overrides \\ %{}) do
    Map.merge(
      %{
        "iid" => 7,
        "state" => "opened",
        "source_branch" => "feat-a",
        "sha" => "63c4726204434e1c2384eb0e3632940235b51ab4",
        "updated_at" => "2026-10-13T17:31:14.238Z",
        "user_notes_count" => 11,
        "detailed_merge_status" => "need_rebase",
        "head_pipeline" => pipeline("success")
      },
      overrides
    )
  end

  defp pipeline(status) do
    %{
      "id" => 2_943_542_884,
      "status" => status,
      "sha" => "63c4726204434e1c2384eb0e3632940235b51ab4"
    }
  end

  defp discussion(id, resolvable, resolved, notes) do
    %{
      "id" => id,
      "individual_note" => false,
      "resolvable" => resolvable,
      "resolved" => resolved,
      "notes" => notes
    }
  end

  defp note(id, author_id, username, opts \\ []) do
    %{
      "id" => id,
      "system" => Keyword.get(opts, :system, false),
      "author" => %{"id" => author_id, "username" => username}
    }
  end
end
