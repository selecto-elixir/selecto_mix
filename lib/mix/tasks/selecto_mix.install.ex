defmodule Mix.Tasks.SelectoMix.Install do
  @shortdoc "Install Selecto dependencies (alias for selecto.install)"
  @moduledoc """
  Alias task for `mix selecto.install`.

  This task installs Selecto ecosystem dependencies (including
  `:selecto` and `:selecto_components`) and runs SelectoComponents integration.

  ## Usage

      mix selecto_mix.install
      mix selecto_mix.install --development-mode --source your-fork
      mix selecto_mix.install --postgis
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("selecto.install", args)
  end
end
