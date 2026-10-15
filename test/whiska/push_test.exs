defmodule Whiska.PushTest do
  @moduledoc """
  `whiska push` through the CLI, over a real git repo and its bare remote, with
  a fake `glab` first on PATH: the branch is pushed, each reply the mouse wrote
  is posted to its thread, and the mouse's question is answered with what was
  done.
  """
  # Serial: the house opens under the one VM-wide name `Whiska.Repo`, and the
  # test puts a fake `glab` first on the OS PATH and sets HERDR_SOCKET_PATH.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import Mox

  alias Whiska.CLI
  alias Whiska.Herdr.Mock, as: Herdr
  alias Whiska.Storage
  alias Whiska.Test.FakeGlab
  alias Whiska.Test.GitRepo

  setup :verify_on_exit!

  @socket "/fake/herdr.sock"
  @mr "https://gitlab.example.com/g/p/-/merge_requests/7"
  @api "projects/g%2Fp/merge_requests/7/discussions"
  @a String.duplicate("a1", 20)
  @b String.duplicate("b2", 20)

  setup do
    root = Path.join(System.tmp_dir!(), "whiska-push-#{Whiska.Test.Unique.id()}")
    repo = GitRepo.create(root)
    path = GitRepo.worktree(repo, "feat-a")
    fake = FakeGlab.create(root)

    was = {System.get_env("PATH"), System.get_env("HERDR_SOCKET_PATH")}
    System.put_env("PATH", fake.dir <> ":" <> elem(was, 0))
    System.put_env("HERDR_SOCKET_PATH", @socket)
    stub(Herdr, :prompt, fn @socket, "w1:p1", _line -> :ok end)

    id =
      Storage.within(repo.checkout, fn ->
        {:ok, _} =
          Storage.record_mouse(%{mouse_id: "m1", path: path, branch: "feat-a", pane: "w1:p1"})

        {:ok, _} = Storage.record_merge_request("m1", @mr)

        {:ok, q} =
          Storage.record_question(%{
            mouse_id: "m1",
            text: "# Ready to push\n\nTwo threads answered.\n⁣⁣",
            kind: "needs-decision",
            status: "sent"
          })

        to_string(q.id)
      end)

    on_exit(fn ->
      {path_was, socket_was} = was
      System.put_env("PATH", path_was)

      if socket_was,
        do: System.put_env("HERDR_SOCKET_PATH", socket_was),
        else: System.delete_env("HERDR_SOCKET_PATH")

      File.rm_rf!(root)
    end)

    {:ok, repo: repo, path: path, id: id, fake: fake}
  end

  defp push(id, repo) do
    parent = self()

    err =
      capture_io(:stderr, fn ->
        out = capture_io(fn -> send(parent, {:code, CLI.run(["push", id], repo.checkout)}) end)
        send(parent, {:out, out})
      end)

    assert_received {:code, code}
    assert_received {:out, out}
    {code, out, err}
  end

  defp reply!(path, name, text) do
    file = Path.join([path, ".whiska-replies", name])
    File.mkdir_p!(Path.dirname(file))
    File.write!(file, text)
  end

  defp thread(fake, id, author, body) do
    FakeGlab.answer(fake, "#{@api}/#{id}", %{
      "id" => id,
      "notes" => [
        %{"id" => 900, "author" => %{"id" => 3, "username" => author}, "body" => body},
        %{"id" => 901, "author" => %{"id" => 4, "username" => "vova"}, "body" => "later"}
      ]
    })
  end

  defp posted(fake, id),
    do: FakeGlab.answer(fake, "#{@api}/#{id}/notes", %{"id" => 1000}, status: 201)

  defp resolved(fake, id), do: FakeGlab.answer(fake, "#{@api}/#{id}?resolved=true", %{})

  # The calls that write, each without the temporary file `--input` names.
  defp writes(fake) do
    for call <- FakeGlab.calls(fake), "GET" not in call do
      Enum.reject(call, &String.starts_with?(&1, System.tmp_dir!()))
    end
  end

  defp on_remote(repo, branch),
    do: GitRepo.git!(repo.remote, ["rev-parse", "--verify", "--quiet", "refs/heads/#{branch}"])

  defp head(path), do: GitRepo.git!(path, ["rev-parse", "HEAD"])

  test "pushes, posts each reply to its thread, resolves the marked one, and moves both to posted",
       ctx do
    reply!(ctx.path, "#{@a}.resolve.md", "Fixed: the date column sorts now.")
    reply!(ctx.path, "#{@b}.md", "Keeping it: Chrome blocks alert() here.")
    thread(ctx.fake, @a, "coderabbitai", "The date column \e[31mdoes not\e[0m sort.")
    thread(ctx.fake, @b, "alice", "Remove the beforeunload clear?")
    posted(ctx.fake, @a)
    resolved(ctx.fake, @a)
    posted(ctx.fake, @b)
    GitRepo.commit!(ctx.path, "fix.md", "fix")

    assert {0, out, _} = push(ctx.id, ctx.repo)

    assert on_remote(ctx.repo, "feat-a") == head(ctx.path)

    json = ~w(--header Content-Type:application/json --input)

    assert writes(ctx.fake) == [
             ~w(api --method POST --hostname gitlab.example.com) ++
               json ++ ["#{@api}/#{@a}/notes"],
             ~w(api --method PUT --hostname gitlab.example.com #{@api}/#{@a}?resolved=true),
             ~w(api --method POST --hostname gitlab.example.com) ++
               json ++ ["#{@api}/#{@b}/notes"]
           ]

    replies = Path.join(ctx.path, ".whiska-replies")
    assert File.ls!(replies) |> Enum.sort() == ["posted", "posting"]
    assert File.ls!(Path.join(replies, "posting")) == []
    assert replies |> Path.join("posted") |> File.ls!() |> length() == 2

    assert out =~ String.slice(head(ctx.path), 0, 8)
    assert out =~ "the forge's words"
    assert out =~ "The date column does not sort."
    refute out =~ "\e["
    assert out =~ "by coderabbitai"
    assert out =~ "#{@mr}#note_900"
    assert out =~ "Fixed: the date column sorts now."
    assert out =~ "resolved"

    Storage.within(ctx.repo.checkout, fn ->
      assert %{status: "answered", answer: answer} = Storage.question(String.to_integer(ctx.id))
      assert answer =~ "Fixed: the date column sorts now."
      assert answer =~ "Keeping it: Chrome blocks alert() here."
      assert answer =~ "#{@mr}#note_900"
      refute answer =~ "does not"
      refute answer =~ "beforeunload clear?"
    end)
  end

  test "each reply's body reaches the forge as a JSON string, whatever the file holds", ctx do
    reply!(ctx.path, "#{@a}.md", "true")
    thread(ctx.fake, @a, "alice", "?")
    posted(ctx.fake, @a)
    bin = Path.join(ctx.fake.dir, "glab")
    real = File.read!(bin)

    # Keep what `--input` named before the command removes it.
    File.write!(
      bin,
      String.replace(
        real,
        "#!/bin/sh\n",
        "#!/bin/sh\nprev=\"\"; for a in \"$@\"; do [ \"$prev\" = --input ] && cp \"$a\" '#{ctx.fake.dir}/body'; prev=\"$a\"; done\n",
        global: false
      )
    )

    assert {0, _, _} = push(ctx.id, ctx.repo)
    assert JSON.decode!(File.read!(Path.join(ctx.fake.dir, "body"))) == %{"body" => "true"}
  end

  test "a line GitLab would run as a quick action is escaped, so it posts as text", ctx do
    reply!(ctx.path, "#{@a}.md", "Fixed.\n/merge\n  /approve now\n\r/close\n\u200B/label x")
    thread(ctx.fake, @a, "alice", "?")
    posted(ctx.fake, @a)
    bin = Path.join(ctx.fake.dir, "glab")

    File.write!(
      bin,
      String.replace(
        File.read!(bin),
        "#!/bin/sh\n",
        "#!/bin/sh\nprev=\"\"; for a in \"$@\"; do [ \"$prev\" = --input ] && cp \"$a\" '#{ctx.fake.dir}/body'; prev=\"$a\"; done\n",
        global: false
      )
    )

    assert {0, _, _} = push(ctx.id, ctx.repo)

    assert JSON.decode!(File.read!(Path.join(ctx.fake.dir, "body"))) ==
             %{"body" => "Fixed.\n\\/merge\n  \\/approve now\n\n\\/close\n\u200B\\/label x"}
  end

  test "a reply that is not UTF-8, a hard link or a thread id GitLab never makes is not posted, and the rest are",
       ctx do
    reply!(ctx.path, "#{@a}.md", <<"Fix", 255>>)
    reply!(ctx.path, "#{@b}.md", "Answered.")
    reply!(ctx.path, "123.md", "?")
    secret = Path.join(ctx.repo.root, "secret")
    File.write!(secret, "token")
    c = String.duplicate("c3", 20)
    File.ln!(secret, Path.join(ctx.path, ".whiska-replies/#{c}.md"))
    thread(ctx.fake, @b, "bob", "?")
    posted(ctx.fake, @b)

    assert {0, out, _} = push(ctx.id, ctx.repo)
    assert [[_, _, "POST" | _]] = writes(ctx.fake)
    assert out =~ "#{@a}.md was not posted: not UTF-8 text"
    assert out =~ "#{c}.md was not posted: not a plain file"
    assert out =~ "123.md was not posted: not a !7 thread id"
    refute out =~ "token"

    for name <- ["#{@a}.md", "#{c}.md", "123.md"],
        do: assert(File.exists?(Path.join(ctx.path, ".whiska-replies/#{name}")))
  end

  test "a reply left in posting/ by a run that stopped is named, never posted again", ctx do
    reply!(ctx.path, "posting/#{@a}.md", "Fixed.")

    assert {0, out, _} = push(ctx.id, ctx.repo)
    assert writes(ctx.fake) == []
    assert out =~ "posting/#{@a}.md was not posted"
    assert out =~ "move it back to post it again"
  end

  test "a reply folder that is a link is not read", ctx do
    outside = Path.join(ctx.repo.root, "outside")
    File.mkdir_p!(outside)
    File.write!(Path.join(outside, "#{@a}.md"), "token")
    File.ln_s!(outside, Path.join(ctx.path, ".whiska-replies"))

    assert {0, out, _} = push(ctx.id, ctx.repo)
    assert writes(ctx.fake) == []
    assert File.ls!(outside) == ["#{@a}.md"]
    refute out =~ "token"
  end

  test "a reply posted whose thread would not resolve says to resolve it on the forge", ctx do
    reply!(ctx.path, "#{@a}.resolve.md", "Fixed.")
    thread(ctx.fake, @a, "alice", "?")
    posted(ctx.fake, @a)
    FakeGlab.answer(ctx.fake, "#{@api}/#{@a}?resolved=true", %{}, status: 403)

    assert {0, out, _} = push(ctx.id, ctx.repo)
    assert out =~ "replied, but not resolved"
    assert out =~ "resolve it on the forge"
  end

  test "Whiska's own question is refused, before anything is pushed", ctx do
    Storage.within(ctx.repo.checkout, fn ->
      Whiska.Repo.update_all(Whiska.Schema.Question, set: [asked_by: "owl"])
    end)

    GitRepo.commit!(ctx.path, "fix.md", "fix")
    assert {1, _, err} = push(ctx.id, ctx.repo)
    assert err =~ "Whiska's own question"
    refute on_remote(ctx.repo, "feat-a") == head(ctx.path)
  end

  test "a dead mouse is refused, before anything is pushed", ctx do
    Storage.within(ctx.repo.checkout, fn ->
      Whiska.Repo.update_all(Whiska.Schema.Mouse, set: [died_at: DateTime.utc_now(:second)])
    end)

    GitRepo.commit!(ctx.path, "fix.md", "fix")
    assert {1, _, err} = push(ctx.id, ctx.repo)
    assert err =~ "is dead"
    refute on_remote(ctx.repo, "feat-a") == head(ctx.path)
  end

  test "a branch rewritten by a squash is pushed with a lease", ctx do
    GitRepo.git!(ctx.path, ["commit", "--amend", "-m", "squashed"])
    assert {0, _, _} = push(ctx.id, ctx.repo)
    assert on_remote(ctx.repo, "feat-a") == head(ctx.path)
  end

  test "a push that fails posts nothing and answers nothing", ctx do
    reply!(ctx.path, "#{@a}.md", "Fixed.")
    GitRepo.git!(ctx.repo.checkout, ["remote", "set-url", "origin", "/nowhere/remote.git"])

    assert {1, _, err} = push(ctx.id, ctx.repo)
    assert err =~ "would not push"
    assert writes(ctx.fake) == []
    assert File.exists?(Path.join(ctx.path, ".whiska-replies/#{@a}.md"))

    Storage.within(ctx.repo.checkout, fn ->
      assert %{status: "sent"} = Storage.question(String.to_integer(ctx.id))
    end)
  end

  test "a reply that fails to post keeps its file and is named, and the rest still post", ctx do
    reply!(ctx.path, "#{@a}.md", "Fixed.")
    reply!(ctx.path, "#{@b}.md", "Answered.")
    thread(ctx.fake, @a, "alice", "?")
    thread(ctx.fake, @b, "bob", "?")

    FakeGlab.answer(ctx.fake, "#{@api}/#{@a}/notes", %{"message" => "403 forge words"},
      status: 403
    )

    posted(ctx.fake, @b)

    assert {0, out, _} = push(ctx.id, ctx.repo)
    assert File.exists?(Path.join(ctx.path, ".whiska-replies/#{@a}.md"))
    refute File.exists?(Path.join(ctx.path, ".whiska-replies/#{@b}.md"))
    assert out =~ "not posted"
    assert out =~ "403 forge words"

    Storage.within(ctx.repo.checkout, fn ->
      assert %{answer: answer} = Storage.question(String.to_integer(ctx.id))
      assert answer =~ "not posted, glab failed"
      refute answer =~ "forge words"
    end)
  end

  test "a file not named for a thread, or a symbolic link, is never posted", ctx do
    reply!(ctx.path, "note.txt", "?")
    reply!(ctx.path, "has space.md", "?")
    secret = Path.join(ctx.repo.root, "secret")
    File.write!(secret, "token")
    File.ln_s!(secret, Path.join(ctx.path, ".whiska-replies/#{@a}.md"))

    assert {0, out, _} = push(ctx.id, ctx.repo)
    assert writes(ctx.fake) == []
    assert out =~ "has space.md"
    assert out =~ "#{@a}.md"
    refute out =~ "token"
  end

  test "with no replies, the branch is still pushed and the question answered", ctx do
    GitRepo.commit!(ctx.path, "fix.md", "fix")
    assert {0, _, _} = push(ctx.id, ctx.repo)
    assert on_remote(ctx.repo, "feat-a") == head(ctx.path)
    assert writes(ctx.fake) == []

    Storage.within(ctx.repo.checkout, fn ->
      assert %{status: "answered"} = Storage.question(String.to_integer(ctx.id))
    end)
  end

  test "a mouse with no recorded merge request is refused, before anything is pushed", ctx do
    Storage.within(ctx.repo.checkout, fn ->
      Whiska.Repo.update_all(Whiska.Schema.Mouse, set: [merge_request_url: nil])
    end)

    GitRepo.commit!(ctx.path, "fix.md", "fix")
    assert {1, _, err} = push(ctx.id, ctx.repo)
    assert err =~ "whiska pr"
    refute on_remote(ctx.repo, "feat-a") == head(ctx.path)
  end

  test "a question already answered is refused, before anything is pushed", ctx do
    Storage.within(ctx.repo.checkout, fn ->
      {:ok, _} = Storage.answer(String.to_integer(ctx.id), "yes")
    end)

    GitRepo.commit!(ctx.path, "fix.md", "fix")
    assert {1, _, err} = push(ctx.id, ctx.repo)
    assert err =~ "answered"
    refute on_remote(ctx.repo, "feat-a") == head(ctx.path)
  end

  test "on GitHub the branch is pushed and the replies are kept, said as not built", ctx do
    Storage.within(ctx.repo.checkout, fn ->
      {:ok, _} = Storage.record_merge_request("m1", "https://github.com/acme/app/pull/7")
    end)

    reply!(ctx.path, "#{@a}.md", "Fixed.")
    GitRepo.commit!(ctx.path, "fix.md", "fix")

    assert {0, out, _} = push(ctx.id, ctx.repo)
    assert on_remote(ctx.repo, "feat-a") == head(ctx.path)
    assert out =~ "GitHub"
    assert File.exists?(Path.join(ctx.path, ".whiska-replies/#{@a}.md"))
  end
end
