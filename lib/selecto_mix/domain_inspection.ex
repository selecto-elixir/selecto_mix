defmodule SelectoMix.DomainInspection do
  @moduledoc """
  Builds Studio/tooling inspection JSON from normalized Selecto domain artifacts.

  This module keeps the same artifact-first workflow as export/check/inspect/diff
  and delegates the actual structured inspection to `Selecto.Domain.describe/1`
  at runtime.
  """

  alias SelectoMix.DomainExport

  @format "selecto.domain_inspection"
  @format_version 1

  @type inspection_error ::
          DomainExport.artifact_error()
          | :selecto_domain_describer_unavailable
          | {:inspection_failed, term()}
          | {:invalid_describer_result, term()}

  @spec describe_file(Path.t(), keyword()) :: {:ok, map()} | {:error, inspection_error()}
  def describe_file(path, opts \\ []) do
    with {:ok, check} <- DomainExport.check_file(path, opts),
         {:ok, inspection, diagnostics} <- describe_normalized(check, opts) do
      {:ok, inspection_artifact(check, inspection, diagnostics)}
    end
  end

  @spec encode!(map(), keyword()) :: String.t()
  def encode!(inspection_artifact, opts \\ []) do
    DomainExport.encode!(inspection_artifact, opts)
  end

  @spec format_error(inspection_error()) :: String.t()
  def format_error(:selecto_domain_describer_unavailable) do
    "Selecto.Domain.describe/1 is unavailable. Add or load a selecto version with domain inspection support."
  end

  def format_error({:inspection_failed, diagnostics}) do
    "Domain inspection failed: #{inspect(diagnostics)}"
  end

  def format_error({:invalid_describer_result, result}) do
    "Selecto.Domain.describe/1 returned an unexpected result: #{inspect(result)}"
  end

  def format_error(reason), do: DomainExport.format_error(reason)

  defp describe_normalized(check, opts) do
    describer = Keyword.get(opts, :describer, Selecto.Domain)
    normalized = Map.fetch!(check, :normalized)

    cond do
      not Code.ensure_loaded?(describer) or not function_exported?(describer, :describe, 1) ->
        {:error, :selecto_domain_describer_unavailable}

      true ->
        case apply(describer, :describe, [normalized]) do
          {:ok, inspection, diagnostics} when is_map(inspection) ->
            {:ok, inspection, diagnostics}

          {:error, diagnostics} ->
            {:error, {:inspection_failed, diagnostics}}

          other ->
            {:error, {:invalid_describer_result, other}}
        end
    end
  end

  defp inspection_artifact(check, inspection, diagnostics) do
    artifact = Map.fetch!(check, :artifact)
    summary = DomainExport.summary(check)

    %{
      "format" => @format,
      "format_version" => @format_version,
      "source" => %{
        "path" => Map.get(check, :path),
        "artifact_format" => Map.get(artifact, "format"),
        "artifact_format_version" => Map.get(artifact, "format_version"),
        "domain_module" => Map.get(artifact, "domain_module"),
        "schema_version" => Map.get(artifact, "schema_version"),
        "name" => Map.get(summary, :name)
      },
      "inspection" => DomainExport.json_safe(inspection),
      "diagnostics" => DomainExport.json_safe(diagnostics)
    }
  end
end
