unless Code.ensure_loaded?(Selecto) do
  defmodule Selecto do
    def configure(domain, _connection, _opts \\ []), do: {:configured, domain}
    def from_ecto(repo, schema, opts \\ []), do: {:from_ecto, repo, schema, opts}
    def select(selecto, _fields), do: selecto
    def filter(selecto, _filter), do: selecto
    def execute(_selecto), do: {:ok, []}
    def execute_one(_selecto), do: {:ok, nil}
  end
end

unless Code.ensure_loaded?(Selecto.Config.Overlay) do
  defmodule Selecto.Config.Overlay do
    def merge(domain, overlay) when is_map(domain) and is_map(overlay),
      do: Map.merge(domain, overlay)
  end
end

unless Code.ensure_loaded?(Selecto.DomainValidator) do
  defmodule Selecto.DomainValidator do
    def validate_domain(_domain), do: :ok
  end
end

unless Code.ensure_loaded?(Selecto.DomainValidator.ValidationError) do
  defmodule Selecto.DomainValidator.ValidationError do
    defexception [:errors]

    @impl Exception
    def message(%{errors: errors}), do: "Selecto domain validation failed: #{inspect(errors)}"
  end
end

unless Code.ensure_loaded?(Selecto.Domain) do
  defmodule Selecto.Domain do
    def normalize(domain) when is_map(domain) do
      schema_version = Map.get(domain, :schema_version) || Map.get(domain, "schema_version") || 1

      {:ok, %{schema_version: schema_version, domain: domain},
       %{
         errors: [],
         warnings: [],
         schema_version: schema_version,
         schema_version_inferred: false,
         canonical_sections: [:source, :schemas, :joins, :filters, :functions, :published_views],
         projection_sections: [],
         proposed_sections: [],
         unknown_sections: []
       }}
    end

    def normalize(_domain) do
      {:error, %{errors: [%{code: :invalid_domain}], warnings: []}}
    end

    def describe(%{schema_version: schema_version, domain: domain}) when is_map(domain) do
      source = map_get(domain, "source", %{})
      filters = map_get(domain, "filters", %{})
      functions = map_get(domain, "functions", %{})
      joins = map_get(domain, "joins", %{})
      source_relationships = map_get(domain, "source_relationships", %{})
      choice_sources = map_get(domain, "choice_sources", %{})

      {:ok,
       %{
         schema_version: schema_version,
         name: map_get(domain, "name"),
         sections: %{
           canonical: [:source, :schemas, :joins, :filters, :functions, :published_views],
           projection: [],
           proposed: [],
           unknown: []
         },
         diagnostics: %{
           error_count: 0,
           warning_count: 0,
           error_codes: [],
           warning_codes: [],
           schema_version_inferred: false
         },
         projections: [:query, :write, :ui, :api, :query_contract],
         counts: %{
           source_fields: source |> map_get("fields", []) |> length_or_zero(),
           schemas: domain |> map_get("schemas", %{}) |> map_size_or_zero(),
           joins: map_size_or_zero(joins),
           filters: map_size_or_zero(filters),
           functions: map_size_or_zero(functions),
           query_members: 0,
           custom_columns: 0,
           writes: %{operations: 0, fields: 0, transitions: 0, validations: 0, constraints: 0},
           actions: domain |> map_get("actions", %{}) |> map_size_or_zero(),
           capabilities: domain |> map_get("capabilities", %{}) |> map_size_or_zero(),
           source_relationships: map_size_or_zero(source_relationships),
           choice_sources: map_size_or_zero(choice_sources),
           field_choice_bindings: 0,
           warnings: 0,
           errors: 0
         },
         registries: %{
           source_fields: source |> map_get("fields", []) |> string_list(),
           schemas: domain |> map_get("schemas", %{}) |> sorted_keys(),
           schema_fields: %{},
           joins: sorted_keys(joins),
           filters: sorted_keys(filters),
           functions: sorted_keys(functions),
           query_members: [],
           custom_columns: [],
           actions: domain |> map_get("actions", %{}) |> sorted_keys(),
           capabilities: domain |> map_get("capabilities", %{}) |> sorted_keys(),
           source_relationships: sorted_keys(source_relationships),
           choice_sources: sorted_keys(choice_sources)
         },
         writes: %{
           operations: [],
           fields: [],
           transitions: [],
           validations_count: 0,
           constraints_count: 0
         },
         actions: [],
         capabilities: [],
         source_relationships: [],
         choice_sources: [],
         field_choice_bindings: []
       },
       %{errors: [], warnings: [], schema_version: schema_version, schema_version_inferred: false}}
    end

    def describe(domain) when is_map(domain) do
      with {:ok, normalized, _diagnostics} <- normalize(domain) do
        describe(normalized)
      end
    end

    def describe(_domain) do
      {:error, %{errors: [%{code: :invalid_domain}], warnings: []}}
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

    defp sorted_keys(value) when is_map(value) do
      value
      |> Map.keys()
      |> string_list()
    end

    defp sorted_keys(_value), do: []

    defp string_list(values) when is_list(values) do
      values
      |> Enum.map(&to_string/1)
      |> Enum.sort()
    end

    defp string_list(_values), do: []

    defp length_or_zero(value) when is_list(value), do: length(value)
    defp length_or_zero(_value), do: 0

    defp map_size_or_zero(value) when is_map(value), do: map_size(value)
    defp map_size_or_zero(_value), do: 0

    defp existing_atom(value) do
      String.to_existing_atom(value)
    rescue
      ArgumentError -> nil
    end
  end
