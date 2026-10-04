defmodule Whiska.ShapeTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Whiska.Shape

  @models_file "priv/models.json" |> File.read!() |> JSON.decode!()

  test "the models are the ones priv/models.json lists" do
    assert Shape.models() == @models_file["models"]
  end

  test "each mode starts on the model priv/models.json gives it" do
    for {mode, model} <- @models_file["defaults"] do
      assert Shape.parse([mode]) == {:ok, %{mode: mode, model: model}}
    end
  end

  test "the help names every model and each mode's default from priv/models.json" do
    help = capture_io(fn -> Whiska.CLI.run(["--help"]) end)

    assert help =~ "--model " <> Enum.join(@models_file["models"], "|")

    for {mode, model} when is_binary(model) <- @models_file["defaults"] do
      assert help =~ "A #{mode} mouse starts on #{model}"
    end
  end

  test "no source or shipped skill names a model, so adding one is a one-file edit" do
    for path <- Path.wildcard("lib/**/*.ex") ++ Path.wildcard("priv/skills/**/*.md"),
        model <- @models_file["models"] do
      refute File.read!(path) =~ ~r/\b#{model}\b/,
             "#{path} names #{model}; it belongs in priv/models.json"
    end
  end
end
