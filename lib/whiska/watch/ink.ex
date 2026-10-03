defmodule Whiska.Watch.Ink do
  @moduledoc """
  The board's colour: plain ANSI, and nothing that fights the dim a stale board
  is wrapped in (ADR-0051, addendum of 2026-10-02).

  Two rules, and both are about somebody else's terminal.

  - **Plain codes only** — `36` for cyan, `33` for yellow, `2` for dim. The
    shade is the person's theme's to pick, so a board drawn in a solarized
    terminal is solarized, and stays right when they switch between the light
    and the dark variant. A hardcoded shade would be right in one of them.
  - **Never a full reset.** The statusline script wraps every line of a stale
    board in `ESC[2m … ESC[0m`, so a `ESC[0m` inside a row would end that dim
    half way along the line and leave the rest of a board nobody is refreshing
    looking live. Colour ends with `39`, "default foreground", and dim with
    `22`, "normal intensity" — each turns off only itself. `22` still ends the
    wrapper's dim as well, which the script puts back (see `Whiska.Install`).
  """

  @doc "The branch: what the person is hunting for on the board."
  @spec cyan(String.t()) :: String.t()
  def cyan(text), do: wrap(text, "36", "39")

  @doc "A question waiting on the person: the one thing on the board for them."
  @spec yellow(String.t()) :: String.t()
  def yellow(text), do: wrap(text, "33", "39")

  @doc "Background to whatever else the row says, never the thing it is for."
  @spec dim(String.t()) :: String.t()
  def dim(text), do: wrap(text, "2", "22")

  defp wrap("", _on, _off), do: ""
  defp wrap(text, on, off), do: "\e[#{on}m" <> text <> "\e[#{off}m"

  @doc "A coloured board read back as the words on it. What tests assert on."
  @spec plain(String.t()) :: String.t()
  def plain(text), do: String.replace(text, ~r/\e\[[0-9;]*m/, "")
end
