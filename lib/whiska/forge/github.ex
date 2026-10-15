defmodule Whiska.Forge.GitHub do
  @moduledoc """
  GitHub, through `gh`: opening a pull request with `gh pr create`, and
  naming one by its link. Not read yet, so the owl leaves its pull requests
  alone (ADR-0060).
  """

  @behaviour Whiska.Forge
  @behaviour Whiska.Forge.Opener

  @link ~r"\Ahttps://([A-Za-z0-9.-]+(?::[0-9]{1,5})?)/([A-Za-z0-9._-]+/[A-Za-z0-9._-]+)/pull/([0-9]+)/?\z"

  @impl true
  def tool, do: "gh"

  @impl Whiska.Forge
  def parse(url) do
    case Regex.run(@link, url) do
      [_, host, project, number] ->
        {:ok,
         %{
           forge: __MODULE__,
           host: host,
           project: project,
           number: String.to_integer(number),
           url: url
         }}

      nil ->
        :error
    end
  end

  @impl Whiska.Forge
  def label(%{number: number}), do: "##{number}"

  @impl Whiska.Forge.Opener
  def create_args(_main_checkout, branch, base, title, file) do
    {:ok,
     ~w(pr create --assignee @me --head) ++
       [branch, "--base", base, "--title", title, "--body-file", file]}
  end

  @impl Whiska.Forge.Opener
  def browse_args(%{url: url}), do: ["pr", "view", url, "--web"]

  @impl Whiska.Forge.Opener
  def link(out) do
    case Regex.scan(~r|https://\S+|, out) |> List.last() do
      [url] -> {:ok, url}
      nil -> {:error, "gh printed no link:\n\n#{String.trim(out)}"}
    end
  end
end
