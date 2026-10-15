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
    root = Path.join(System.tmp_dir!(), "whiska-gitlab-#{Whiska.Test.Unique.id()}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    fake = FakeGlab.create(root)
    {:ok, ref} = GitLab.parse(@url)
    {:ok, fake: fake, ref: ref, run: %{tool: fake.bin, cwd: root, timeout_ms: 60_000}}
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
             ready?: false,
             blocker: :rebase,
             merging: nil
           }
  end

  test "GitLab's auto-merge flags and its locked state say the request is merging",
       %{fake: fake} = ctx do
    for {fields, merging} <- [
          {%{}, nil},
          {%{"merge_when_pipeline_succeeds" => true}, :auto},
          {%{"auto_merge_enabled" => true}, :auto},
          {%{"auto_merge_enabled" => false, "merge_when_pipeline_succeeds" => false}, nil},
          {%{"state" => "locked"}, :now},
          {%{"state" => "locked", "auto_merge_enabled" => true}, :now},
          {%{"state" => "merged", "auto_merge_enabled" => true}, nil},
          {%{"state" => "closed", "merge_when_pipeline_succeeds" => true}, nil}
        ] do
      FakeGlab.answer(fake, @mr, merge_request(fields))
      assert {:ok, %{merging: ^merging}} = GitLab.merge_request(ctx.ref, ctx.run)
    end
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

  test "why GitLab will not merge folds into one blocker, or none the pipeline already says",
       %{fake: fake} = ctx do
    for {gitlab, ours} <- [
          {"mergeable", nil},
          {"not_approved", :approval},
          {"conflict", :conflict},
          {"draft_status", :draft},
          {"discussions_not_resolved", :threads},
          {"need_rebase", :rebase},
          {"requested_changes", nil},
          {"ci_must_pass", nil},
          {"ci_still_running", nil},
          {"checking", nil},
          {"unchecked", nil},
          {"approvals_syncing", nil},
          {"preparing", nil},
          {"not_open", nil},
          {"commits_status", :blocked},
          {"merge_request_blocked", :blocked},
          {"merge_time", :blocked},
          {"jira_association_missing", :blocked},
          {"security_policy_pipeline_check", :blocked},
          {"security_policy_violations", :blocked},
          {"status_checks_must_pass", :blocked},
          {"locked_paths", :blocked},
          {"locked_lfs_files", :blocked},
          {"title_regex", :blocked},
          {"a_status_gitlab_adds_later", :blocked},
          {nil, nil}
        ] do
      FakeGlab.answer(fake, @mr, merge_request(%{"detailed_merge_status" => gitlab}))
      assert {:ok, %{blocker: ^ours}} = GitLab.merge_request(ctx.ref, ctx.run)
    end
  end

  test "a merge request GitLab does not have is missing, and a refusal unknown",
       %{fake: fake} = ctx do
    assert :missing = GitLab.merge_request(ctx.ref, ctx.run)

    FakeGlab.answer(fake, @mr, %{"message" => "401 Unauthorized"}, status: 401)
    assert {:unknown, {:http, 401}, nil} = GitLab.merge_request(ctx.ref, ctx.run)

    FakeGlab.answer(fake, @mr, %{"no" => "state"})
    assert {:unknown, :unreadable_merge_request, nil} = GitLab.merge_request(ctx.ref, ctx.run)
  end

  test "a number past what the house can store is unreadable, never kept", %{fake: fake} = ctx do
    FakeGlab.answer(fake, @mr, merge_request(%{"user_notes_count" => 2 ** 70}))
    assert {:unknown, :unreadable_merge_request, nil} = GitLab.merge_request(ctx.ref, ctx.run)

    FakeGlab.answer(
      fake,
      @mr,
      merge_request(%{"head_pipeline" => %{pipeline("failed") | "id" => 2 ** 70}})
    )

    assert {:ok, %{pipeline: nil}} = GitLab.merge_request(ctx.ref, ctx.run)

    FakeGlab.answer(fake, @mr <> "/discussions?per_page=100&page=1", [
      discussion("d1", true, false, [
        note(2 ** 70, 2, "alice"),
        note(11, 2 ** 70, "bob"),
        note(12, 2, "alice")
      ])
    ])

    assert {:ok, %{notes: [%{id: 12}]}} = GitLab.notes(ctx.ref, ctx.run)
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

    assert Enum.map(notes, &{&1.id, &1.author_id, &1.author, &1.system?, &1.discussion_id}) == [
             {11, 2, "alice", false, "d1"},
             {12, 1, "me", false, "d1"},
             {13, 3, "bob", false, "d2"},
             {14, 2, "alice", true, "d3"},
             {15, 4, "group_1_bot_abc", false, "d4"}
           ]
  end

  test "a thread's id is kept only as letters and digits", %{fake: fake} = ctx do
    FakeGlab.answer(fake, @mr <> "/discussions?per_page=100&page=1", [
      discussion("ab12", true, false, [note(11, 2, "alice")]),
      discussion("x; rm -rf /", true, false, [note(12, 2, "alice")]),
      %{"notes" => [note(13, 2, "alice")]}
    ])

    assert {:ok, %{notes: notes}} = GitLab.notes(ctx.ref, ctx.run)
    assert Enum.map(notes, &{&1.id, &1.discussion_id}) == [{11, "ab12"}, {12, nil}, {13, nil}]
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

  @project %{forge: GitLab, host: "gitlab.example.com", project: "acme/tools/app"}
  @lookup "projects/acme%2Ftools%2Fapp/merge_requests"

  test "a merge request open from a branch is found by one GET, one into its base first",
       %{fake: fake} = ctx do
    other = "https://gitlab.example.com/acme/tools/app/-/merge_requests/8"

    FakeGlab.answer(fake, @lookup, [
      opened(other, "fix/a b", "release/x"),
      opened(@url, "fix/a b", "staging")
    ])

    assert GitLab.open_from(@project, "fix/a b", "staging", ctx.run) == {:ok, @url}

    assert [
             [
               "api",
               "--method",
               "GET",
               "--include",
               "--hostname",
               "gitlab.example.com",
               @lookup <> "?source_branch=fix%2Fa%20b&state=opened"
             ]
           ] = FakeGlab.calls(fake)

    FakeGlab.answer(fake, @lookup, [opened(other, "fix/a b", "release/x")])

    assert GitLab.open_from(@project, "fix/a b", "staging", ctx.run) == {:ok, other}
    assert GitLab.open_from(@project, "fix/a b", nil, ctx.run) == {:ok, other}

    upper = %{@project | host: "GitLab.example.com", project: "Acme/Tools/App"}
    assert GitLab.open_from(upper, "fix/a b", "staging", ctx.run) == {:ok, other}
  end

  test "a merge request from another branch, from a fork, or on another project, is none",
       %{fake: fake} = ctx do
    for other <- [
          %{"source_branch" => "feat-b"},
          %{"source_project_id" => 99},
          %{"source_project_id" => nil},
          %{"web_url" => "https://gitlab.example.com/acme/other/-/merge_requests/7"},
          %{"web_url" => "https://evil.example.com/acme/tools/app/-/merge_requests/7"},
          %{"web_url" => "javascript:alert(1)"}
        ] do
      found =
        Map.merge(
          opened(@url, "feat-a", "staging"),
          other
        )

      FakeGlab.answer(fake, @lookup, [found])
      assert GitLab.open_from(@project, "feat-a", "staging", ctx.run) == {:ok, nil}
    end

    FakeGlab.answer(fake, @lookup, [])
    assert GitLab.open_from(@project, "feat-a", "staging", ctx.run) == {:ok, nil}
    FakeGlab.answer(fake, @lookup, %{"message" => "oops"})
    assert {:unknown, _, _} = GitLab.open_from(@project, "feat-a", "staging", ctx.run)
    FakeGlab.answer(fake, @lookup, %{"message" => "401"}, status: 401)

    assert {:unknown, {:http, 401}, nil} =
             GitLab.open_from(@project, "feat-a", "staging", ctx.run)
  end

  test "a project is read off origin only when it is on GitLab", ctx do
    checkout = Path.join(ctx.run.cwd, "checkout")
    File.mkdir_p!(checkout)
    System.cmd("git", ["init", "--quiet", checkout])

    for {url, expected} <- [
          {"git@gitlab.com:prosapient/platform/platform/platform-backend.git",
           {"gitlab.com", "prosapient/platform/platform/platform-backend"}},
          {"https://gitlab.example.com/acme/app.git", {"gitlab.example.com", "acme/app"}},
          {"ssh://git@gitlab.example.com:2222/acme/app", {"gitlab.example.com", "acme/app"}},
          {"https://gitlab.example.com:8443/acme/app.git",
           {"gitlab.example.com:8443", "acme/app"}},
          {"git@github.com:acme/app.git", nil},
          {"git@github.com:acme/gitlab-ci-templates.git", nil},
          {"/tmp/bare.git", nil}
        ] do
      System.cmd("git", ["remote", "remove", "origin"], cd: checkout, stderr_to_stdout: true)
      System.cmd("git", ["remote", "add", "origin", url], cd: checkout)

      case expected do
        {host, project} ->
          assert Forge.origin_project(checkout) ==
                   {:ok, %{forge: GitLab, host: host, project: project}}

        nil ->
          assert Forge.origin_project(checkout) == :error
      end
    end
  end

  defp opened(url, branch, base) do
    %{
      "web_url" => url,
      "source_branch" => branch,
      "target_branch" => base,
      "source_project_id" => 12,
      "target_project_id" => 12
    }
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
      "notes" =>
        Enum.map(notes, &Map.merge(&1, %{"resolvable" => resolvable, "resolved" => resolved}))
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
