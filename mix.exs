defmodule Whiska.MixProject do
  use Mix.Project

  def project do
    [
      app: :whiska,
      version: "0.0.1",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      escript: escript(),
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps()
    ]
  end

  # No `mod:` on purpose. The same escript serves the hooks — invoked fresh per
  # event, exiting at once (ADR-0030) — and the owl, which `whiska owl` starts
  # explicitly. Starting the owl on every hook call would be the wrong default.
  def application do
    [extra_applications: [:logger]]
  end

  defp escript do
    [main_module: Whiska.CLI, app: nil]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:ecto_sql, "~> 3.12"},
      {:ecto_sqlite3, "~> 0.17"},
      # The herdr boundary is the one place mocking is allowed (ADR-0031).
      {:mox, "~> 1.2", only: :test}
    ]
  end
end
