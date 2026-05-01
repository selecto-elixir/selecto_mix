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
  end
end

defmodule SelectoMix.DomainExportTaskTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

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
