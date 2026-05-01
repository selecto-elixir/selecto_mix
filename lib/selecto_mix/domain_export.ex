defmodule SelectoMix.DomainExport do
  @moduledoc """
  Builds JSON-ready artifacts for normalized Selecto domains.

  The exporter intentionally calls into `Selecto.Domain.normalize/1` at runtime
  so `selecto_mix` can stay a tooling package while host projects provide the
  Selecto version they are using.
  """

  @format "selecto.normalized_domain"
  @format_version 1

  @type export_error ::
          :selecto_domain_unavailable
          | {:module_not_loaded, module()}
          | {:missing_domain_function, module()}
          | {:normalization_failed, term()}
          | {:invalid_normalizer_result, term()}

  @spec export(String.t() | module(), keyword()) :: {:ok, map()} | {:error, export_error()}
  def export(domain_module, opts \\ []) do
    normalizer = Keyword.get(opts, :normalizer, Selecto.Domain)

    with {:ok, module} <- domain_module(domain_module),
         :ok <- ensure_domain_module(module),
         {:ok, domain} <- domain_from_module(module),
         {:ok, normalized, diagnostics} <- normalize_domain(domain, normalizer),
         artifact <- artifact(module, normalized, diagnostics),
         :ok <- round_trip_artifact(artifact, normalizer) do
      {:ok, artifact}
    end
  end

  @spec encode!(map(), keyword()) :: String.t()
  def encode!(artifact, opts \\ []) do
    pretty? = Keyword.get(opts, :pretty, true)
    Jason.encode!(artifact, pretty: pretty?)
  end

  defp domain_module(module) when is_atom(module), do: {:ok, module}

  defp domain_module(module) when is_binary(module) do
    {:ok, Module.concat([module])}
  end

  defp ensure_domain_module(module) do
    if Code.ensure_loaded?(module) do
      :ok
    else
      {:error, {:module_not_loaded, module}}
    end
  end

  defp domain_from_module(module) do
    if function_exported?(module, :domain, 0) do
      {:ok, apply(module, :domain, [])}
    else
      {:error, {:missing_domain_function, module}}
    end
  end

  defp normalize_domain(domain, normalizer) do
    cond do
      not Code.ensure_loaded?(normalizer) or not function_exported?(normalizer, :normalize, 1) ->
        {:error, :selecto_domain_unavailable}

      true ->
        case apply(normalizer, :normalize, [domain]) do
          {:ok, normalized, diagnostics} when is_map(normalized) ->
            {:ok, normalized, diagnostics}

          {:error, diagnostics} ->
            {:error, {:normalization_failed, diagnostics}}

          other ->
            {:error, {:invalid_normalizer_result, other}}
        end
    end
  end

  defp artifact(module, normalized, diagnostics) do
    domain = Map.get(normalized, :domain) || Map.get(normalized, "domain") || normalized
    schema_version = Map.get(normalized, :schema_version) || Map.get(normalized, "schema_version")

    %{
      "format" => @format,
      "format_version" => @format_version,
      "domain_module" => inspect(module),
      "schema_version" => json_value(schema_version),
      "domain" => json_value(domain),
      "diagnostics" => json_value(diagnostics)
    }
  end

  defp round_trip_artifact(artifact, normalizer) do
    with {:ok, encoded} <- Jason.encode(artifact),
         {:ok, decoded} <- Jason.decode(encoded),
         {:ok, _normalized, _diagnostics} <-
           normalize_domain(Map.fetch!(decoded, "domain"), normalizer) do
      :ok
    else
      {:error, reason} -> {:error, {:normalization_failed, reason}}
    end
  end

  defp json_value(%_struct{} = value) do
    value
    |> Map.from_struct()
    |> json_value()
  end

  defp json_value(value) when is_map(value) do
    value
    |> Enum.map(fn {key, value} -> {json_key(key), json_value(value)} end)
    |> Enum.into(%{})
  end

  defp json_value(value) when is_list(value), do: Enum.map(value, &json_value/1)

  defp json_value(value) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> json_value()
  end

  defp json_value(value) when is_function(value) do
    function_info =
      value
      |> Function.info()
      |> Map.new()
      |> Map.take([:module, :name, :arity, :type])

    %{
      "$selecto_export" => "function",
      "inspect" => inspect(value),
      "function" => json_value(function_info)
    }
  end

  defp json_value(value) when is_pid(value) or is_port(value) or is_reference(value) do
    %{
      "$selecto_export" => "term",
      "type" => value |> term_type() |> Atom.to_string(),
      "inspect" => inspect(value)
    }
  end

  defp json_value(value) when is_atom(value), do: atom_value(value)
  defp json_value(value), do: value

  defp atom_value(nil), do: nil
  defp atom_value(true), do: true
  defp atom_value(false), do: false
  defp atom_value(value), do: Atom.to_string(value)

  defp json_key(key) when is_atom(key), do: Atom.to_string(key)
  defp json_key(key) when is_binary(key), do: key
  defp json_key(key), do: inspect(key)

  defp term_type(value) when is_pid(value), do: :pid
  defp term_type(value) when is_port(value), do: :port
  defp term_type(value) when is_reference(value), do: :reference
end
