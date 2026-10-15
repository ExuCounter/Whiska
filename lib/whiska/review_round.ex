defmodule Whiska.ReviewRound do
  @moduledoc """
  A review round: new review on a mouse's merge request, handed to a mouse to
  fix, answer and, on the person's yes, push (ADR-0060).

  The owl reads the review (`Whiska.MergeRequests`) and keeps it on the read's
  row until it can hand it over. Then it either wakes the branch's mouse, idle
  in its pane, with a letter and one fixed line typed there (ADR-0044's fourth
  exception), or, with no live mouse, starts a fresh one in the branch's
  worktree (`Whiska.ReviewStart`, ADR-0044's fifth).

  The letter holds the round's rules, the merge request's link, and a link and
  id for each new comment and failed pipeline. Nothing the forge wrote reaches
  it but a username, cut to the characters a username is made of: the mouse
  reads the comments itself, as data.

  Rounds in a row that pushed nothing are counted; the round after the third
  is a question to the person instead, and so is a mouse the owl started that
  died before saying anything. While that question is open no round runs.
  """

  alias Whiska.Brief
  alias Whiska.Forge
  alias Whiska.MergeRequests
  alias Whiska.MousePane
  alias Whiska.Question.FromOwl
  alias Whiska.Schema.MergeRequestRead
  alias Whiska.Schema.Mouse
  alias Whiska.Schema.Question

  @replies ".whiska-replies"

  @ready ~w(idle done)
  @waiting ~w(open sent)
  @cap 3

  @typedoc """
  What the owl knows when it judges a round. `panes` is herdr's answer;
  `in_flight?` whether the mouse's transcript has background work out;
  `starting?` whether a mouse is being started for it now; `picked_up?`
  whether the owl carried on its died turn this minute; `pushed?` whether the
  last round pushed.
  """
  @type facts :: %{
          mouse: Mouse.t(),
          row: MergeRequestRead.t(),
          questions: [Question.t()],
          panes: {:ok, [map()]} | term(),
          main_pane: String.t() | nil,
          in_flight?: boolean(),
          starting?: boolean(),
          picked_up?: boolean(),
          pushed?: boolean()
        }

  @type verdict :: {:wake, map()} | :start | {:keep, atom()} | {:ask, :cap | :died} | :nothing

  @doc "What the owl does with the review kept for a mouse. The first rule to refuse is the answer."
  @spec judge(facts()) :: verdict()
  def judge(facts) do
    case decide(facts) do
      :start -> if_askable(facts, :start)
      {:ask, _why} = ask -> if_askable(facts, ask)
      verdict -> verdict
    end
  end

  # A start that fails is a question too, so neither goes ahead on a branch
  # whose name cannot be put in one.
  defp if_askable(facts, verdict),
    do: if(FromOwl.askable?(facts.mouse), do: verdict, else: {:keep, :cannot_ask})

  defp decide(%{row: row} = facts) do
    with :ok <- open(row),
         :ok <- not_asked(row),
         :ok <- not_starting(facts),
         :ok <- said_something(facts),
         :ok <- kept(row),
         :ok <- not_held(facts.mouse),
         :ok <- nothing_waiting(facts.questions) do
      if live?(facts.mouse), do: wake(facts), else: start(facts)
    end
  end

  defp open(%MergeRequestRead{state: "open"}), do: :ok
  defp open(_closed), do: :nothing

  defp kept(row), do: if(MergeRequestRead.pending(row), do: :ok, else: :nothing)

  defp not_asked(%MergeRequestRead{review_asked_at: nil}), do: :ok
  defp not_asked(_asked), do: {:keep, :asked}

  defp not_starting(%{starting?: true}), do: {:keep, :starting}
  defp not_starting(_facts), do: :ok

  defp not_held(%Mouse{held_at: %DateTime{}}), do: {:keep, :held}
  defp not_held(_mouse), do: :ok

  defp nothing_waiting(questions) do
    cond do
      Enum.any?(questions, &(&1.status in @waiting)) ->
        {:keep, :waiting_on_you}

      Enum.any?(questions, &(&1.status == "answered" and is_nil(&1.taken_at))) ->
        {:keep, :answer_not_taken}

      true ->
        :ok
    end
  end

  defp live?(%Mouse{died_at: nil, removed_at: nil, path: path}) when is_binary(path),
    do: File.dir?(path)

  defp live?(_mouse), do: false

  defp wake(facts) do
    cond do
      facts.picked_up? -> {:keep, :picked_up}
      facts.in_flight? -> {:keep, :in_flight}
      true -> with {:wake, _pane} = wake <- pane(facts), :ok <- under_cap(facts), do: wake
    end
  end

  defp start(%{panes: {:ok, _panes}} = facts), do: with(:ok <- under_cap(facts), do: :start)
  defp start(_no_herdr), do: {:keep, :no_herdr}

  defp pane(%{panes: {:ok, panes}} = facts) do
    case MousePane.agent_panes(facts.mouse, panes) do
      [%{agent: "claude", agent_status: status} = pane] when status in @ready ->
        if pane.pane_id == facts.main_pane, do: {:keep, :main_session}, else: {:wake, pane}

      [%{agent: "claude"}] ->
        {:keep, :working}

      [_other_agent] ->
        {:keep, :no_claude}

      [] ->
        {:keep, :no_pane}

      _many ->
        {:keep, :many_panes}
    end
  end

  defp pane(_no_herdr), do: {:keep, :no_herdr}

  defp under_cap(%{row: row, pushed?: pushed?}) do
    if unpushed(row, pushed?) >= @cap, do: {:ask, :cap}, else: :ok
  end

  @doc "Whether `row` is a round the owl started a mouse for, which `judge/1` watches until it says something."
  @spec started?(MergeRequestRead.t()) :: boolean()
  def started?(%MergeRequestRead{round_by: "started", round_at: %DateTime{}}), do: true
  def started?(_row), do: false

  # A mouse the owl started that is dead and has asked nothing since, a report
  # included, ended its round without a word.
  defp said_something(%{row: %MergeRequestRead{round_at: at} = row} = facts) do
    cond do
      not started?(row) or live?(facts.mouse) -> :ok
      Enum.any?(facts.questions, &(&1.asked_by != "owl" and after?(&1, at))) -> :ok
      true -> {:ask, :died}
    end
  end

  defp after?(question, at), do: DateTime.compare(question.asked_at, at) != :lt

  @doc "The rounds in a row that pushed nothing, once the last one is counted."
  @spec unpushed(MergeRequestRead.t(), boolean()) :: non_neg_integer()
  def unpushed(%MergeRequestRead{round_at: nil}, _pushed?), do: 0
  def unpushed(_row, true), do: 0
  def unpushed(%MergeRequestRead{rounds_unpushed: n}, false), do: (n || 0) + 1

  @doc """
  Whether the last round pushed: the branch's `origin` ref, as `ref` reads it
  now, or the forge's head moved since it began.
  """
  @spec pushed?(MergeRequestRead.t(), String.t() | nil) :: boolean()
  def pushed?(%MergeRequestRead{round_at: nil}, _ref), do: false

  def pushed?(%MergeRequestRead{} = row, ref) do
    (is_binary(ref) and is_binary(row.round_ref) and ref != row.round_ref) or
      (is_binary(row.head_sha) and row.head_sha != row.round_head)
  end

  @doc "The folder a mouse writes its replies to, before it posts them."
  @spec replies() :: String.t()
  def replies, do: @replies

  @spec exclude_line() :: String.t()
  def exclude_line, do: "/" <> @replies <> "/"

  @spec rules() :: String.t()
  def rules, do: Brief.review_rules()

  @doc "The letter handing `review` on `mouse`'s merge request over."
  @spec letter(Mouse.t(), MergeRequestRead.review()) :: String.t()
  def letter(%Mouse{merge_request_url: url}, review) do
    {:ok, ref} = Forge.for_url(url)

    items =
      Enum.map(review.comments, fn c ->
        thread = if c.discussion_id, do: ", thread #{c.discussion_id}", else: ""
        what = if c[:open], do: "Open thread", else: "Comment"
        "- #{what} by #{MergeRequests.plain(c.author)}#{thread}: #{ref.url}#note_#{c.id}"
      end) ++
        if review.pipeline,
          do: [
            "- Pipeline #{review.pipeline.id} failed on #{MergeRequests.plain(review.pipeline.sha)}: " <>
              "https://#{ref.host}/#{ref.project}/-/pipelines/#{review.pipeline.id}"
          ],
          else: []

    """
    # New review on #{Forge.label(ref)}

    Whiska read new review on this branch's merge request, #{ref.url}

    #{Enum.join(items, "\n")}

    #{rules()}
    """
  end

  @doc "The one line typed into the mouse's pane, naming its letter."
  @spec line(Path.t()) :: String.t()
  def line(letter_path) do
    "Whiska read new review on your merge request. Read the letter in full, " <>
      "then act on it: #{letter_path}"
  end

  @doc "What is kept of `pending` once `handed` is handed over: whatever came in since."
  @spec rest(MergeRequestRead.review() | nil, MergeRequestRead.review()) ::
          MergeRequestRead.review() | nil
  def rest(nil, _handed), do: nil

  def rest(pending, handed) do
    ids = MapSet.new(handed.comments, & &1.id)

    rest = %{
      comments: Enum.reject(pending.comments, &MapSet.member?(ids, &1.id)),
      pipeline: if(pending.pipeline == handed.pipeline, do: nil, else: pending.pipeline)
    }

    if rest.comments == [] and is_nil(rest.pipeline), do: nil, else: rest
  end
end