end

defmodule SelectoMix.DomainExportTaskTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SelectoMix.DomainGenerator

  defmodule DemoDomain do
    def domain do
      %{
        schema_version: 1,
        name: "Demo Items",
        source: %{
          source_table: "demo_items",
          primary_key: :id,
          fields: [:id, :name],
          columns: %{
            id: %{type: :integer, name: "ID"},
            name: %{type: :string, name: "Name"}
          }
        },
        schemas: %{
          customers: %{
            source_table: "customers",
            columns: %{id: %{type: :integer}, name: %{type: :string}}
          }
        },
        joins: %{customer: %{name: "Customer"}},
        filters: %{name: %{type: :string}},
        functions: %{name_lower: %{kind: :scalar}},
        published_views: %{
          "demo_rollup" => %{
            kind: :view,
            query: fn domain -> domain end
          }
        }
      }
    end
  end

  test "exports a normalized domain JSON artifact to stdout" do
    Mix.Task.reenable("selecto.domain.export")

    output =
      capture_io(fn ->
        Mix.Tasks.Selecto.Domain.Export.run([inspect(DemoDomain)])
      end)

    artifact = Jason.decode!(output)

    assert artifact["format"] == "selecto.normalized_domain"
    assert artifact["format_version"] == 1
    assert artifact["domain_module"] == inspect(DemoDomain)
    assert artifact["schema_version"] == 1
    assert artifact["diagnostics"]["errors"] == []
    assert artifact["domain"]["source"]["primary_key"] == "id"
    assert artifact["domain"]["source"]["fields"] == ["id", "name"]

    assert artifact["domain"]["published_views"]["demo_rollup"]["query"]["$selecto_export"] ==
             "function"
  end

  test "writes a normalized domain JSON artifact to --output" do
    in_tmp_dir("selecto_mix_domain_export", fn ->
      Mix.Task.reenable("selecto.domain.export")

      output =
        capture_io(fn ->
          Mix.Tasks.Selecto.Domain.Export.run([
            inspect(DemoDomain),
            "--output",
            "priv/selecto/demo.normalized.json"
          ])
        end)

      assert output =~ "Wrote normalized domain JSON"

      artifact =
        "priv/selecto/demo.normalized.json"
        |> File.read!()
        |> Jason.decode!()

      assert artifact["domain"]["name"] == "Demo Items"
      assert artifact["domain"]["source"]["columns"]["id"]["type"] == "integer"
    end)
  end

  test "checks an exported normalized domain JSON artifact" do
    in_tmp_dir("selecto_mix_domain_check", fn ->
      Mix.Task.reenable("selecto.domain.check")
      assert {:ok, artifact} = SelectoMix.DomainExport.export(DemoDomain)
      File.write!("demo.normalized.json", SelectoMix.DomainExport.encode!(artifact))

      output =
        capture_io(fn ->
          Mix.Tasks.Selecto.Domain.Check.run(["demo.normalized.json"])
        end)

      assert output =~ "Checked normalized domain JSON: demo.normalized.json"
      assert output =~ "Format: selecto.normalized_domain v1"
      assert output =~ "Domain module: #{inspect(DemoDomain)}"
      assert output =~ "Schema version: 1"
      assert output =~ "Diagnostics: 0 errors, 0 warnings"
    end)
  end

  test "inspects an exported normalized domain JSON artifact" do
    in_tmp_dir("selecto_mix_domain_inspect", fn ->
      Mix.Task.reenable("selecto.domain.inspect")
      assert {:ok, artifact} = SelectoMix.DomainExport.export(DemoDomain)
      File.write!("demo.normalized.json", SelectoMix.DomainExport.encode!(artifact))

      output =
        capture_io(fn ->
          Mix.Tasks.Selecto.Domain.Inspect.run(["demo.normalized.json"])
        end)

      assert output =~ "Normalized domain artifact: demo.normalized.json"
      assert output =~ "Name: Demo Items"
      assert output =~ "Sections:"
      assert output =~ "canonical: source, schemas, joins, filters, functions, published_views"
      assert output =~ "source fields: 2"
      assert output =~ "schemas: 1"
      assert output =~ "joins: customer"
      assert output =~ "filters: name"
      assert output =~ "functions: name_lower"
      assert output =~ "published views: demo_rollup"
      assert output =~ "artifact: 0 errors, 0 warnings"
      assert output =~ "current: 0 errors, 0 warnings"
    end)
  end

  test "generates Markdown docs from an exported normalized domain JSON artifact" do
    in_tmp_dir("selecto_mix_domain_docs", fn ->
      Mix.Task.reenable("selecto.domain.docs")
      assert {:ok, artifact} = SelectoMix.DomainExport.export(DemoDomain)
      File.write!("demo.normalized.json", SelectoMix.DomainExport.encode!(artifact))

      output =
        capture_io(fn ->
          Mix.Tasks.Selecto.Domain.Docs.run([
            "demo.normalized.json",
            "--output",
            "docs/selecto/demo.md"
          ])
        end)

      assert output =~ "Wrote normalized domain Markdown docs: docs/selecto/demo.md"

      docs = File.read!("docs/selecto/demo.md")

      assert docs =~ "# Demo Items"
      assert docs =~ "| Domain module | #{inspect(DemoDomain)} |"
      assert docs =~ "## Source"
      assert docs =~ "| Table | demo_items |"
      assert docs =~ "| id | integer | ID |"
      assert docs =~ "| name | string | Name |"
      assert docs =~ "## Registries"
      assert docs =~ "### Filters"
      assert docs =~ "| name |  | string |  |"
      assert docs =~ "### Published Views"
      assert docs =~ "| demo_rollup |  | view |  |"
      assert docs =~ "## Diagnostics"
      assert docs =~ "| Current | 0 | 0 | (none) | (none) |"
    end)
  end

  test "generates Studio inspection JSON from an exported normalized domain JSON artifact" do
    in_tmp_dir("selecto_mix_domain_describe", fn ->
      Mix.Task.reenable("selecto.domain.describe")
      assert {:ok, artifact} = SelectoMix.DomainExport.export(DemoDomain)
      File.write!("demo.normalized.json", SelectoMix.DomainExport.encode!(artifact))

      output =
        capture_io(fn ->
          Mix.Tasks.Selecto.Domain.Describe.run([
            "demo.normalized.json",
            "--output",
            "priv/selecto/demo.inspection.json"
          ])
        end)

      assert output =~
               "Wrote normalized domain inspection JSON: priv/selecto/demo.inspection.json"

      inspection =
        "priv/selecto/demo.inspection.json"
        |> File.read!()
        |> Jason.decode!()

      assert inspection["format"] == "selecto.domain_inspection"
      assert inspection["format_version"] == 1
      assert inspection["source"]["path"] == "demo.normalized.json"
      assert inspection["source"]["domain_module"] == inspect(DemoDomain)
      assert inspection["source"]["name"] == "Demo Items"
      assert inspection["inspection"]["name"] == "Demo Items"
      assert inspection["inspection"]["counts"]["source_fields"] == 2
      assert inspection["inspection"]["counts"]["filters"] == 1
      assert inspection["inspection"]["registries"]["filters"] == ["name"]

      assert inspection["inspection"]["projections"] == [
               "query",
               "write",
               "ui",
               "api",
               "query_contract"
             ]

      assert inspection["diagnostics"]["errors"] == []
      assert inspection["diagnostics"]["schema_version"] == 1
    end)
  end

  test "diffs exported normalized domain JSON artifacts" do
    in_tmp_dir("selecto_mix_domain_diff", fn ->
      Mix.Task.reenable("selecto.domain.diff")
      assert {:ok, artifact} = SelectoMix.DomainExport.export(DemoDomain)

      changed_artifact =
        artifact
        |> update_in(["domain", "filters"], &Map.put(&1, "status", %{"type" => "string"}))
        |> update_in(["domain", "joins"], &Map.delete(&1, "customer"))
        |> update_in(["diagnostics", "unknown_sections"], &["future_section" | &1])
        |> update_in(["diagnostics", "warnings"], &[%{"code" => "unknown_sections"} | &1])

      File.write!("left.normalized.json", SelectoMix.DomainExport.encode!(artifact))
      File.write!("right.normalized.json", SelectoMix.DomainExport.encode!(changed_artifact))

      output =
        capture_io(fn ->
          Mix.Tasks.Selecto.Domain.Diff.run([
            "left.normalized.json",
            "right.normalized.json"
          ])
        end)

      assert output =~ "Normalized domain artifact diff"
      assert output =~ "Left: left.normalized.json"
      assert output =~ "Right: right.normalized.json"
      assert output =~ "filters: 1 -> 2 (+1)"
      assert output =~ "joins: 1 -> 0 (-1)"
      assert output =~ "+ future_section"
      assert output =~ "+ status"
      assert output =~ "- customer"
      assert output =~ "warnings: 0 -> 1 (+1)"
      assert output =~ "+ unknown_sections"
    end)
  end

  test "generated domain files round-trip through export check inspect and diff artifacts" do
    in_tmp_dir("selecto_mix_generated_domain_round_trip", fn ->
      suffix = System.unique_integer([:positive])
      schema_module = Module.concat(["GeneratedRoundTrip#{suffix}"])

      domain_module =
        Module.concat(["TmpRoundTrip.SelectoDomains.GeneratedRoundTrip#{suffix}Domain"])

      overlay_module =
        Module.concat([
          "TmpRoundTrip.SelectoDomains.Overlays.GeneratedRoundTrip#{suffix}DomainOverlay"
        ])

      config = %{
        schema_module: schema_module,
        table_name: "round_trip_items",
        primary_key: :id,
        fields: [:id, :name, :status],
        field_types: %{id: :integer, name: :string, status: :string},
        associations: %{},
        suggested_defaults: %{
          default_selected: [:name],
          default_filters: %{"status" => %{type: :string}},
          default_order: []
        },
        metadata: %{
          module_name: "GeneratedRoundTrip#{suffix}",
          context_name: "RoundTrip"
        }
      }

      generated =
        DomainGenerator.generate_domain_file(schema_module, config, app_name: "TmpRoundTrip")

      Code.compile_string("""
      defmodule #{inspect(overlay_module)} do
        def overlay, do: %{}
      end
      """)

      Code.compile_string(generated)
      assert function_exported?(domain_module, :domain, 0)

      Mix.Task.reenable("selecto.domain.check")
      Mix.Task.reenable("selecto.domain.inspect")
      Mix.Task.reenable("selecto.domain.diff")
      Mix.Task.reenable("selecto.domain.docs")
      Mix.Task.reenable("selecto.domain.describe")

      assert {:ok, artifact} = SelectoMix.DomainExport.export(domain_module)
      File.write!("generated.normalized.json", SelectoMix.DomainExport.encode!(artifact))

      check_output =
        capture_io(fn ->
          Mix.Tasks.Selecto.Domain.Check.run(["generated.normalized.json"])
        end)

      assert check_output =~ "Checked normalized domain JSON: generated.normalized.json"
      assert check_output =~ "Schema version: 1"

      inspect_output =
        capture_io(fn ->
          Mix.Tasks.Selecto.Domain.Inspect.run(["generated.normalized.json"])
        end)

      assert inspect_output =~ "Name: GeneratedRoundTrip#{suffix} Domain"
      assert inspect_output =~ "source fields: 3"
      assert inspect_output =~ "filters: status"

      docs_output =
        capture_io(fn ->
          Mix.Tasks.Selecto.Domain.Docs.run([
            "generated.normalized.json",
            "--output",
            "docs/selecto/generated.md"
          ])
        end)

      assert docs_output =~ "Wrote normalized domain Markdown docs: docs/selecto/generated.md"

      generated_docs = File.read!("docs/selecto/generated.md")

      assert generated_docs =~ "# GeneratedRoundTrip#{suffix} Domain"
      assert generated_docs =~ "| Fields | id, name, status |"
      assert generated_docs =~ "### Filters"
      assert generated_docs =~ "| status |  | string |  |"

      describe_output =
        capture_io(fn ->
          Mix.Tasks.Selecto.Domain.Describe.run([
            "generated.normalized.json",
            "--output",
            "priv/selecto/generated.inspection.json"
          ])
        end)

      assert describe_output =~
               "Wrote normalized domain inspection JSON: priv/selecto/generated.inspection.json"

      generated_inspection =
        "priv/selecto/generated.inspection.json"
        |> File.read!()
        |> Jason.decode!()

      assert generated_inspection["format"] == "selecto.domain_inspection"
      assert generated_inspection["inspection"]["name"] == "GeneratedRoundTrip#{suffix} Domain"
      assert generated_inspection["inspection"]["counts"]["source_fields"] == 3

      changed_artifact =
        update_in(artifact, ["domain", "filters"], fn filters ->
          Map.put(filters, "priority", %{"type" => "integer"})
        end)

      File.write!(
        "generated.changed.normalized.json",
        SelectoMix.DomainExport.encode!(changed_artifact)
      )

      diff_output =
        capture_io(fn ->
          Mix.Tasks.Selecto.Domain.Diff.run([
            "generated.normalized.json",
            "generated.changed.normalized.json"
          ])
        end)

      assert diff_output =~ "filters: 1 -> 2 (+1)"
      assert diff_output =~ "+ priority"
    end)
  end

  test "raises a clear error for an unexpected artifact format" do
    in_tmp_dir("selecto_mix_domain_check_bad_format", fn ->
      Mix.Task.reenable("selecto.domain.check")
      File.write!("bad.json", Jason.encode!(%{"format" => "other", "format_version" => 1}))

      assert_raise Mix.Error, ~r/Unexpected normalized domain artifact format "other"/, fn ->
        Mix.Tasks.Selecto.Domain.Check.run(["bad.json"])
      end
    end)
  end

  test "raises a clear error when the domain module cannot be loaded" do
    Mix.Task.reenable("selecto.domain.export")

    assert_raise Mix.Error, ~r/Domain module Missing.Domain could not be loaded/, fn ->
      Mix.Tasks.Selecto.Domain.Export.run(["Missing.Domain"])
    end
  end

  defp in_tmp_dir(prefix, fun) do
    base_tmp = System.tmp_dir!()
    tmp_dir = Path.join(base_tmp, "#{prefix}_#{System.unique_integer([:positive])}")

    File.rm_rf!(tmp_dir)
    File.mkdir_p!(tmp_dir)

    try do
      File.cd!(tmp_dir, fun)
    after
      File.rm_rf!(tmp_dir)
    end
  end
end
