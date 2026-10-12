defmodule Whiska.BuildPlan do
  @moduledoc """
  The build plan a mouse writes beside its spec, or for a bug once its fix is
  obvious or picked: the shape of the change, reviewed before any code
  (ADR-0063). One file at the worktree root, never committed and
  ignored like the spec; the cold review never reads it (ADR-0049).
  """

  @filename ".whiska-plan.md"

  @spec filename() :: String.t()
  def filename, do: @filename

  @doc "The exclude pattern, anchored like the spec's."
  @spec exclude_line() :: String.t()
  def exclude_line, do: "/" <> @filename
end
