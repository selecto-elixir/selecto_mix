defmodule SelectoMix.DomainDocs do
  @moduledoc """
  Renders Markdown documentation from normalized Selecto domain artifacts.

  The docs renderer consumes the same checked artifact shape used by
  `selecto.domain.check`, `inspect`, and `diff`, so it documents the portable
  normalized JSON artifact rather than requiring the original domain module.
  """

  alias SelectoMix.DomainExport

  @section_order [:canonical, :projection, :proposed, :unknown]
  @count_order [
    :source_fields,
    :source_columns,
    :schemas,
    :joins,
    :filters,
    :functions,
    :query_members,
    :published_views,
    :source_relationships,
    :choice_sources
  ]

  @registry_sections [
    {"Joins", "joins"},
    {"Filters", "filters"},
    {"Functions", "functions"},
    {"Published Views", "published_views"},
    {"Detail Actions", "detail_actions"},
    {"Writes", "writes"},
    {"Capabilities", "capabilities"},
    {"Actions", "actions"},
    {"Source Relationships", "source_relationships"},
    {"Choice Sources", "choice_sources"}
  ]

  @spec render_file(Path.t(), keyword()) ::
          {:ok, String.t()} | {:error, DomainExport.artifact_error()}
  def render_file(path, opts \\ []) do
    with {:ok, check} <- DomainExport.check_file(path, opts) do
      {:ok, render_check(check)}
    end
  end

  @spec render_check(map()) :: String.t()
  def render_check(%{artifact: artifact} = check) do
    summary = DomainExport.summary(check)
    domain = Map.get(artifact, "domain", %{})

    render(summary, domain)
  end

  @spec render(map(), map()) :: String.t()
  def render(summary, domain) do
    [
      "# #{heading(summary)}",
      "",
      "Generated from a normalized Selecto domain artifact.",
      "",
      artifact_section(summary),
      sections_section(summary),
      counts_section(summary),
      source_section(domain),
      schemas_section(domain),
      registries_section(domain),
      query_members_section(domain),
      diagnostics_section(summary)
    ]
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp artifact_section(summary) do
    [
      "## Artifact",
      "",
      "| Key | Value |",
      "| --- | --- |",
      table_row("Path", Map.get(summary, :path) || "(unknown)"),
      table_row("Format", "#{Map.get(summary, :format)} v#{Map.get(summary, :format_version)}"),
      table_row("Domain module", Map.get(summary, :domain_module) || "(unknown)"),
      table_row("Schema version", Map.get(summary, :schema_version) || "(unknown)"),
      ""
    ]
  end

  defp sections_section(summary) do
    sections = Map.fetch!(summary, :sections)

    [
      "## Sections",
      "",
      "| Class | Sections |",
      "| --- | --- |"
    ] ++
      Enum.map(@section_order, fn section_class ->
        table_row(format_key(section_class), format_list(Map.get(sections, section_class, [])))
      end) ++
      [""]
  end

  defp counts_section(summary) do
    counts = Map.fetch!(summary, :counts)

    [
      "## Counts",
      "",
      "| Item | Count |",
      "| --- | --- |"
    ] ++
      Enum.map(@count_order, fn count_key ->
        table_row(format_key(count_key), Map.get(counts, count_key, 0))
      end) ++
      [""]
  end

  defp source_section(domain) do
    source = map_get(domain, "source", %{})
    columns = map_get(source, "columns", %{})

    [
      "## Source",
      "",
      "| Key | Value |",
      "| --- | --- |",
      table_row("Table", source_table(source)),
      table_row("Primary key", map_get(source, "primary_key") || "(unknown)"),
      table_row("Fields", format_list(map_get(source, "fields", []))),
      ""
    ] ++ source_columns_section(columns)
  end

  defp source_columns_section(columns) when is_map(columns) and map_size(columns) > 0 do
    [
      "### Source Columns",
      "",
      "| Field | Type | Label |",
      "| --- | --- | --- |"
    ] ++
      Enum.map(sorted_entries(columns), fn {field, column} ->
        table_row([
          field,
          column_value(column, "type"),
          label_value(column)
        ])
      end) ++
      [""]
  end

  defp source_columns_section(_columns), do: []

  defp schemas_section(domain) do
    schemas = map_get(domain, "schemas", %{})

    if is_map(schemas) and map_size(schemas) > 0 do
      [
        "## Schemas",
        "",
        "| Schema | Table | Columns |",
        "| --- | --- | --- |"
      ] ++
        Enum.map(sorted_entries(schemas), fn {schema_id, schema} ->
          columns = map_get(schema, "columns", %{})

          table_row([
            schema_id,
            source_table(schema),
            if(is_map(columns), do: map_size(columns), else: 0)
          ])
        end) ++
        [""]
    else
      ["## Schemas", "", "(none)", ""]
    end
  end

  defp registries_section(domain) do
    sections =
      @registry_sections
      |> Enum.flat_map(fn {title, key} ->
        registry_section(title, map_get(domain, key, %{}))
      end)

    case sections do
      [] ->
        ["## Registries", "", "(none)", ""]

      sections ->
        ["## Registries", ""] ++ sections
    end
  end

  defp registry_section(_title, registry) when not is_map(registry), do: []
  defp registry_section(_title, registry) when map_size(registry) == 0, do: []

  defp registry_section(title, registry) do
    [
      "### #{title}",
      "",
      "| Id | Label | Kind | Target |",
      "| --- | --- | --- | --- |"
    ] ++
      Enum.map(sorted_entries(registry), fn {id, spec} ->
        table_row([
          id,
          label_value(spec),
          first_value(spec, ["kind", "type", "source", "mode"]),
          first_value(spec, ["field", "relation", "source_table", "table", "target"])
        ])
      end) ++
      [""]
  end

  defp query_members_section(domain) do
    query_members = map_get(domain, "query_members", %{})

    if is_map(query_members) and map_size(query_members) > 0 do
      [
        "## Query Members",
        "",
        "| Group | Member | Label | Kind |",
        "| --- | --- | --- | --- |"
      ] ++
        Enum.flat_map(sorted_entries(query_members), fn {group, members} ->
          query_member_rows(group, members)
        end) ++
        [""]
    else
      []
    end
  end

  defp query_member_rows(group, members) when is_map(members) do
    Enum.map(sorted_entries(members), fn {member_id, spec} ->
      table_row([
        group,
        member_id,
        label_value(spec),
        first_value(spec, ["kind", "type", "source"])
      ])
    end)
  end

  defp query_member_rows(group, members) when is_list(members) do
    Enum.map(members, fn member_id ->
      table_row([group, member_id, "", ""])
    end)
  end

  defp query_member_rows(_group, _members), do: []

  defp diagnostics_section(summary) do
    diagnostics = Map.fetch!(summary, :diagnostics)

    [
      "## Diagnostics",
      "",
      "| Scope | Errors | Warnings | Error Codes | Warning Codes |",
      "| --- | ---: | ---: | --- | --- |",
      diagnostic_row("Artifact", Map.fetch!(diagnostics, :artifact)),
      diagnostic_row("Current", Map.fetch!(diagnostics, :current)),
      ""
    ]
  end

  defp diagnostic_row(label, diagnostics) do
    table_row([
      label,
      Map.get(diagnostics, :errors, 0),
      Map.get(diagnostics, :warnings, 0),
      format_list(Map.get(diagnostics, :error_codes, [])),
      format_list(Map.get(diagnostics, :warning_codes, []))
    ])
  end

  defp heading(summary), do: Map.get(summary, :name) || "Selecto Domain"

  defp source_table(source) do
    map_get(source, "source_table") ||
      map_get(source, "table_name") ||
      map_get(source, "name") ||
      "(unknown)"
  end

  defp label_value(spec) do
    first_value(spec, ["label", "name", "title", "display_name", "display"])
  end

  defp column_value(column, key), do: first_value(column, [key])

  defp first_value(spec, keys) when is_map(spec) do
    Enum.find_value(keys, fn key ->
      case map_get(spec, key) do
        nil -> nil
        "" -> nil
        value -> value
      end
    end) || ""
  end

  defp first_value(_spec, _keys), do: ""

  defp sorted_entries(map) when is_map(map) do
    map
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
  end

  defp table_row(label, value), do: table_row([label, value])

  defp table_row(values) do
    cells =
      values
      |> Enum.map(&format_cell/1)
      |> Enum.join(" | ")

    "| #{cells} |"
  end

  defp format_cell(nil), do: ""
  defp format_cell(value) when is_binary(value), do: escape_markdown(value)
  defp format_cell(value) when is_atom(value), do: value |> Atom.to_string() |> escape_markdown()
  defp format_cell(value) when is_integer(value), do: Integer.to_string(value)
  defp format_cell(value) when is_float(value), do: Float.to_string(value)

  defp format_cell(%{"$selecto_export" => type} = value) do
    [type, map_get(value, "inspect")]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" ")
    |> escape_markdown()
  end

  defp format_cell(%{} = value) do
    value
    |> Map.keys()
    |> Enum.map(&to_string/1)
    |> Enum.sort()
    |> Enum.join(", ")
    |> escape_markdown()
  end

  defp format_cell(value) when is_list(value), do: value |> format_list() |> escape_markdown()
  defp format_cell(value), do: value |> inspect() |> escape_markdown()

  defp format_list([]), do: "(none)"

  defp format_list(values) when is_list(values) do
    values
    |> Enum.map(&to_string/1)
    |> Enum.join(", ")
  end

  defp format_list(value), do: to_string(value)

  defp format_key(key) do
    key
    |> to_string()
    |> String.replace("_", " ")
  end

  defp escape_markdown(value) do
    value
    |> String.replace("|", "\\|")
    |> String.replace("\n", " ")
  end

  defp map_get(map, key, default \\ nil)

  defp map_get(map, key, default) when is_map(map) and is_binary(key) do
    atom_key = existing_atom(key)

    cond do
      Map.has_key?(map, key) -> Map.get(map, key)
      atom_key && Map.has_key?(map, atom_key) -> Map.get(map, atom_key)
      true -> default
    end
  end

  defp map_get(map, key, default) when is_map(map) and is_atom(key) do
    string_key = Atom.to_string(key)

    cond do
      Map.has_key?(map, key) -> Map.get(map, key)
      Map.has_key?(map, string_key) -> Map.get(map, string_key)
      true -> default
    end
  end

  defp map_get(_map, _key, default), do: default

  defp existing_atom(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> nil
  end
end
