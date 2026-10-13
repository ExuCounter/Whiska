defmodule Whiska.Rule.Persons do
  @moduledoc """
  The person's commands are not a mouse's to run
  (ADR-0079).

  `away`, `hold`, `focus`, `resume`, `reply`, `dismiss` and `close` set or end
  what the person decided — what reaches them, which mouse stops, what a mouse
  is told. `spawn`, `send`, `land`, `pr` and `drop` start, steer, ship or throw
  away a branch, which the person decides from the main session; they are
  judged only as `whiska <word>`, since `pr` and `send` are other programs too.
  Prose in a brief is the only other thing between a mouse and putting the
  whole machine away, holding a sibling, or lifting its own hold, and ADR-0011
  puts a rule like that in the hook, not in prose.

  Judged on the text of a shell command, segment by segment (`Whiska.Shell`):
  `whiska <word>` and the bare word at the head of a command. Reading commands —
  `inbox`, `show`, `questions`, `waiting`, `mice` — are not the person's alone
  and pass. Like every text rule here, it catches the honest case; a mouse set
  on it can write a program (ADR-0024).
  """

  alias Whiska.Shell

  @persons ~w(away hold focus resume reply dismiss close)
  @main_sessions ~w(spawn send land pr drop)

  @type decision :: :allow | {:deny, String.t()}

  @doc "The words that are the person's alone."
  @spec words() :: [String.t()]
  def words, do: @persons ++ @main_sessions

  @doc "Decide one tool call for a mouse."
  @spec decide(String.t(), map()) :: decision()
  def decide("Bash", tool_input) do
    command = Map.get(tool_input, "command", "")

    case Enum.find_value(Shell.segments(command), &persons_word/1) do
      nil -> :allow
      word -> {:deny, reason(word)}
    end
  end

  def decide(_tool_name, _tool_input), do: :allow

  defp persons_word(segment) do
    case segment |> Shell.words() |> Enum.drop_while(&assignment?/1) do
      ["whiska", word | _] when word in @persons or word in @main_sessions -> "whiska #{word}"
      [word | _] when word in @persons -> word
      _ -> nil
    end
  end

  defp assignment?(token), do: token =~ ~r/^[A-Za-z_][A-Za-z0-9_]*=/

  defp reason(word) do
    """
    Whiska denied this: `#{word}` is the person's command, not a mouse's.

    Away, a focus, a hold, the answer to a question, and which branch starts,
    lands or goes are the person's to decide. If the work needs one, say so in
    your report and end the turn; the person decides from their own session.
    """
    |> String.trim()
  end
end
