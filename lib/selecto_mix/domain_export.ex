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

  @type artifact_error ::
          export_error()
          | {:read_failed, Path.t(), term()}
          | {:decode_failed, Path.t(), term()}
          | :invalid_artifact
          | {:invalid_artifact_format, term()}
          | {:unsupported_artifact_version, term()}
          | :missing_artifact_domain
          | {:invalid_artifact_domain, term()}

  @spec export(String.t() | module(), keyword()) :: {:ok, map()} | {:error, artifact_error()}
  def export(domain_module, opts \\ []) do
    normalizer = Keyword.get(opts, :normalizer, Selecto.Domain)

    with {:ok, module} <- domain_module(domain_module),
         :ok <- ensure_domain_module(module),
         {:ok, domain} <- domain_from_module(module),
         {:ok, normalized, diagnostics} <- normalize_domain(domain, normalizer),
         artifact <- artifact(module, normalized, diagnostics),
         {:ok, _check} <- round_trip_artifact(artifact, normalizer) do
      {:ok, artifact}
    end
  end

  @spec check_file(Path.t(), keyword()) :: {:ok, map()} | {:error, artifact_error()}
  def check_file(path, opts \\ []) do
    with {:ok, contents} <- read_artifact(path),
         {:ok, artifact} <- decode_artifact(contents, path),
         {:ok, check} <- check_artifact(artifact, opts) do
      {:ok, Map.put(check, :path, path)}
    end
  end

  @spec check_artifact(map(), keyword()) :: {:ok, map()} | {:error, artifact_error()}
  def check_artifact(artifact, opts \\ []) do
    normalizer = Keyword.get(opts, :normalizer, Selecto.Domain)

    with :ok <- validate_artifact_envelope(artifact),
         {:ok, domain} <- artifact_domain(artifact),
         {:ok, normalized, diagnostics} <- normalize_domain(domain, normalizer) do
      {:ok,
       %{
         artifact: artifact,
         domain_module: Map.get(artifact, "domain_module"),
         schema_version: Map.get(artifact, "schema_version"),
         normalized: normalized,
         diagnostics: diagnostics
       }}
    end
  end

  @spec encode!(map(), keyword()) :: String.t()
  def encode!(artifact, opts \\ []) do
    pretty? = Keyword.get(opts, :pretty, true)
    Jason.encode!(artifact, pretty: pretty?)
  end

  @spec format_error(artifact_error()) :: String.t()
  def format_error(:selecto_domain_unavailable) do
    "Selecto.Domain.normalize/1 is unavailable. Add or load the selecto dependency for this project."
  end

  def format_error({:module_not_loaded, module}) do
    "Domain module #{inspect(module)} could not be loaded"
  end

  def format_error({:missing_domain_function, module}) do
    "Domain module #{inspect(module)} must export domain/0"
  end

  def format_error({:normalization_failed, diagnostics}) do
    "Domain normalization failed: #{inspect(diagnostics)}"
  end

  def format_error({:invalid_normalizer_result, result}) do
    "Selecto.Domain.normalize/1 returned an unexpected result: #{inspect(result)}"
  end

  def format_error({:read_failed, path, reason}) do
    "Could not read normalized domain JSON #{path}: #{inspect(reason)}"
  end

  def format_error({:decode_failed, path, reason}) do
    "Could not decode normalized domain JSON #{path}: #{Exception.message(reason)}"
  end

  def format_error(:invalid_artifact) do
    "Normalized domain JSON artifact must be a JSON object"
  end

  def format_error({:invalid_artifact_format, format}) do
    "Unexpected normalized domain artifact format #{inspect(format)}"
  end

  def format_error({:unsupported_artifact_version, version}) do
    "Unsupported normalized domain artifact version #{inspect(version)}"
  end

  def format_error(:missing_artifact_domain) do
    "Normalized domain JSON artifact is missing a domain object"
  end

  def format_error({:invalid_artifact_domain, domain}) do
    "Normalized domain JSON artifact domain must be an object, got: #{inspect(domain)}"
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
         {:ok, check} <- check_artifact(decoded, normalizer: normalizer) do
      {:ok, check}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_artifact(path) do
    case File.read(path) do
      {:ok, contents} -> {:ok, contents}
      {:error, reason} -> {:error, {:read_failed, path, reason}}
    end
  end

  defp decode_artifact(contents, path) do
    case Jason.decode(contents) do
      {:ok, artifact} -> {:ok, artifact}
      {:error, reason} -> {:error, {:decode_failed, path, reason}}
    end
  end

  defp validate_artifact_envelope(%{} = artifact) do
    cond do
      Map.get(artifact, "format") != @format ->
        {:error, {:invalid_artifact_format, Map.get(artifact, "format")}}

      Map.get(artifact, "format_version") != @format_version ->
        {:error, {:unsupported_artifact_version, Map.get(artifact, "format_version")}}

      true ->
        :ok
    end
  end

  defp validate_artifact_envelope(_artifact), do: {:error, :invalid_artifact}

  defp artifact_domain(artifact) do
    case Map.fetch(artifact, "domain") do
      {:ok, domain} when is_map(domain) -> {:ok, domain}
      {:ok, domain} -> {:error, {:invalid_artifact_domain, domain}}
      :error -> {:error, :missing_artifact_domain}
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
