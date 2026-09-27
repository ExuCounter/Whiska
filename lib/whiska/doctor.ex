defmodule Whiska.Doctor do
  @moduledoc """
  `whiska doctor`: is Whiska working for this repo right now, and if not, what
  exactly is wrong.

  Built for the case where everything was set up once and has drifted since —
  a binary rebuilt but not reinstalled, a hook that a later version wires but
  this repo's `init` predates, an owl that never got started, a main session
  never recorded. First-time setup is the degenerate case where everything
  fails. Delivery cannot report the cases where it cannot deliver, and the
  statusline (ADR-0027) that would is still unbuilt, so this is the command
  the person runs when the mice have gone quiet and they want to know whether
  that is real quiet.

  Two rules (ADR-0038):

  - **It checks and never repairs.** Every failing check prints the exact
    command that fixes it. Rewriting `settings.json` is `init`'s job; replacing
    the binary is the installer's. The doctor touches nothing.
  - **It probes rather than inspects.** Reading `settings.json` proves a hook is
    wired; it does not prove the shim finds a runtime or that the installed
    binary knows the hook. So the doctor runs the repo's real shim, for both
    hooks, with a payload whose `cwd` is outside any worktree — which makes both
    hooks no-ops that write nothing (ADR-0035 already says the shim is verified
    by running it, not by unit test).

  Scoped to one repo, run from its main checkout or any worktree. The binary,
  runtime, herdr and owl are reported too, because they are that repo's
  prerequisites: a wired Stop hook is worth nothing if the installed binary
  cannot serve it.
  """

  alias Whiska.Doctor.Check
  alias Whiska.Doctor.Report
  alias Whiska.Doorstep
  alias Whiska.Doorstep.Entry
  alias Whiska.Herdr
  alias Whiska.Install
  alias Whiska.Layout
  alias Whiska.Marker
  alias Whiska.OpenHouses
  alias Whiska.Schema.Mouse
  alias Whiska.Schema.Question
  alias Whiska.Storage

  @reinstall "mix escript.build && cp whiska ~/.local/bin/whiska"
  @init "whiska init"
  @owl "whiska owl"
  @restart "whiska start --force  (from the main checkout's pane)"

  @doc """
  Examine one repo. `main_checkout` is its main checkout.

  Options exist so the environment can be pinned in tests: `:env` (a map, the
  process environment by default), `:owl_pids` (a function returning the pids
  of running owls, the process table by default), `:herdr` (the herdr module,
  ADR-0031's boundary), `:open_houses` (the record's path, the real one by
  default).
  """
  @spec run(Path.t(), keyword()) :: Report.t()
  def run(main_checkout, opts \\ []) do
    env = Keyword.get(opts, :env, System.get_env())
    owl_pids = Keyword.get(opts, :owl_pids, &Whiska.Owl.pids/0)
    herdr = Keyword.get(opts, :herdr, Herdr.impl())
    record = Keyword.get_lazy(opts, :open_houses, &OpenHouses.path/0)
    now = DateTime.utc_now()
    pids = owl_pids.()

    {binary, binary_found?} = binary(env)
    {herdr_check, panes} = herdr(env, herdr)
    hooks = hooks(read_settings(main_checkout))
    shim_contents = read_shim(main_checkout)
    shim = shim(shim_contents)

    probes =
      if binary_found? and shim.status == :ok,
        do: [probe(main_checkout, "pre-tool-use", env), probe(main_checkout, "stop", env)],
        else: []

    {house, in_house} = house(main_checkout, panes, herdr, env["HERDR_SOCKET_PATH"], now)

    checks =
      [
        binary,
        runtime(env),
        herdr_check,
        owl(pids),
        open_houses(OpenHouses.read(record), main_checkout, pids)
      ] ++
        hooks ++
        [shim] ++ probes ++ [house, doorstep(Doorstep.waiting(main_checkout), now)] ++ in_house

    %Report{repo: main_checkout, checks: checks}
  end

  # -- prerequisites -----------------------------------------------------------

  # Mirrors the shim's own search (ADR-0035): WHISKA_BIN, then PATH, then
  # ~/.local/bin. Finding it only in the fallback is worth a warning, since a
  # plain `whiska` at the prompt will not work there.
  defp binary(env) do
    override = env["WHISKA_BIN"]
    fallback = Path.join(home(env), ".local/bin/whiska")

    cond do
      executable?(override) ->
        {Check.ok("binary", "#{override} (WHISKA_BIN)"), true}

      path = find_on_path(env, "whiska") ->
        {Check.ok("binary", path), true}

      executable?(fallback) ->
        {Check.warn(
           "binary",
           "#{fallback} — not on PATH; the shim falls back here",
           ~s|export PATH="$HOME/.local/bin:$PATH"|
         ), true}

      true ->
        {Check.fail("binary", "no whiska binary found", @reinstall), false}
    end
  end

  defp runtime(env) do
    override = env["WHISKA_ESCRIPT"]

    cond do
      executable?(override) ->
        Check.ok("runtime", "#{override} (WHISKA_ESCRIPT)")

      path = find_on_path(env, "escript") ->
        Check.ok("runtime", path)

      path = asdf_escript(env) ->
        Check.ok("runtime", "#{path} (asdf install, not on PATH — the shim finds it)")

      path = Enum.find(["/opt/homebrew/bin/escript", "/usr/local/bin/escript"], &executable?/1) ->
        Check.ok("runtime", path)

      true ->
        Check.warn(
          "runtime",
          "no escript found — only a native whiska binary would run (ADR-0033)"
        )
    end
  end

  defp asdf_escript(env) do
    data_dir = env["ASDF_DATA_DIR"] || Path.join(home(env), ".asdf")

    data_dir
    |> Path.join("installs/erlang/*/bin/escript")
    |> Path.wildcard()
    |> Enum.filter(&executable?/1)
    |> Enum.sort_by(&Path.basename(Path.dirname(Path.dirname(&1))), &version_gte?/2)
    |> List.first()
  end

  defp version_gte?(a, b), do: version_parts(a) >= version_parts(b)

  defp version_parts(v),
    do: v |> String.split(".") |> Enum.map(fn p -> Integer.parse(p) |> elem(0) end)

  defp herdr(env, herdr) do
    socket = env["HERDR_SOCKET_PATH"]

    cond do
      is_nil(socket) or socket == "" ->
        {Check.warn("herdr", "HERDR_SOCKET_PATH is not set — run this from a herdr pane"),
         :unknown}

      not File.exists?(socket) ->
        {Check.warn("herdr", "no socket at #{socket} — is herdr running?"), :unknown}

      true ->
        case herdr.list_panes(socket) do
          {:ok, panes} ->
            {Check.ok("herdr", "reachable at #{socket} (#{length(panes)} panes)"), {:ok, panes}}

          {:error, reason} ->
            {Check.warn("herdr", "not answering at #{socket} (#{inspect(reason)})"), :unknown}
        end
    end
  end

  @doc "Is an owl running? `pids` are the owl processes found."
  @spec owl([pos_integer()]) :: Check.t()
  def owl([]), do: Check.warn("owl", "not running — nothing collects the doorstep", @owl)
  def owl(pids), do: Check.ok("owl", "running (pid #{Enum.join(pids, ", ")})")

  @doc """
  The open-houses record (ADR-0039): which houses the owl has open, and
  whether this repo is one of them. `record` is what the file says; `pids`
  are the owl processes found, because the record is only in force while one
  is alive. A repo not in it is not a whiska and nothing collects its
  doorstep, however live its main session is — the case the statusline's count
  cannot explain and this line does.
  """
  @spec open_houses([Path.t()], Path.t(), [pos_integer()]) :: Check.t()
  def open_houses([], _main, _pids),
    do: Check.warn("open houses", "none recorded — the owl has not opened a house yet", @owl)

  def open_houses(record, _main, []) do
    Check.warn(
      "open houses",
      "record lists #{count(record)} (#{names(record)}); none is open while the owl is down",
      @owl
    )
  end

  def open_houses(record, main, _pids) do
    main = Path.expand(main)

    case Enum.reject(record, &(&1 == main)) do
      ^record ->
        Check.warn(
          "open houses",
          "this repo is not open — the owl has #{names(record)}; it is not a whiska and its doorstep is not collected",
          "#{@owl} #{main}  (restart the owl with this repo added)"
        )

      [] ->
        Check.ok("open houses", "this repo")

      others ->
        Check.ok("open houses", "this repo, with #{count(others)} more: #{names(others)}")
    end
  end

  defp count([_]), do: "1 house"
  defp count(houses), do: "#{length(houses)} houses"
  defp names(houses), do: Enum.map_join(houses, ", ", &Path.basename/1)

  # -- this repo's hooks -------------------------------------------------------

  @doc "What `.claude/settings.json` wires: one check for PreToolUse, one for Stop."
  @spec hooks(map()) :: [Check.t()]
  def hooks(settings) when is_map(settings) do
    [
      hook_check(
        "PreToolUse",
        settings,
        Install.command(),
        Install.matcher(),
        "not wired — nothing is enforced for mice here"
      ),
      hook_check(
        "Stop",
        settings,
        Install.stop_command(),
        nil,
        "not wired — mice here cannot leave questions"
      )
    ]
  end

  defp hook_check(event, settings, expected_command, expected_matcher, missing) do
    entries = get_in(settings, ["hooks", event]) || []

    case Enum.find(entries, &ours?/1) do
      nil ->
        Check.fail(event, missing, @init)

      entry ->
        command = our_command(entry)
        matcher = entry["matcher"]

        cond do
          command != expected_command ->
            Check.fail(event, "older version of the hook command: #{command}", @init)

          expected_matcher && matcher != expected_matcher ->
            Check.fail(
              event,
              "matcher is #{inspect(matcher)} — the rules never fire for the tools it leaves out",
              @init
            )

          expected_matcher ->
            Check.ok(event, "wired, matcher #{matcher}")

          true ->
            Check.ok(event, "wired")
        end
    end
  end

  # The same recognition `init` uses when it replaces its own entry.
  defp ours?(%{"hooks" => hooks}) when is_list(hooks), do: our_command(%{"hooks" => hooks}) != nil
  defp ours?(_), do: false

  defp our_command(%{"hooks" => hooks}) do
    Enum.find_value(hooks, fn
      %{"command" => command} when is_binary(command) ->
        if String.contains?(command, "whiska hook") or
             String.contains?(command, "hook pre-tool-use") or
             String.contains?(command, Install.shim_path()),
           do: command

      _ ->
        nil
    end)
  end

  @doc "The committed shim, compared with what `init` writes today."
  @spec shim(String.t() | nil) :: Check.t()
  def shim(nil), do: Check.fail("shim", "#{Install.shim_path()} is missing", @init)

  def shim(contents) do
    if contents == Install.shim(),
      do: Check.ok("shim", "#{Install.shim_path()} is current"),
      else: Check.fail("shim", "#{Install.shim_path()} differs from what init writes", @init)
  end

  @doc """
  Run the repo's installed hook for real, through its shim.

  The payload's `cwd` is a fresh temporary directory outside any worktree, so
  `pre-tool-use` allows and `stop` is a no-op: nothing is minted, nothing lands
  on a doorstep. What is being tested is everything before that point — the
  shim finds a binary and a runtime, and the binary knows this hook.

  The shim fails open by design (ADR-0035), so exit 0 is not enough: its
  complaint on stderr is what says the call was allowed by accident.
  """
  @spec probe(Path.t(), String.t(), map()) :: Check.t()
  def probe(repo_root, hook, env) do
    name = "hook #{hook}"
    shim = Path.join(repo_root, Install.shim_path())

    tmp =
      Path.join(System.tmp_dir!(), "whiska-doctor-probe-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp)

    try do
      payload_file = Path.join(tmp, "payload.json")
      stderr_file = Path.join(tmp, "stderr")
      File.write!(payload_file, JSON.encode!(payload(hook, tmp)))

      {out, status} =
        System.cmd(
          "sh",
          [~s|-c|, ~s|bash "$0" "$1" < "$2" 2> "$3"|, shim, hook, payload_file, stderr_file],
          env: Map.to_list(Map.put(env, "CLAUDE_PROJECT_DIR", repo_root)),
          cd: tmp
        )

      stderr = File.read!(stderr_file)
      complaint = stderr |> String.split("\n", trim: true) |> List.first()

      cond do
        status != 0 ->
          Check.fail(name, "exit #{status}: #{complaint || "no output"}", @reinstall)

        String.contains?(stderr, "whiska:") ->
          Check.fail(name, "allowed by accident — #{complaint}", @reinstall)

        String.trim(out) != "" ->
          Check.fail(
            name,
            "unexpected output from a no-op probe: #{String.trim(out)}",
            @reinstall
          )

        true ->
          Check.ok(name, "runs through #{Install.shim_path()}")
      end
    after
      File.rm_rf(tmp)
    end
  end

  defp payload("pre-tool-use", cwd),
    do: %{
      "cwd" => cwd,
      "tool_name" => "Read",
      "tool_input" => %{"file_path" => Path.join(cwd, "probe")}
    }

  defp payload("stop", cwd),
    do: %{
      "cwd" => cwd,
      "last_assistant_message" => "whiska doctor probe\n[worktree-status: done]"
    }

  # -- this repo's house -------------------------------------------------------

  defp house(main_checkout, panes, herdr, socket, now) do
    path = Storage.database_path(main_checkout)

    try do
      case Storage.open(main_checkout) do
        {:ok, handle} ->
          try do
            version = Storage.schema_version()
            main_pane = Storage.main_pane()
            word = main_word(main_pane, panes, herdr, socket)

            in_house =
              [
                main_session(main_pane, word),
                questions(Storage.open_count(), Storage.sent(), main_pane != nil, now)
              ] ++ mice(Storage.all(Mouse), panes)

            {Check.ok("house", "#{path}, schema v#{version}"), in_house}
          after
            Storage.close(handle)
          end

        {:error, reason} ->
          {Check.fail("house", "cannot open #{path} (#{inspect(reason)})"), []}
      end
    rescue
      e -> {Check.fail("house", "cannot open #{path} (#{Exception.message(e)})"), []}
    end
  end

  # herdr's fresh word on the main pane — the same call the delivery gate
  # makes, so the doctor and the owl agree on what "running Claude" means.
  defp main_word(nil, _panes, _herdr, _socket), do: :unknown
  defp main_word(_pane, :unknown, _herdr, _socket), do: :unknown
  defp main_word(pane, {:ok, _}, herdr, socket), do: herdr.pane(socket, pane)

  @doc """
  Where delivery would go: the pane `whiska start` recorded, judged by herdr's
  fresh word on it (`{:ok, pane}`, `{:error, reason}`, or `:unknown` when herdr
  could not be asked). Every bad state is a warning, not a failure — the owl
  holds the queue and nothing is lost — but it is the first thing to read when
  the mice have gone quiet.
  """
  @spec main_session(String.t() | nil, {:ok, Herdr.pane()} | {:error, term()} | :unknown) ::
          Check.t()
  def main_session(nil, _word) do
    Check.warn(
      "main session",
      "not recorded — nothing is delivered until it is",
      "whiska start  (from the main checkout's pane)"
    )
  end

  def main_session(pane, :unknown),
    do: Check.ok("main session", "#{pane}, not checked (herdr unreachable)")

  def main_session(pane, {:ok, %{agent: "claude", agent_status: status}}),
    do: Check.ok("main session", "#{pane}, claude #{status}")

  def main_session(pane, {:ok, %{agent: nil}}),
    do: Check.warn("main session", "#{pane} is not running Claude — questions are held", @restart)

  def main_session(pane, {:ok, %{agent: other}}),
    do:
      Check.warn(
        "main session",
        "#{pane} runs #{other}, not Claude — questions are held",
        @restart
      )

  def main_session(pane, {:error, _reason}),
    do: Check.warn("main session", "recorded as #{pane}, but herdr has no such pane", @restart)

  @doc """
  The queue as a diagnosis, not a listing (`whiska questions` is the listing):
  how many are open, whether one is sent and for how long — and a warning for
  the one combination that means nothing can move, open questions with no main
  session to deliver them to.
  """
  @spec questions(non_neg_integer(), Question.t() | nil, boolean(), DateTime.t()) :: Check.t()
  def questions(0, nil, _main?, _now), do: Check.ok("questions", "none waiting")

  def questions(open, nil, false, _now) when open > 0 do
    Check.warn(
      "questions",
      "#{open} open, cannot be delivered — no main session",
      "whiska start  (from the main checkout's pane)"
    )
  end

  def questions(open, sent, _main?, now) do
    parts =
      ["#{open} open"] ++
        case sent do
          nil ->
            []

          %Question{id: id, sent_at: at} ->
            ["1 sent (id #{id}, waiting #{age(DateTime.diff(now, at, :second))})"]
        end

    Check.ok("questions", Enum.join(parts, ", "))
  end

  @doc "Uncollected entries: none is ok; any is a warning carrying the count and the oldest age."
  @spec doorstep([{Path.t(), Entry.t()} | Entry.t()], DateTime.t()) :: Check.t()
  def doorstep([], _now), do: Check.ok("doorstep", "nothing waiting")

  def doorstep(entries, now) do
    stamps =
      Enum.map(entries, fn
        {_file, %Entry{stamped_at: at}} -> at
        %Entry{stamped_at: at} -> at
      end)

    oldest = stamps |> Enum.min(DateTime) |> then(&DateTime.diff(now, &1, :second))
    Check.warn("doorstep", "#{length(entries)} waiting, oldest #{age(oldest)}", @owl)
  end

  defp age(seconds) when seconds < 3600, do: "#{div(seconds, 60)} min"
  defp age(seconds), do: "#{div(seconds, 3600)} h #{div(rem(seconds, 3600), 60)} min"

  @doc """
  Do the live mouse records still match the world? One check per live mouse.

  A record is judged against the filesystem (is the worktree there, does its
  marker still hold this id) and against herdr's panes (`{:ok, panes}`, or
  `:unknown` when herdr could not be asked, in which case panes are not
  judged). Dead records are left out. Nothing is marked: reconciling is the
  owl's job (ADR-0026).
  """
  @spec mice([Mouse.t()], {:ok, [Herdr.pane()]} | :unknown) :: [Check.t()]
  def mice(mice, panes) do
    for %Mouse{died_at: nil} = mouse <- mice, do: mouse_check(mouse, panes)
  end

  defp mouse_check(%Mouse{branch: branch, path: path, mouse_id: id}, panes) do
    cond do
      not File.dir?(path) ->
        Check.warn(
          "mice",
          "#{branch}: worktree gone (#{path}), record not marked dead",
          "#{@owl} — reconciles on open"
        )

      marker(path) != id ->
        Check.warn("mice", "#{branch}: marker in the worktree does not match the record")

      panes == :unknown ->
        Check.ok("mice", "#{branch}: worktree present, pane not checked (herdr unreachable)")

      pane = live_pane(panes, path) ->
        Check.ok("mice", "#{branch}: live pane #{pane.pane_id}")

      true ->
        Check.warn("mice", "#{branch}: no live pane — dead, or not started yet")
    end
  end

  defp marker(worktree_root) do
    case File.read(Marker.path(worktree_root)) do
      {:ok, contents} -> String.trim(contents)
      _ -> nil
    end
  end

  defp live_pane({:ok, panes}, path) do
    Enum.find(panes, &(&1.agent != nil and is_binary(&1.cwd) and Layout.inside?(&1.cwd, path)))
  end

  # -- reading the repo --------------------------------------------------------

  defp read_settings(main_checkout) do
    with {:ok, raw} <- File.read(Path.join(main_checkout, ".claude/settings.json")),
         {:ok, settings} when is_map(settings) <- JSON.decode(raw) do
      settings
    else
      _ -> %{}
    end
  end

  defp read_shim(main_checkout) do
    case File.read(Path.join(main_checkout, Install.shim_path())) do
      {:ok, contents} -> contents
      _ -> nil
    end
  end

  defp home(env), do: env["HOME"] || System.user_home!()

  defp executable?(nil), do: false
  defp executable?(""), do: false

  defp executable?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, mode: mode}} -> Bitwise.band(mode, 0o111) != 0
      _ -> false
    end
  end

  defp find_on_path(env, name) do
    (env["PATH"] || "")
    |> String.split(":", trim: true)
    |> Enum.map(&Path.join(&1, name))
    |> Enum.find(&executable?/1)
  end
end
