defmodule Whiska.InstallStatuslineTest do
  @moduledoc """
  What `whiska init` writes for questions: herdr's tab bar script and its config
  entry (ADR-0048), and the reading skills (ADR-0022) — and the Claude Code
  statusline it takes out of an older install
  (ADR-0082).
  """
  # Serial: each test points the global `:home` at a folder of its own.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Whiska.CLI
  alias Whiska.Install
  alias Whiska.Delivery.Mode
  alias Whiska.Questions
  alias Whiska.Schema.Question

  setup do
    root = Path.join(System.tmp_dir!(), "whiska-inst-#{System.unique_integer([:positive])}")
    main = Path.join(root, "myrepo")
    home = Path.join(root, "dot-whiska")
    File.mkdir_p!(Path.join(main, ".git"))
    previous = Application.get_env(:whiska, :home)
    Application.put_env(:whiska, :home, home)

    on_exit(fn ->
      Application.put_env(:whiska, :home, previous)
      File.rm_rf!(root)
    end)

    {:ok, main: main, home: home}
  end

  describe "merge — the retired Claude Code statusline" do
    @ours_repo ~s|bash "${CLAUDE_PROJECT_DIR:-.}/.claude/hooks/whiska-statusline.sh"|
    @ours_global ~s|bash "$HOME/.claude/hooks/whiska-statusline.sh"|

    test "writes no statusLine" do
      refute Map.has_key?(Install.merge(%{}), "statusLine")
      refute Map.has_key?(Install.merge(%{}, :global), "statusLine")
    end

    test "takes out one an older init wrote, interval and all" do
      old = %{"type" => "command", "command" => @ours_repo, "refreshInterval" => 1}

      refute Map.has_key?(Install.merge(%{"statusLine" => old}), "statusLine")
    end

    test "puts the person's own line back where the global install displaced it" do
      old = %{"type" => "command", "command" => @ours_global, "refreshInterval" => 1}

      assert Install.merge(%{"statusLine" => old}, :global, "bash ~/my-line.sh")["statusLine"] ==
               %{"type" => "command", "command" => "bash ~/my-line.sh"}
    end

    test "leaves a statusLine that is not ours exactly alone" do
      mine = %{"type" => "command", "command" => "bash mine.sh", "refreshInterval" => 5}

      assert Install.merge(%{"statusLine" => mine})["statusLine"] == mine
      assert Install.merge(%{"statusLine" => mine}, :global, "bash old.sh")["statusLine"] == mine
    end

    test "a statusLine of a shape we do not recognise is left alone too" do
      for theirs <- ["bash mine.sh", %{"type" => "command"}, %{"command" => nil}] do
        assert Install.merge(%{"statusLine" => theirs})["statusLine"] == theirs
      end
    end
  end

  describe "retired_statusline/1 — what an older init left behind" do
    test "names the settings entry, the script and the kept line, where they are", %{main: main} do
      File.mkdir_p!(Path.join(main, ".claude/hooks"))
      File.write!(Path.join(main, ".claude/hooks/whiska-statusline.sh"), "#!/usr/bin/env bash\n")
      File.write!(Path.join(main, ".claude/whiska-base-statusline"), "bash ~/my-line.sh")

      File.write!(
        Path.join(main, ".claude/settings.json"),
        JSON.encode!(%{"statusLine" => %{"type" => "command", "command" => @ours_repo}})
      )

      assert Install.retired_statusline(main) == [
               ".claude/settings.json statusLine",
               ".claude/hooks/whiska-statusline.sh",
               ".claude/whiska-base-statusline"
             ]
    end

    test "is nothing where none of it is", %{main: main} do
      File.mkdir_p!(Path.join(main, ".claude"))

      File.write!(
        Path.join(main, ".claude/settings.json"),
        JSON.encode!(%{"statusLine" => %{"type" => "command", "command" => "bash mine.sh"}})
      )

      assert Install.retired_statusline(main) == []
    end
  end

  # What the script prints is driven for real in Whiska.Owl.HerdrStatusTest.
  describe "herdr_status_script/0 — what herdr's tab bar runs (ADR-0048)" do
    test "lives in the whiska home, not in any repo" do
      assert Install.herdr_status_path() == Path.join(Whiska.OpenHouses.home(), "herdr-status.sh")
    end
  end

  describe "tab_bar_right_snippet/0 — what the person commits in dotfiles" do
    test "is the herdr config entry that draws the line, naming the shipped script" do
      snippet = Install.tab_bar_right_snippet()

      assert snippet =~ "[ui]"
      assert snippet =~ "tab_bar_right"
      assert snippet =~ ~s(type = "command")
      assert snippet =~ ~s(command = "#{Install.herdr_status_path()} '⌃a space'")
      assert snippet =~ "interval_seconds = #{Install.herdr_status_interval()}"
      assert snippet =~ "timeout_seconds = #{Install.herdr_status_timeout()}"
    end

    test "an interval and timeout herdr accepts" do
      assert Install.herdr_status_interval() in 1..31_536_000
      assert Install.herdr_status_timeout() in 1..3_600
    end
  end

  describe "whiska owl install writes the script" do
    test "executable, in the whiska home", %{home: home} do
      script = Install.herdr_status_path()
      assert String.starts_with?(script, home)

      assert :ok = Install.write_herdr_status()
      assert File.read!(script) == Install.herdr_status_script()
      assert Bitwise.band(File.stat!(script).mode, 0o100) != 0
    end
  end

  describe "skills/0 — one slash command per command (ADR-0022)" do
    # whiska-delivered is a core skill plus a file per finish options, read
    # only when the line needs it.
    defp delivered(file) do
      assert {_path, body} =
               List.keyfind(Install.skills(), ".claude/skills/whiska-delivered/#{file}", 0),
             "whiska-delivered/#{file} is not installed"

      body
    end

    # The options finished.md offers for one branch state: that state's row.
    defp options_for(state) do
      rows =
        delivered("finished.md")
        |> String.split("\n")
        |> Enum.filter(&(String.starts_with?(&1, "| `") and String.contains?(&1, state)))

      assert [row] = rows, "finished.md has no one row for #{state}"
      row
    end

    # The line `whiska show` prints under a finished question's heading.
    defp branch_line(branch) do
      question = %Question{id: 1, kind: "done", status: "closed", text: "Done."}
      question = %{question | asked_at: DateTime.utc_now()}

      question
      |> Questions.full("feat-a", nil, Mode.none(), nil, fn _ -> branch end)
      |> String.split("\n")
      |> Enum.at(1)
    end

    # A row's first cell as a pattern for the line it stands for.
    defp row_pattern(row) do
      [_, shape] = Regex.run(~r/^\| `([^`]+)`/, row)

      if String.starts_with?(shape, "On the branch:"),
        do: line_pattern(shape),
        else: line_pattern("On the branch: " <> shape)
    end

    # A line's shape as the skills write it, as a pattern for whole lines.
    defp line_pattern(shape) do
      shape
      |> Regex.escape()
      |> String.replace("<N>", "\\d+")
      |> String.replace("<base>", "\\S+")
      |> String.replace("…", ".*")
      |> String.replace("\\(s\\)", "s?")
      |> then(&Regex.compile!("^" <> &1 <> "$", "u"))
    end

    # One option in finished.md, as written once for every state.
    defp option(name) do
      assert [_, rest] = String.split(delivered("finished.md"), "- **#{name}** — ", parts: 2),
             "finished.md does not define #{name}"

      rest
      |> String.split(~r/^- \*\*|^`drop-worktree`/m, parts: 2)
      |> hd()
      |> String.replace(~r/\s+/, " ")
    end

    test "installs /show as a thin wrapper around the fixed command" do
      assert {path, body} = List.keyfind(Install.skills(), ".claude/skills/show/SKILL.md", 0)

      assert path =~ "show"
      assert body =~ "name: show"
      assert body =~ "whiska show"
    end

    test "/show reads everything in full with no argument, one by id with one" do
      assert {_path, body} = List.keyfind(Install.skills(), ".claude/skills/show/SKILL.md", 0)

      assert body =~ "whiska show\n"
      assert body =~ "$ARGUMENTS"
      assert body =~ "whiska show $ARGUMENTS"
      # Still a thin wrapper of fixed commands (ADR-0022), still never answering
      # on the person's behalf (ADR-0017).
      assert body =~ ~r/never reply/
      refute body =~ "summarise"
    end

    test "both reading skills say the person cannot see the command's output, so it goes verbatim in the reply" do
      # Claude Code folds a Bash tool's result away from the person; "show its
      # output" alone got read as "it is already visible" and the model summarised.
      for path <- [
            ".claude/skills/show/SKILL.md",
            ".claude/skills/whiska-delivered/SKILL.md"
          ] do
        assert {_path, body} = List.keyfind(Install.skills(), path, 0)
        assert body =~ "cannot see", path
        assert body =~ "verbatim", path
        # A fenced block is what turns rendering off: the person saw `**sent**`
        # and backticks instead of bold and code. The reply is the message as
        # markdown, so it renders the way the mouse wrote it.
        assert body =~ "as markdown", path
        assert body =~ "no fence", path
        refute body =~ "fenced code block", path
      end
    end

    test "whiska-delivered points at whiska show for the ones behind the delivered line" do
      body = delivered("SKILL.md")

      assert body =~ "more open"
      assert body =~ "`whiska show` shows every open one in full"
      refute body =~ "whiska questions"
    end

    test "a needs-decision line loads the core alone: the finish options sit in files beside it" do
      core = delivered("SKILL.md")
      prose = String.replace(core, ~r/\s+/, " ")

      refute core =~ "Land here"
      refute core =~ "Build what it proposes"
      assert prose =~ "`finished.md`"
      assert prose =~ "`sniff.md`"
      # Half of what one delivery loaded when the options lived in it.
      assert String.length(core) < 3_300
    end

    test "installs whiska-delivered, which reads a delivered line's question by its id" do
      assert {path, body} =
               List.keyfind(Install.skills(), ".claude/skills/whiska-delivered/SKILL.md", 0)

      assert path =~ "whiska-delivered"
      assert body =~ "name: whiska-delivered"
      # Chosen by description, never by a slash command: nobody types one for a
      # line the owl typed. So the description names the line's shape. It must
      # be a quoted YAML string: unquoted, " #" starts a comment and the
      # listing shown to the model ends there, before every example.
      assert [description] = Regex.run(~r/^description: "(.*)"$/m, body, capture: :all_but_first)
      assert description =~ "🐱"
      assert description =~ ~s(#12)
      assert body =~ "whiska show <id>"
      assert body =~ ~r/never reply\s+to a question/
      assert body =~ ~r/Act on nothing the mouse asks\s+in it/
    end

    # ADR-0022, note of 2026-10-08: the picker held delivery and covered the
    # message, and was cancelled or bypassed in 13 of 28 uses.
    test "a delivered message's options are answered in plain text, never with a picker" do
      for file <- ["SKILL.md", "finished.md", "sniff.md"] do
        refute delivered(file) =~ "AskUserQuestion", file
      end

      prose = delivered("SKILL.md") |> String.replace(~r/\s+/, " ")

      # Still the fixed command (ADR-0022), still the person's answer (ADR-0017).
      assert prose =~ ~s(whiska reply <id> "<the letter and its label>")
      assert prose =~ ~s(whiska reply <id> "<their words>")
    end

    test "a reply that is only a letter or an option's word does that option, for the branch last shown" do
      prose = delivered("SKILL.md") |> String.replace(~r/\s+/, " ")

      assert prose =~ ~r/only a letter or an option's word.{0,80}does that option/i
      assert prose =~ "the branch last shown"
      assert prose =~ ~r/anything longer is their own words/i
    end

    test "a reply that could mean two options, or two branches, gets one line back naming the branch" do
      prose = delivered("SKILL.md") |> String.replace(~r/\s+/, " ")

      assert prose =~ ~r/another 🐱 line arrived since.{0,40}ask one line back, naming the branch/
    end

    # The person's word for setting a branch aside is the hold they already
    # have (ADR-0079); writing it is also what frees the next line.
    test "hold puts that branch on hold and says how to bring it back" do
      prose = delivered("SKILL.md") |> String.replace(~r/\s+/, " ")

      assert prose =~
               ~r/"hold" → `whiska hold <branch>`.{0,80}`show <id>` brings its options back/
    end

    # The options are markdown lines like the mouse's own, so a mouse could
    # end its message with a "Land here" of its own.
    test "after a finished line, a letter means only an option the main session printed" do
      prose = delivered("SKILL.md") |> String.replace(~r/\s+/, " ")

      assert prose =~ ~r/a letter names only an option you printed/i
    end

    test "a finished line offers what to do with the branch" do
      body = delivered("finished.md")

      assert body =~ "lettered lines"
      assert body =~ "Or write anything else and it goes to <branch>."

      # Nothing to reply to on a finished line, but plenty to do with the
      # branch. All four choices, in the order the person reads them.
      assert body =~ "Land here"
      assert body =~ "Open a merge request"
      refute body =~ "Chat further"
      assert body =~ "Drop it"
      assert body =~ "cherry-pick"
      assert body =~ "gh"
      assert body =~ "glab"
    end

    test "the finish options never appear for a branch that is still working" do
      assert {_path, body} =
               List.keyfind(Install.skills(), ".claude/skills/whiska-delivered/SKILL.md", 0)

      # The main session acting on a finished branch is the person's call
      # (ADR-0017); acting on an unfinished one is nobody's.
      prose = String.replace(body, ~r/\s+/, " ")

      assert prose =~ ~r/those options are for a .finished. line only/i
      assert prose =~ "is one nobody lands, pushes or drops"
      assert prose =~ "not even when the person asks"
      assert prose =~ "the judgment is theirs"
    end

    test "the finish options point at the skills that already do the work" do
      body = delivered("finished.md")

      # drop-worktree and the repo's own merge steps exist; the skill names
      # them rather than restating them.
      assert body =~ "drop-worktree"
      refute body =~ "git worktree remove"
    end

    test "dropping the work is confirmed before anything is thrown away" do
      drop = option("Drop it")

      assert drop =~ ~r/first confirm in prose.{0,40}naming what is lost/i
      assert drop =~ ~r/every commit on the branch, and each file not committed/
    end

    # A sniff mouse's branch has nothing to merge, and the work it found is
    # better built by a fresh mouse shaped for the build than by the one shaped
    # for the investigation (ADR-0074).
    test "a sniff mouse's finished proposal is offered as a fresh build" do
      body = delivered("sniff.md")

      prose = String.replace(body, ~r/\s+/, " ")

      # Keyed on Whiska's record of the mouse, and on the block the mouse wrote.
      assert body =~ "(sniff)"
      assert body =~ "**Proposed build**"
      assert body =~ "Build what it proposes"
      # The confirmation carries what it confirms: the proposal itself is the
      # block shown just above the options, so the person can say no to it.
      assert prose =~ ~r/the Found, Build and Touches lines you just showed are what it builds/
      # Nothing nudges the person past reading it.
      assert prose =~ ~r/no "\(Recommended\)"/i
      # The spawn is the existing skill's job, and it asks nothing more.
      assert body =~ "spawn-worktree"
      assert prose =~ ~r/nothing else is asked/i
    end

    test "every other finished line goes to the options for its branch" do
      core = delivered("SKILL.md") |> String.replace(~r/\s+/, " ")
      sniff = delivered("sniff.md") |> String.replace(~r/\s+/, " ")

      # Found anywhere in the message: a mouse may close on a line after it.
      assert core =~ ~r/the message carries a \*\*Proposed build\*\* block/
      assert sniff =~ ~r/no proposal, or neither sign/i
      assert sniff =~ "`finished.md`"
    end

    # Rendered by the code that prints it, so rewording either side goes red.
    test "every branch line whiska show prints has exactly one options row" do
      rows =
        delivered("finished.md")
        |> String.split("\n")
        |> Enum.filter(&String.starts_with?(&1, "| `"))
        |> Enum.map(&row_pattern/1)

      branches =
        for ahead <- [0, 1, 2], files <- [[], ["a.txt"], ~w(a b c d)] do
          {:ok, %{base: "main", ahead: ahead, uncommitted: files}}
        end

      for branch <- branches ++ [{:error, :no_worktree}, {:error, :ambiguous_base}] do
        line = branch_line(branch)
        assert [_one] = Enum.filter(rows, &Regex.match?(&1, line)), "no one row for #{line}"
      end
    end

    # A whole line, so a file name that reads "nothing committed beyond main"
    # cannot route a branch with commits to the proposal (ADR-0074).
    test "the proposal is routed by the whole line whiska show prints for an empty branch" do
      empty = branch_line({:ok, %{base: "main", ahead: 0, uncommitted: []}})

      dirty =
        branch_line({:ok, %{base: "main", ahead: 0, uncommitted: ["nothing uncommitted"]}})

      for file <- ["SKILL.md", "sniff.md"] do
        assert delivered(file) =~ "(sniff)", file

        assert [_, shape] =
                 Regex.run(~r/is\s+exactly\s+`(On the branch:[^`]+)`/, delivered(file)),
               file

        pattern = shape |> String.replace(~r/\s+/, " ") |> line_pattern()
        assert empty =~ pattern, "#{file} routes on #{inspect(shape)}, which show never prints"
        refute dirty =~ pattern, file
      end
    end

    test "a branch with commits and nothing uncommitted keeps the four options" do
      assert options_for("<N> commit(s) beyond <base> · nothing uncommitted") =~
               "Land here (Recommended), Open a merge request / PR, Drop it"

      assert delivered("finished.md") =~ "finish: land here"
    end

    test "files not committed are offered a commit first, whatever is committed" do
      for state <- [
            "<N> commit(s) beyond <base> · <N> file(s) not committed",
            "nothing committed beyond <base> · <N> file(s) not committed"
          ] do
        assert options_for(state) =~
                 "| Commit and land (Recommended), Commit and open a PR, Drop it |",
               state
      end

      refute delivered("finished.md") =~ "The next step"
      refute option("Land here") =~ ~r/stay in the worktree/i
    end

    # Nothing a mouse wrote reaches a command line (ADR-0074).
    test "the main session commits in the mouse's worktree, from a file, after showing every file" do
      commit = option("Commit and land")

      assert commit =~ ~r/list.{0,60}every file/i
      assert commit =~ "`git -C <worktree> status --porcelain --untracked-files=all`"
      assert commit =~ ~r/file outside both checkouts/i
      assert commit =~ "`git -C <worktree> commit -F <file>`"

      assert commit =~
               ~r/Whiska's own `\.whiska-mouse` and `\.whiska-spec\.md` are never committed.{0,40}left out of the list/i

      assert commit =~
               "run `git -C <worktree> add -A -- . ':!.whiska-mouse' ':!.whiska-spec.md'`"

      assert commit =~
               ~r/`git -C <worktree> diff --cached --name-only --no-renames`.{0,160}`git -C <worktree> reset`, stop/i

      assert commit =~
               ~r/looks like a secret or local setup.{0,160}marked in the list, and no option is recommended, whatever the table or `finish:` says/i

      assert commit =~ ~r/git refuses.{0,60}stop/i
      assert commit =~ ~r/then exactly as Land here/i
    end

    test "opening a request commits the rest the same way first" do
      pr = option("Commit and open a PR")

      assert pr =~ ~r/commit as Commit and land does/i
      assert pr =~ ~r/then exactly as Open a merge request \/ PR/i
    end

    test "the person's own words still reach the mouse, quoted" do
      body = delivered("finished.md") |> String.replace(~r/\s+/, " ")

      assert body =~ ~r/the person's own words go to the mouse/i
      assert body =~ "herdr agent prompt <pane-id> '<their words>'"
      assert body =~ "each `'` in it written `'\\''`"
    end

    test "a branch with nothing on it and no proposal gets no options, only a reply" do
      assert options_for("nothing committed beyond <base> · nothing uncommitted") =~
               "none: a reply, not a choice"

      reply = String.replace(delivered("finished.md"), ~r/\s+/, " ")
      assert reply =~ "send this to <branch>?"
      assert reply =~ ~s(is not sent; "hold" holds the branch, as `SKILL.md` says)
      assert reply =~ "word for word"
      assert option("Drop it") =~ ~r/a branch with nothing on it needs no confirmation/i
    end

    test "an unknown branch, or no line at all, keeps the four options" do
      assert options_for("On the branch: unknown") =~
               "as for commits and nothing uncommitted: unknown keeps every option"
    end

    # The finished question is closed, so `whiska reply` refuses it.
    test "what a finished line sends into the pane is no answer" do
      core = delivered("SKILL.md") |> String.replace(~r/\s+/, " ")

      [_, other] =
        String.split(delivered("finished.md"), "## Their own words", parts: 2)

      assert core =~ ~r/what `finished.md` sends into the pane is not an answer/i
      assert other =~ ~r/this is not an answer/i
    end

    test "an investigation's proposal options are Build or Not now, with no chat or drop" do
      body = delivered("sniff.md")

      assert body =~ "**Build what it proposes**"
      assert body =~ "**Not now**"
      assert body =~ "Their own words"
      refute body =~ "Chat further"
      refute body =~ "**Drop it**"
    end

    test "a repo can name its usual finish choice, and the options follow it" do
      body = delivered("finished.md")

      # Read from an optional heading the person writes by hand — no fifth
      # part in the block whiska init writes (ADR-0045 nest untouched).
      assert body =~ "## Finish"
      assert body =~ "finish: land here"

      assert String.replace(body, ~r/\s+/, " ") =~
               ~r/where Commit and land would be recommended.{0,120}merge request recommends Commit and open a PR/i

      refute body =~ "whiska:finish"
    end

    test "/show reads a reply to one question the way whiska-delivered does" do
      assert {_path, body} = List.keyfind(Install.skills(), ".claude/skills/show/SKILL.md", 0)

      refute body =~ "AskUserQuestion"
      assert body =~ ~r/whiska reply/
      assert body =~ "whiska-delivered"
      # Bare `show` is a list of several; a bare letter cannot name one of them.
      assert String.replace(body, ~r/\s+/, " ") =~ ~r/a bare letter.{0,80}ask which/i
    end

    test "installs /reply as a thin wrapper around the fixed command" do
      assert {path, body} = List.keyfind(Install.skills(), ".claude/skills/reply/SKILL.md", 0)

      assert path =~ "reply"
      assert body =~ "name: reply"
      assert body =~ "whiska reply $ARGUMENTS"
      # The text is the person's, never the model's composition (ADR-0017).
      assert body =~ "own words"
    end

    test "every answering skill says an answer goes through whiska reply and nothing else" do
      for path <- [
            ".claude/skills/whiska-delivered/SKILL.md",
            ".claude/skills/reply/SKILL.md"
          ] do
        assert {_path, body} = List.keyfind(Install.skills(), path, 0)
        prose = String.replace(body, ~r/\s+/, " ")

        assert prose =~ ~r/only (as `whiska reply|this way)/i, path
        assert body =~ "herdr agent prompt", path
      end
    end

    test "the main session never closes or supersedes a delivered question itself" do
      assert {_path, body} =
               List.keyfind(Install.skills(), ".claude/skills/whiska-delivered/SKILL.md", 0)

      # A question the person has not answered stays open. Whiska settles it
      # when that branch's next message arrives (ADR-0037); `whiska close` is
      # the person's command, never the model's tidying-up.
      assert body =~ ~r/never close/i
      assert body =~ "whiska dismiss <id>"
      refute body =~ "whiska close"
      assert body =~ ~r/Whiska supersedes it/
      assert body =~ ~r/only when they ask|when the person asks/i
    end

    # No "the committed copy matches what init writes" test any more: the only
    # copy is `priv/skills/`, which `Whiska.Install` reads at compile time
    # (ADR-0046), so there is nothing left for it to drift from. This repo is
    # installed globally (ADR-0056) and has no `.claude/skills/` of its own.
  end

  describe "whiska init writes them" do
    test "the skills, and no statusline", %{main: main} do
      capture_io(fn -> assert CLI.run(["init"], main) == 0 end)

      for {path, body} <- Install.skills() do
        assert File.read!(Path.join(main, path)) == body
      end

      refute File.exists?(Path.join(main, Install.statusline_path()))
      settings = JSON.decode!(File.read!(Path.join(main, ".claude/settings.json")))
      refute Map.has_key?(settings, "statusLine")
    end

    test "takes out the statusline an earlier init wrote, and says so", %{main: main} do
      script = Path.join(main, Install.statusline_path())
      File.mkdir_p!(Path.dirname(script))
      File.write!(script, "#!/usr/bin/env bash\n# whiska-statusline: v4\n")

      File.write!(
        Path.join(main, ".claude/settings.json"),
        JSON.encode!(%{
          "statusLine" => %{"type" => "command", "command" => @ours_repo, "refreshInterval" => 1}
        })
      )

      said = capture_io(fn -> assert CLI.run(["init"], main) == 0 end)

      refute File.exists?(script)
      settings = JSON.decode!(File.read!(Path.join(main, ".claude/settings.json")))
      refute Map.has_key?(settings, "statusLine")
      assert said =~ Install.statusline_path()
      assert said =~ "herdr's sidebar"
    end

    test "names a leftover reached through a symlink, and leaves it where it lives", %{
      main: main
    } do
      elsewhere = Path.join(Path.dirname(main), "dotfiles/whiska-statusline.sh")
      File.mkdir_p!(Path.dirname(elsewhere))
      File.write!(elsewhere, "#!/usr/bin/env bash\n")
      File.mkdir_p!(Path.join(main, ".claude/hooks"))
      File.ln_s!(Path.dirname(elsewhere), Path.join(main, ".claude/hooks/linked"))
      File.ln_s!(elsewhere, Path.join(main, Install.statusline_path()))

      said = capture_io(fn -> assert CLI.run(["init"], main) == 0 end)

      assert File.exists?(elsewhere)
      assert said =~ "through a symlink"
      assert said =~ Install.statusline_path()
    end

    test "leaves somebody else's statusline, and their script, alone", %{main: main} do
      mine = %{"type" => "command", "command" => "bash .claude/hooks/mine.sh"}
      File.mkdir_p!(Path.join(main, ".claude/hooks"))
      File.write!(Path.join(main, ".claude/hooks/mine.sh"), "echo mine\n")
      File.write!(Path.join(main, ".claude/settings.json"), JSON.encode!(%{"statusLine" => mine}))

      capture_io(fn -> assert CLI.run(["init"], main) == 0 end)

      settings = JSON.decode!(File.read!(Path.join(main, ".claude/settings.json")))
      assert settings["statusLine"] == mine
      assert File.exists?(Path.join(main, ".claude/hooks/mine.sh"))
    end

    test "the shim itself is unchanged by this", %{main: main} do
      capture_io(fn -> assert CLI.run(["init"], main) == 0 end)
      assert File.read!(Path.join(main, Install.shim_path())) == Install.shim()
      assert Install.shim() =~ ~s(hook "$@")
    end
  end
end
