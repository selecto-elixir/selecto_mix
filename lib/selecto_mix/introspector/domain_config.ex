defmodule SelectoMix.Introspector.DomainConfig do
  @moduledoc false

  @doc false
  @spec build(term(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def build(source, opts \\ []) do
    include_associations = Keyword.get(opts, :include_associations, true)
    redact_fields = Keyword.get(opts, :redact_fields, [])

    case SelectoMix.Introspector.introspect(source, opts) do
      {:ok, metadata} ->
        # Filter associations if not requested
        associations = if include_associations, do: metadata.associations, else: %{}

        # Generate suggested defaults based on metadata
        suggested_defaults =
          generate_suggested_defaults_from_metadata(
            metadata.fields,
            metadata.field_types,
            opts
          )

        # Extract additional metadata
        extra_metadata = extract_metadata_from_source(source, metadata)

        {:ok,
         %{
           schema_module: Map.get(metadata, :schema_module, source),
           table_name: metadata.table_name,
           primary_key: metadata.primary_key,
           fields: metadata.fields,
           field_types: metadata.field_types,
           associations: associations,
           suggested_defaults: suggested_defaults,
           redacted_fields: redact_fields,
           metadata: extra_metadata,
           columns: Map.get(metadata, :columns, %{}),
           source: Map.get(metadata, :source),
           source_kind: Map.get(metadata, :source_kind),
           readonly: Map.get(metadata, :readonly),
           source_type: Map.get(metadata, :source_type, source_type_for(source)),
           adapter: Map.get(metadata, :adapter)
         }}

      {:error, reason} ->
        {:error, "Failed to introspect schema #{inspect(source)}: #{inspect(reason)}"}
    end
  end

  @doc false
  @spec build!(term(), keyword()) :: map()
  def build!(source, opts \\ []) do
    case build(source, opts) do
      {:ok, config} -> config
      {:error, reason} -> Mix.raise(to_string(reason))
    end
  end

  # Generate suggested defaults from field metadata (works with any source)
  defp generate_suggested_defaults_from_metadata(fields, field_types, opts) do
    include_timestamps = Keyword.get(opts, :include_timestamps, false)

    # Suggest reasonable default selected fields
    default_selected = suggest_default_selected_fields(fields, field_types, include_timestamps)

    # Suggest default filters based on common patterns
    default_filters = suggest_default_filters(fields, field_types)

    # Suggest ordering
    default_order = suggest_default_ordering(fields, field_types)

    %{
      default_selected: default_selected,
      default_filters: default_filters,
      default_order: default_order,
      default_limit: Keyword.get(opts, :default_limit, 50)
    }
  end

  # Extract metadata from any source type
  defp extract_metadata_from_source(source, metadata) when is_atom(source) do
    # Ecto schema module
    %{
      module_name: get_module_name(source),
      context_name: get_context_name(source),
      has_timestamps: has_timestamps_in_fields?(metadata.fields),
      estimated_complexity: estimate_complexity_from_metadata(metadata)
    }
  end

  defp extract_metadata_from_source({:db, adapter, _conn, table_name}, metadata) do
    %{
      module_name: module_name_from_table(table_name),
      context_name: adapter_context_name(adapter),
      has_timestamps: has_timestamps_in_fields?(metadata.fields),
      estimated_complexity: estimate_complexity_from_metadata(metadata)
    }
  end

  defp extract_metadata_from_source({:db, adapter, _conn, table_name, _opts}, metadata) do
    %{
      module_name: module_name_from_table(table_name),
      context_name: adapter_context_name(adapter),
      has_timestamps: has_timestamps_in_fields?(metadata.fields),
      estimated_complexity: estimate_complexity_from_metadata(metadata)
    }
  end

  defp extract_metadata_from_source(_source, metadata) do
    %{
      module_name: "Unknown",
      context_name: "Unknown",
      has_timestamps: has_timestamps_in_fields?(metadata.fields),
      estimated_complexity: estimate_complexity_from_metadata(metadata)
    }
  end

  defp has_timestamps_in_fields?(fields) do
    Enum.any?(fields, fn field ->
      field_str = to_string(field)
      String.contains?(field_str, ["inserted_at", "updated_at"])
    end)
  end

  defp estimate_complexity_from_metadata(metadata) do
    field_count = length(metadata.fields)
    assoc_count = map_size(metadata.associations)

    cond do
      field_count <= 5 and assoc_count <= 2 -> :simple
      field_count <= 15 and assoc_count <= 5 -> :moderate
      true -> :complex
    end
  end

  # Private helper functions

  defp suggest_default_selected_fields(fields, field_types, include_timestamps) do
    # Start with common display fields
    candidates =
      Enum.filter(fields, fn field ->
        field_str = to_string(field)

        # Include name/title fields
        name_field = String.contains?(field_str, ["name", "title", "email", "username"])

        # Include ID fields
        id_field = String.ends_with?(field_str, "_id") or field == :id

        # Include status/active fields
        status_field = String.contains?(field_str, ["status", "active", "enabled"])

        # Include timestamps if requested
        timestamp_field = include_timestamps and String.contains?(field_str, ["_at", "date"])

        # Exclude binary and large text fields from defaults
        suitable_type =
          field_types[field] in [:string, :integer, :decimal, :boolean, :date, :utc_datetime]

        (name_field or id_field or status_field or timestamp_field) and suitable_type
      end)

    # Limit to reasonable number of fields
    candidates |> Enum.take(5)
  end

  defp suggest_default_filters(fields, field_types) do
    # Look for common filter patterns
    filter_fields =
      Enum.filter(fields, fn field ->
        field_str = to_string(field)
        field_type = field_types[field]

        # Boolean fields make good filters
        boolean_filter = field_type == :boolean

        # Status/category fields
        status_filter = String.contains?(field_str, ["status", "type", "category", "role"])

        # Date fields for range filtering
        date_filter =
          field_type in [:date, :utc_datetime] and
            String.contains?(field_str, ["created", "updated"])

        boolean_filter or status_filter or date_filter
      end)

    # Generate filter configurations
    Enum.into(filter_fields, %{}, fn field ->
      field_type = field_types[field]
      filter_config = generate_filter_config(field, field_type)
      {to_string(field), filter_config}
    end)
  end

  defp generate_filter_config(field, field_type) do
    _field_str = to_string(field)

    base_config = %{
      name: humanize_field_name(field),
      type: filter_type_for_selecto_type(field_type)
    }

    case field_type do
      :boolean ->
        Map.put(base_config, :default, true)

      type when type in [:date, :utc_datetime] ->
        Map.put(base_config, :operator, "gte")

      _ ->
        base_config
    end
  end

  defp filter_type_for_selecto_type(selecto_type) do
    case selecto_type do
      :boolean -> :boolean
      :integer -> :integer
      :decimal -> :decimal
      :float -> :float
      :date -> :date
      :utc_datetime -> :utc_datetime
      :naive_datetime -> :naive_datetime
      :string -> :string
      :text -> :string
      _ -> :string
    end
  end

  defp suggest_default_ordering(fields, field_types) do
    # Look for good ordering fields
    order_candidates =
      Enum.filter(fields, fn field ->
        field_str = to_string(field)
        field_type = field_types[field]

        # Timestamp fields for chronological ordering
        timestamp_field =
          field_type in [:date, :utc_datetime] and
            String.contains?(field_str, ["created", "updated", "published"])

        # Name fields for alphabetical ordering
        name_field =
          field_type == :string and
            String.contains?(field_str, ["name", "title"])

        # ID for natural ordering
        id_field = field == :id

        timestamp_field or name_field or id_field
      end)

    case order_candidates do
      [] -> []
      [first | _] -> [%{"field" => to_string(first), "direction" => "asc"}]
    end
  end

  defp get_module_name(schema_module) do
    schema_module
    |> Module.split()
    |> List.last()
  end

  defp get_context_name(schema_module) do
    parts = Module.split(schema_module)

    case parts do
      [_app, context | _] -> context
      _ -> "Unknown"
    end
  end

  defp humanize_field_name(field) do
    field
    |> to_string()
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end

  defp source_type_for(source) when is_atom(source), do: :ecto
  defp source_type_for({:db, _adapter, _conn, _table_name}), do: :db
  defp source_type_for({:db, _adapter, _conn, _table_name, _opts}), do: :db
  defp source_type_for(_source), do: :unknown

  defp module_name_from_table(table_name) do
    table_name
    |> to_string()
    |> String.trim()
    |> String.trim_leading("public.")
    |> SelectoMix.Inflect.singularize()
    |> Macro.camelize()
  end

  defp adapter_context_name(adapter) when is_atom(adapter) do
    adapter
    |> Module.split()
    |> Enum.at(-2, "Database")
    |> to_string()
    |> String.replace_prefix("SelectoDB", "")
  end

  defp adapter_context_name(_adapter), do: "Database"
end
