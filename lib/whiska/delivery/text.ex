defmodule Whiska.Delivery.Text do
  @moduledoc """
  The one line the owl types into the main session, the hook's reading of it
  back, and the words the hoot says a question in.

  The person sees a cat. `whiska show` prints the question itself, so a line
  that also named the branch, the verb and the id said everything twice. The
  id still rides along, because answers are keyed to it (ADR-0005): written
  in blank space characters, one per digit, closed by a braille blank. Claude
  Code strips every zero-width character from a prompt and trims trailing
  space, but keeps these blanks when a character that is not space closes
  them, so the main session's `UserPromptSubmit` hook reads the id back
  (`id_in/1`) and hands it to the model (ADR-0009).

  One line, no newline anywhere: `agent.prompt` types into a prompt box, and an
  embedded newline would submit half a notification.
  """

  alias Whiska.Question.Marker

  @cat "🐱"
  @close "\u2800"
  @digits ["\u2002", "\u2003", "\u2004", "\u2005", "\u2006"] ++
            ["\u2007", "\u2008", "\u2009", "\u200A", "\u202F"]

  @id_max 12

  @pointer_max 120

  @typedoc "What is still waiting behind a question: every other open question."
  @type more :: %{open: non_neg_integer()}

  @spec line(pos_integer()) :: String.t()
  def line(id) when is_integer(id) and id > 0 do
    blanks = id |> Integer.digits() |> Enum.map_join(&Enum.at(@digits, &1))
    @cat <> blanks <> @close
  end

  @doc "The id a delivered line carries, when the whole prompt is one; nil for anything else."
  @spec id_in(String.t()) :: pos_integer() | nil
  def id_in(prompt) when is_binary(prompt) do
    with @cat <> rest <- String.trim_trailing(prompt, "\n"),
         {blanks, @close} when blanks != "" <- String.split_at(rest, -1),
         true <- String.length(blanks) <= @id_max,
         digits =
           blanks
           |> String.graphemes()
           |> Enum.map(&Enum.find_index(@digits, fn d -> d == &1 end)),
         false <- nil in digits,
         id when id > 0 <- Integer.undigits(digits) do
      id
    else
      _ -> nil
    end
  end

  @doc """
  What the mouse did: `needs a decision`, `finished`, or
  `stopped without saying why`.
  """
  @spec verb(String.t()) :: String.t()
  def verb("unmarked"), do: "stopped without saying why"
  def verb("done"), do: "finished"
  def verb(_), do: "needs a decision"

  @doc """
  The mouse's own pointer, quoted and cut to length, or `nil` when it left
  none.
  """
  @spec pointer(String.t()) :: String.t() | nil
  def pointer(text) do
    case Marker.pointer(text) do
      "" -> nil
      p when byte_size(p) > @pointer_max -> ~s("#{String.slice(p, 0, @pointer_max)}…")
      p -> ~s("#{p}")
    end
  end

  @doc "What is still waiting behind this one, or `nil` for nothing."
  @spec more(more()) :: String.t() | nil
  def more(%{open: 0}), do: nil
  def more(%{open: n}), do: "#{n} more open"

  @doc """
  The line for a letter another repo's main session left here (ADR-0044): the
  sending repo's name, cut to letters, digits, `.`, `_` and `-`, and the path of
  the file. The
  letter's own words are never typed. `:error` for a path that is not UTF-8 or
  holds a control character, which would end the line early.
  """
  @spec letter(String.t(), Path.t()) :: {:ok, String.t()} | :error
  def letter(from_repo, path) do
    if String.valid?(path) and not String.match?(path, ~r/[[:cntrl:]]/u) do
      {:ok, "📨 #{repo_name(from_repo)}'s Whiska sent you a letter: #{path}"}
    else
      :error
    end
  end

  defp repo_name(from_repo) do
    name =
      if String.valid?(from_repo),
        do: String.replace(from_repo, ~r/[^\p{L}\p{N}._-]/u, ""),
        else: ""

    if name == "", do: "another repo", else: name
  end
end
