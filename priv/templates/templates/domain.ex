defmodule <%= inspect data.module %> do

  ### A module that has implements behavior Selecto.Domain.Expansion
  ### Allows you to add configuration without editing this file
  @expansion <%= inspect data.expansion_source %>

  def domain() do
    %{
      source: <%= data.root %>,



    }
  end

  @recreate """
    This file was created with the command:

    mix selecto.gen.domain <%= data.args %>
  """

end
