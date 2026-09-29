defmodule Whiska.Watch.Text do
  @moduledoc """
  Making one phrase safe to put on the board.

  The board is the first thing in Whiska that carries free text a mouse wrote
  into the person's terminal, and a mouse's text is not trusted: it can quote a
  file, a branch name or a command that somebody else wrote. Two things follow,
  and the board file is where both are enforced — not the statusline script,
  which only prints what it is given.

  - **No control characters.** An escape sequence in a row would be run by the
    terminal, not shown: a title change, a screen clear, an alternate-screen
    switch, a carriage return that overwrites the line. The board redraws every
    couple of seconds in every open session, so one would keep happening.
  - **One line, one row.** A newline in what a tool is doing would forge a whole
    extra row — `🐭 main  idle  all clear` is 27 characters — and a forged row
    can say that nothing is waiting. That is the one failure the board must not
    have, so every phrase is flattened to a single line and cut to a width.
  """

  @doc "One line, printable, no longer than `max` characters."
  @spec plain(String.t(), pos_integer()) :: String.t()
  def plain(text, max) do
    text
    |> String.replace(~r/[\x{0}-\x{8}\x{b}-\x{1f}\x{7f}-\x{9f}]/u, "")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> cut(max)
  end

  defp cut(phrase, max) do
    if String.length(phrase) > max,
      do: String.slice(phrase, 0, max - 1) <> "…",
      else: phrase
  end
end
