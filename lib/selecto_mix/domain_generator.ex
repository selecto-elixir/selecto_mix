defmodule SelectoMix.DomainGenerator do
  @moduledoc """
  Generates Selecto domain configuration files from schema introspection data.

  This module creates complete, functional Selecto domain files that users
  can immediately use in their applications. The generated files include
  helpful comments, overlay hooks, and suggested configurations.

  This module is a thin facade; the actual rendering work is split across:

    * a private file-template renderer for generated module source;
    * a private map builder for source, column, association, and join config;
    * private schema-expansion logic for related schemas and inferred names.
  """

  alias SelectoMix.DomainGenerator.{FileTemplate, MapBuilder}

  @doc """
  Generate a complete Selecto domain file.

  Creates a comprehensive domain configuration file with:
  - Schema-based field and type definitions
  - Association configurations for joins
  - Suggested default selections and filters
  - Overlay hooks for user modifications
  - Documentation and usage examples
  """
  def generate_domain_file(schema_module, config, opts \\ []) do
    FileTemplate.render(schema_module, config, opts)
  end

  @doc """
  Resolve the generated domain module name for a source/config pair.
  """
  def domain_module_name(source, config, opts \\ []) do
    FileTemplate.get_domain_module_name(source, config, opts)
  end

  @doc """
  Generate the core domain configuration map.
  """
  def generate_domain_map(config) do
    MapBuilder.generate_domain_map(config)
  end
end
