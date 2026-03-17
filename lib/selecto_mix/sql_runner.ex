defmodule SelectoMix.SqlRunner do
  @moduledoc false

  def run_sql_directory(adapter, conn, dir, opts \\ []) do
    pattern = Keyword.get(opts, :pattern, "*.sql")

    sql_files =
      Path.join(dir, pattern)
      |> Path.wildcard()
      |> Enum.sort()

    if Enum.empty?(sql_files) do
      {:ok, :no_files}
    else
      results = Enum.map(sql_files, &run_sql_file(adapter, conn, &1))
      errors = Enum.filter(results, &match?({:error, _, _}, &1))

      if Enum.empty?(errors) do
        {:ok, length(sql_files)}
      else
        {:error, errors}
      end
    end
  end

  def run_sql_file(adapter, conn, file_path) do
    case File.read(file_path) do
      {:ok, sql} -> run_sql_string(adapter, conn, sql, file_path)
      {:error, reason} -> {:error, file_path, {:file_read_error, reason}}
    end
  end

  def run_sql_string(adapter, conn, sql, label \\ "inline") do
    statements =
      sql
      |> String.split(";")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    results =
      Enum.map(statements, fn stmt ->
        case adapter.execute(conn, stmt, [], prepared: false) do
          {:ok, result} -> {:ok, result}
          {:error, error} -> {:error, label, error}
        end
      end)

    errors = Enum.filter(results, &match?({:error, _, _}, &1))

    if Enum.empty?(errors) do
      {:ok, label, length(statements)}
    else
      List.first(errors)
    end
  end
end
