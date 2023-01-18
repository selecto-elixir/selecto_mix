defmodule Mix.Tasks.Selecto.Gen.Domain do
  @moduledoc "The hello mix task: `mix help hello`"
  use Mix.Task

  @doc """
  switches:
   --db get metadata from the DB instead of ecto
   --extender module #source a module to integrate into this domain
   --extender_path where to put
   --umb_live app:module #same as below, for umbrella apps
   --live # create liveview parts
   domain_module
   domain_lower
   liveview_module
   liveview_lower
   root



  """

  @shortdoc "Generate a Selecto Domain module."
  def run(args) do
    # calling our Hello.say() function from earlier
    IO.puts("HERE")

    {_parsed, [dom_mod, dom_lower, live_mod, live_lower, root | joins]} = OptionParser.parse!(args)

    IO.puts( inspect( args ))
    app = Mix.Project.config() |> Keyword.fetch!(:app)
    data = %{
      app: app,
      domain_module_path: "lib/#{app}/test_domain.ex",
      domain_module: "App.TestDomain",
      domain_expansion: "App.TestExpansion",
      liveview_module: "AppWeb.Live.TestLive.ex",
      liveview_module_path: "lib/#{app}_web/live/test_live.ex",
      ### Root is the first table in the domain
      root: "App.Cntx.Test",
      joins: [],
      args: args
    }

    create_files(data)

  end

  def create_files(data) do

  end

  def files_to_generate(data) do
    [
      ### Domain goes in app.constructed.path
      {:eex, "domain.ex", Path.join([])},
      ### Liveview goes in app_web.live
      {:eex, "liveview.ex", "path..."}
    ]
  end

  #### Joins format - can recurse
  ## assoc:(list,of,dependant,joins) ???
  ## joins expansion format:
  ## assoc.subassoc.subassoc


end
