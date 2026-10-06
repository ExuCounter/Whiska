defmodule Whiska.ClaudeMd do
  @moduledoc """
  Whiska's marked block in a `CLAUDE.md`, and the parts of it the person claimed.

  A session's rules arrive at session start, by role (`Whiska.Rules`,
  ADR-next-rules-arrive-by-role), and Claude Code loads every `CLAUDE.md` on top
  of them. So a block an older Whiska wrote is taken out, and a part the person
  holds as `keep` is read so the hook can leave it out:

  - **`remove/1`** — on `whiska init`, so no rule reaches a session twice, and
    on `whiska uninstall`.
  - **`kept/1`** — the parts the person holds in their own words.

  ## The grammar, still ADR-0045's

  One outer `<!-- whiska:start -->` … `<!-- whiska:end -->` pair bounds what
  Whiska will touch at all, and inside it each part carries its own named pair
  — `<!-- whiska:report:start -->` and so on. A part with `keep` on its start
  marker is the person's.

  Pure values, so what gets taken out and what is left exactly alone is
  testable without a filesystem.
  """

  @outer_start "<!-- whiska:start -->"
  @outer_end "<!-- whiska:end -->"
  @outer_start_line ~r/^<!-- whiska:start -->$/m
  @outer_end_line ~r/^<!-- whiska:end -->$/m

  # A start marker, with the optional `keep` that makes the part the person's.
  # Anchored to whole lines: a marker is always alone on its own line, so a
  # sentence in prose that happens to mention one is never mistaken for one.
  @part_start ~r/^<!-- whiska:([a-z-]+):start( keep)? -->$/m

  # The comment every older Whiska put at the top of its block, in either scope.
  # It quotes a part marker of its own, `keep -->` included, so it ends at the
  # first `-->` after the ADR it names.
  @header ~r/<!-- Whiska wrote this block.*?ADR-0045\..*?-->/s

  @doc """
  The names of the parts a `CLAUDE.md` holds as `keep`, wherever they sit.

  Read across the whole file rather than only inside the outer markers: a part
  the person kept survives an uninstall without them (`remove/1`), and it is
  still theirs.
  """
  @spec kept(String.t()) :: [String.t()]
  def kept(contents) when is_binary(contents) do
    for {:part, name, true, _raw} <- segments(contents), uniq: true, do: name
  end

  @doc """
  Take Whiska's block out — on `whiska init`, and on `whiska uninstall`.

  Text outside the outer markers comes back byte for byte. Inside them, what
  goes is what Whiska wrote: its header comment and every part not marked
  `keep`. What stays is the person's: a `keep` part, markers and all, and any
  text of their own between parts. With nothing of theirs left inside, the
  outer markers go too and the file reads as though Whiska had never been here.
  """
  @spec remove(String.t()) :: String.t()
  def remove(contents) when is_binary(contents) do
    case split_outer(contents) do
      :none ->
        contents

      {before_block, inside, after_block} ->
        kept = inside |> segments() |> Enum.map_join(&theirs/1) |> String.trim()

        case kept do
          "" ->
            strip_outer(before_block, after_block)

          kept ->
            before_block <> "\n" <> kept <> "\n" <> after_block
        end
    end
  end

  # A `keep` part is the person's, and so is any text of theirs between parts.
  # Whiska's own header comment, and the blank lines it left between parts, go.
  defp theirs({:part, _name, true, raw}), do: raw <> "\n"
  defp theirs({:part, _name, false, _raw}), do: ""

  defp theirs({:other, text}) do
    case text |> String.replace(@header, "") |> String.trim() do
      "" -> ""
      own -> "\n" <> own <> "\n"
    end
  end

  # Nothing of the person's was inside, so the markers go too — along with the
  # blank line that separated the block from whatever came before it.
  defp strip_outer(before_block, after_block) do
    head = before_block |> String.replace_suffix(@outer_start, "") |> String.trim_trailing()
    tail = after_block |> String.replace_prefix(@outer_end, "") |> String.trim_leading("\n")

    case {head, tail} do
      {"", ""} -> ""
      {"", tail} -> tail
      {head, ""} -> head <> "\n"
      {head, tail} -> head <> "\n\n" <> tail
    end
  end

  # The outer markers bound everything Whiska is allowed to rewrite. Only the
  # first pair counts: a second one would mean two blocks, which no Whiska ever
  # wrote, and guessing which was meant would be worse than leaving it be.
  # Like a part's, an outer marker is a whole line of its own; one quoted in a
  # sentence is prose.
  defp split_outer(contents) do
    with [{start_at, start_len}] <- Regex.run(@outer_start_line, contents, return: :index),
         rest_at = start_at + start_len,
         rest = binary_part(contents, rest_at, byte_size(contents) - rest_at),
         [{end_at, _}] <- Regex.run(@outer_end_line, rest, return: :index) do
      {binary_part(contents, 0, rest_at), binary_part(rest, 0, end_at),
       binary_part(rest, end_at, byte_size(rest) - end_at)}
    else
      _ -> :none
    end
  end

  # In order: the parts, and the text between them. A start marker with no
  # matching end is not a part at all — it is text, and copying it through
  # unchanged is the only safe reading of a half-written marker. Only that
  # marker line is text: the parts after it are still read.
  defp segments(inside) do
    case Regex.run(@part_start, inside, return: :index) do
      nil ->
        [{:other, inside}]

      [{start_at, start_len}, {name_at, name_len} | rest] ->
        name = binary_part(inside, name_at, name_len)
        keep = rest != [] and match?({_, _}, hd(rest)) and elem(hd(rest), 0) >= 0
        before_part = binary_part(inside, 0, start_at)
        after_start = binary_part(inside, start_at, byte_size(inside) - start_at)

        case close(after_start, name, start_len) do
          nil ->
            marker_end = start_at + start_len
            rest = binary_part(inside, marker_end, byte_size(inside) - marker_end)
            [{:other, text} | more] = segments(rest)
            [{:other, binary_part(inside, 0, marker_end) <> text} | more]

          {raw, remainder} ->
            [{:other, before_part}, {:part, name, keep, raw} | segments(remainder)]
        end
    end
  end

  # The part ends at its own name's end marker. A different name's end marker in
  # between means the file is malformed; matching only on the name keeps the
  # damage to that one part rather than swallowing its neighbours.
  defp close(text, name, start_len) do
    ending = "<!-- whiska:#{name}:end -->"

    case String.split(text, ending, parts: 2) do
      [body, remainder] when byte_size(body) >= start_len ->
        {body <> ending, remainder}

      _ ->
        nil
    end
  end
end
