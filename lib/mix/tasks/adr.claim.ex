defmodule Mix.Tasks.Adr.Claim do
  @shortdoc "Give this branch's placeholder ADRs their numbers, just before it merges"
  @moduledoc """
  Run on the branch, right before the person merges it into main. Every
  `docs/adr/next-<slug>.md` takes the next number free on both this branch and main,
  and every citation of it is rewritten to match. Nothing is committed.
  """
  use Mix.Task

  @impl true
  def run(_args) do
    root = File.cwd!()

    case Whiska.Adr.claim(root, Whiska.Adr.view(root)) do
      [] -> Mix.shell().info("No placeholder ADRs on this branch.")
      claimed -> Enum.each(claimed, fn {old, new} -> Mix.shell().info("#{old} -> #{new}") end)
    end
  end
end
