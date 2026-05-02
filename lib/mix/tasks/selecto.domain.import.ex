defmodule Mix.Tasks.Selecto.Domain.Import do
  @shortdoc "Check a normalized Selecto domain import plan"
  @moduledoc """
  Check a normalized Selecto domain import plan.

  This task is deliberately non-writing in the first import/readback slice.
  `--check` verifies the artifact and reports what a future importer could
  reconstruct. Running without `--check` raises a clear error until generated
  file write semantics are designed.

  ## Examples

      mix selecto.domain.import priv/selecto/product.normalized.json --check

      mix selecto.domain.import priv/selecto/product.normalized.json --check --target-module MyApp.SelectoDomains.ProductDomain
  """

  use Mix.Task

  alias SelectoMix.{DomainExport, DomainImport}

  @requirements ["app.start"]
  @switches [check: :boolean, format: :string, output_dir: :string, target_module: :string]
  @aliases [c: :check]

  @impl Mix.Task
  def run(args) do
    {opts, positional, invalid} = OptionParser.parse(args, strict: @switches, aliases: @aliases)

    cond do
      invalid != [] ->
        Mix.raise("Invalid option(s): #{format_invalid_options(invalid)}")

      positional == [] ->
        Mix.raise("Usage: mix selecto.domain.import priv/selecto/product.normalized.json --check")

      length(positional) > 1 ->
        Mix.raise("Usage: mix selecto.domain.import priv/selecto/product.normalized.json --check")

      not Keyword.get(opts, :check, false) ->
        Mix.raise(
          "Writing normalized domain imports is not implemented yet. Use --check to validate and preview the import plan."
        )

      true ->
        check_import(List.first(positional), opts)
    end
  end

  defp check_import(path, opts) do
    case DomainImport.plan_file(path, opts) do
      {:ok, plan} ->
        print_plan(plan, opts)

      {:error, reason} ->
        Mix.raise(DomainExport.format_error(reason))
    end
  end

  defp print_plan(plan, opts) do
    case Keyword.get(opts, :format, "text") do
      "text" ->
        print_text_plan(plan)

      "json" ->
        IO.write(DomainImport.encode!(plan) <> "\n")

      format ->
        Mix.raise("Unsupported import plan format #{inspect(format)}; expected text or json")
    end
  end

  defp print_text_plan(plan) do
    source = Map.fetch!(plan, "source")
    runtime_placeholders = Map.fetch!(plan, "runtime_placeholders")
    diagnostics = Map.fetch!(plan, "diagnostics")

    Mix.shell().info("Checked normalized domain import plan: #{Map.get(source, "path")}")
    Mix.shell().info("Mode: check (no files written)")
    Mix.shell().info("Domain module: #{Map.get(source, "domain_module") || "(unknown)"}")
    Mix.shell().info("Schema version: #{Map.get(source, "schema_version") || "(unknown)"}")
    Mix.shell().info("Name: #{Map.get(source, "name") || "(unnamed)"}")

    print_preview(Map.fetch!(plan, "preview"))
    print_sections(Map.fetch!(plan, "sections"))
    print_runtime_placeholders(runtime_placeholders)
    print_diagnostics(diagnostics)

    Mix.shell().info("")
    Mix.shell().info("Write status: #{get_in(plan, ["write", "status"])}")
    Mix.shell().info("  #{get_in(plan, ["write", "message"])}")
  end

  defp print_preview(preview) do
    Mix.shell().info("")
    Mix.shell().info("Generated-domain preview:")
    Mix.shell().info("  status: #{Map.get(preview, "status")}")
    Mix.shell().info("  target module: #{Map.get(preview, "target_module")}")
    Mix.shell().info("  target file: #{Map.get(preview, "target_file")}")
    Mix.shell().info("  domain function: #{Map.get(preview, "domain_function")}")
    Mix.shell().info("  render strategy: #{Map.get(preview, "render_strategy")}")
    Mix.shell().info("  write enabled: #{Map.get(preview, "write_enabled")}")

    Mix.shell().info(
      "  reconstructable sections: #{format_list(Map.get(preview, "reconstructable_sections", []))}"
    )

    Mix.shell().info(
      "  partial sections: #{format_list(Map.get(preview, "partial_sections", []))}"
    )

    Mix.shell().info(
      "  preserved unmodeled sections: #{format_list(Map.get(preview, "preserved_unmodeled_sections", []))}"
    )
  end

  defp print_sections(sections) do
    Mix.shell().info("")
    Mix.shell().info("Sections to reconstruct:")

    sections
    |> Enum.group_by(&Map.get(&1, "class", "unclassified"))
    |> Enum.sort_by(fn {class, _items} -> class_order(class) end)
    |> Enum.each(fn {class, items} ->
      Mix.shell().info("  #{class}:")

      items
      |> Enum.sort_by(&Map.get(&1, "name"))
      |> Enum.each(fn section ->
        Mix.shell().info(
          "    #{Map.get(section, "name")}: #{Map.get(section, "count")} (#{Map.get(section, "status")})"
        )
      end)
    end)
  end

  defp print_runtime_placeholders(runtime_placeholders) do
    Mix.shell().info("")
    Mix.shell().info("Runtime placeholders: #{Map.get(runtime_placeholders, "count", 0)}")

    runtime_placeholders
    |> Map.get("by_type", %{})
    |> Enum.sort_by(fn {type, _count} -> type end)
    |> Enum.each(fn {type, count} ->
      Mix.shell().info("  #{type}: #{count}")
    end)

    runtime_placeholders
    |> Map.get("paths", [])
    |> Enum.take(10)
    |> Enum.each(fn placeholder ->
      Mix.shell().info("  #{Map.get(placeholder, "path")} (#{Map.get(placeholder, "type")})")
    end)
  end

  defp print_diagnostics(diagnostics) do
    Mix.shell().info("")
    Mix.shell().info("Diagnostics:")
    print_diagnostic_summary("artifact", Map.fetch!(diagnostics, "artifact"))
    print_diagnostic_summary("current", Map.fetch!(diagnostics, "current"))
  end

  defp print_diagnostic_summary(label, diagnostics) do
    Mix.shell().info(
      "  #{label}: #{Map.get(diagnostics, "errors", 0)} errors, #{Map.get(diagnostics, "warnings", 0)} warnings"
    )
  end

  defp class_order("canonical"), do: 0
  defp class_order("projection"), do: 1
  defp class_order("proposed"), do: 2
  defp class_order("unknown"), do: 3
  defp class_order(_class), do: 4

  defp format_list([]), do: "(none)"
  defp format_list(values), do: Enum.join(values, ", ")

  defp format_invalid_options(invalid) do
    invalid
    |> Enum.map(fn
      {switch, nil} -> switch
      {switch, value} -> "#{switch} #{value}"
    end)
    |> Enum.join(", ")
  end
end
