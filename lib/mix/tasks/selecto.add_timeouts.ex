defmodule Mix.Tasks.Selecto.AddTimeouts do
  @shortdoc "Add query timeout defense system to your Phoenix application"
  @moduledoc """
  Adds a multi-layer query timeout defense system to protect your database from overload.

  This task implements a comprehensive defense strategy including:
  - PostgreSQL statement_timeout configuration
  - Ecto connection pool timeout configuration
  - QueryTimeoutMonitor with circuit breaker pattern
  - Application supervision tree integration

  ## Examples

      # Add with default settings (30s timeout, 90% circuit breaker threshold)
      mix selecto.add_timeouts

      # Add with custom timeout
      mix selecto.add_timeouts --timeout 60000

      # Add with custom circuit breaker threshold
      mix selecto.add_timeouts --circuit-threshold 0.8

      # Preview changes without applying
      mix selecto.add_timeouts --dry-run

  ## Options

    * `--timeout` - Default query timeout in milliseconds (default: 30000)
    * `--test-timeout` - Test query timeout in milliseconds (default: 15000)
    * `--circuit-threshold` - Pool utilization threshold to open circuit (default: 0.9)
    * `--check-interval` - Health check interval in milliseconds (default: 5000)
    * `--dry-run` - Show what would be changed without applying
    * `--force` - Overwrite existing QueryTimeoutMonitor module
    * `--skip-config` - Skip config file modifications
    * `--skip-monitor` - Skip QueryTimeoutMonitor generation
    * `--skip-supervision` - Skip adding monitor to supervision tree

  ## What Gets Modified

  ### Configuration Files:
  - `config/dev.exs` - Adds database timeouts and PostgreSQL parameters
  - `config/test.exs` - Adds shorter timeouts for tests
  - `config/runtime.exs` - Adds production timeout configuration with env vars

  ### Generated Files:
  - `lib/APP_NAME/query_timeout_monitor.ex` - Circuit breaker GenServer

  ### Modified Files:
  - `lib/APP_NAME/application.ex` - Adds QueryTimeoutMonitor to supervision tree

  ## Defense Layers

  The system implements multiple defense layers:

  1. **PostgreSQL Level**: `statement_timeout` kills queries at database
  2. **Ecto Level**: Connection pool timeouts (query, connect, queue)
  3. **Application Level**: Task-based timeout wrapper (if using Selecto.Executor)
  4. **Circuit Breaker**: Blocks queries when pool saturated
  5. **Complexity Analysis**: Pre-execution query validation (if enabled)

  ## Usage After Installation

  Check circuit breaker status:

      YourApp.QueryTimeoutMonitor.allow_query?()
      YourApp.QueryTimeoutMonitor.circuit_state()
      YourApp.QueryTimeoutMonitor.stats()

  Record query metrics:

      YourApp.QueryTimeoutMonitor.record_timeout()
      YourApp.QueryTimeoutMonitor.record_slow_query(duration_ms)
      YourApp.QueryTimeoutMonitor.record_query(duration_ms)

  ## Environment Variables (Production)

  Set these in your production environment:

      QUERY_TIMEOUT=30000          # Query execution timeout
      STATEMENT_TIMEOUT=30000      # PostgreSQL statement timeout
      POOL_SIZE=10                 # Connection pool size
  """

  use Igniter.Mix.Task

  @impl Igniter.Mix.Task
  def info(_argv, _composing_task) do
    %Igniter.Mix.Task.Info{
      group: :selecto,
      example: "mix selecto.add_timeouts --timeout 60000",
      positional: [],
      schema: [
        timeout: :integer,
        test_timeout: :integer,
        circuit_threshold: :float,
        check_interval: :integer,
        dry_run: :boolean,
        force: :boolean,
        skip_config: :boolean,
        skip_monitor: :boolean,
        skip_supervision: :boolean
      ],
      aliases: [
        t: :timeout,
        d: :dry_run,
        f: :force
      ],
      defaults: [
        timeout: 30_000,
        test_timeout: 15_000,
        circuit_threshold: 0.9,
        check_interval: 5_000,
        dry_run: false,
        force: false,
        skip_config: false,
        skip_monitor: false,
        skip_supervision: false
      ]
    }
  end

  @impl Igniter.Mix.Task
  def igniter(igniter, argv) do
    options = info(argv, nil).defaults
    {opts, _} = OptionParser.parse!(argv, switches: info(argv, nil).schema, aliases: info(argv, nil).aliases)
    options = Keyword.merge(options, opts)

    app_name = Igniter.Project.Application.app_name(igniter)
    app_module = Igniter.Project.Module.module_name(igniter, app_name)

    igniter
    |> maybe_update_dev_config(options, app_name)
    |> maybe_update_test_config(options, app_name)
    |> maybe_update_runtime_config(options, app_name)
    |> maybe_generate_monitor(options, app_module)
    |> maybe_add_to_supervision_tree(options, app_module)
    |> display_instructions(options, app_module)
  end

  defp maybe_update_dev_config(igniter, options, app_name) do
    if options[:skip_config] do
      igniter
    else
      timeout = options[:timeout]
      config_path = "config/dev.exs"

      Mix.shell().info("📝 Updating #{config_path} with database timeouts...")

      repo_config = """
        timeout: #{timeout},              # Query execution timeout: #{div(timeout, 1000)}s
        connect_timeout: 5_000,       # Connection establishment: 5 seconds
        queue_timeout: 10_000,        # Pool checkout timeout: 10 seconds
        # PostgreSQL-level timeout enforcement
        parameters: [
          statement_timeout: "#{timeout}",                      # Kill queries > #{div(timeout, 1000)}s
          idle_in_transaction_session_timeout: "300000"   # Kill idle txns > 5min
        ]
      """

      Igniter.Project.Config.configure(
        igniter,
        config_path,
        app_name,
        [:"Elixir.#{Macro.camelize(to_string(app_name))}.Repo"],
        {:code, repo_config},
        updater: fn zipper ->
          # Try to find and update existing timeout config
          zipper
        end
      )
    end
  end

  defp maybe_update_test_config(igniter, options, app_name) do
    if options[:skip_config] do
      igniter
    else
      timeout = options[:test_timeout]
      config_path = "config/test.exs"

      Mix.shell().info("📝 Updating #{config_path} with test timeouts...")

      repo_config = """
        timeout: #{timeout},              # Query timeout: #{div(timeout, 1000)} seconds
        connect_timeout: 5_000,
        queue_timeout: 5_000,
        # PostgreSQL-level timeout enforcement
        parameters: [
          statement_timeout: "#{timeout}",                      # Kill queries > #{div(timeout, 1000)}s in tests
          idle_in_transaction_session_timeout: "60000"    # Kill idle txns > 1min in tests
        ]
      """

      Igniter.Project.Config.configure(
        igniter,
        config_path,
        app_name,
        [:"Elixir.#{Macro.camelize(to_string(app_name))}.Repo"],
        {:code, repo_config}
      )
    end
  end

  defp maybe_update_runtime_config(igniter, options, app_name) do
    if options[:skip_config] do
      igniter
    else
      config_path = "config/runtime.exs"

      Mix.shell().info("📝 Updating #{config_path} with production timeout configuration...")

      repo_config = """
        # Production timeout configuration
        timeout: String.to_integer(System.get_env("QUERY_TIMEOUT") || "#{options[:timeout]}"),
        connect_timeout: 5_000,
        queue_timeout: 10_000,
        # PostgreSQL-level safety parameters
        parameters: [
          statement_timeout: System.get_env("STATEMENT_TIMEOUT") || "#{options[:timeout]}",
          idle_in_transaction_session_timeout: "300000",
          lock_timeout: "10000",                    # Don't wait > 10s for locks
          maintenance_work_mem: "256MB"             # Limit work memory
        ]
      """

      Igniter.Project.Config.configure(
        igniter,
        config_path,
        app_name,
        [:"Elixir.#{Macro.camelize(to_string(app_name))}.Repo"],
        {:code, repo_config}
      )
    end
  end

  defp maybe_generate_monitor(igniter, options, app_module) do
    if options[:skip_monitor] do
      igniter
    else
      Mix.shell().info("🔧 Generating QueryTimeoutMonitor module...")

      monitor_module = Module.concat(app_module, QueryTimeoutMonitor)
      monitor_code = generate_monitor_code(options, app_module)

      Igniter.Project.Module.create_module(
        igniter,
        monitor_module,
        monitor_code,
        force?: options[:force]
      )
    end
  end

  defp maybe_add_to_supervision_tree(igniter, options, app_module) do
    if options[:skip_supervision] do
      igniter
    else
      Mix.shell().info("🌳 Adding QueryTimeoutMonitor to supervision tree...")

      app_module_path = Module.concat(app_module, Application)
      monitor_module = Module.concat(app_module, QueryTimeoutMonitor)

      Igniter.Project.Application.add_new_child(
        igniter,
        monitor_module,
        after: [Module.concat(app_module, Repo)]
      )
    end
  end

  defp display_instructions(igniter, options, app_module) do
    if not options[:dry_run] do
      Mix.shell().info("""

      ✅ Query timeout defense system has been added to your application!

      ## What was added:

      - PostgreSQL statement_timeout: #{options[:timeout]}ms
      - Ecto connection pool timeouts
      - #{inspect(Module.concat(app_module, QueryTimeoutMonitor))} with circuit breaker
      - Integration with application supervision tree

      ## Circuit Breaker Configuration:

      - Threshold: #{Float.round(options[:circuit_threshold] * 100, 1)}% pool utilization
      - Check interval: #{div(options[:check_interval], 1000)}s
      - States: :closed (normal) → :open (blocked) → :half_open (testing)

      ## Usage:

      Check if queries are allowed:
          #{inspect(Module.concat(app_module, QueryTimeoutMonitor))}.allow_query?()

      Get current statistics:
          #{inspect(Module.concat(app_module, QueryTimeoutMonitor))}.stats()

      Get circuit breaker state:
          #{inspect(Module.concat(app_module, QueryTimeoutMonitor))}.circuit_state()

      ## Environment Variables (Production):

      Set these in your production environment:

          export QUERY_TIMEOUT=#{options[:timeout]}
          export STATEMENT_TIMEOUT=#{options[:timeout]}
          export POOL_SIZE=10

      ## Next Steps:

      1. Review generated files and adjust thresholds if needed
      2. Test with: `mix test`
      3. Start server: `mix phx.server`
      4. Monitor logs for timeout warnings
      5. Adjust timeouts based on your application's needs

      For more information, see the SelectoMix documentation.
      """)
    end

    igniter
  end

  defp generate_monitor_code(options, app_module) do
    repo_module = Module.concat(app_module, Repo)

    """
    defmodule #{inspect(Module.concat(app_module, QueryTimeoutMonitor))} do
      @moduledoc \"\"\"
      Monitors database query performance and implements circuit breaker pattern.

      Protects the database from overload by:
      - Monitoring connection pool utilization
      - Tracking query timeout rates
      - Opening circuit breaker when system is under heavy load
      - Collecting performance statistics

      Circuit breaker states:
      - `:closed` - Normal operation, queries allowed
      - `:open` - System overloaded, queries blocked
      - `:half_open` - Testing if system has recovered

      Generated by: mix selecto.add_timeouts
      \"\"\"

      use GenServer
      require Logger

      @check_interval #{options[:check_interval]}  # Check every #{div(options[:check_interval], 1000)} seconds
      @circuit_open_threshold #{options[:circuit_threshold]}  # Open circuit if #{Float.round(options[:circuit_threshold] * 100, 1)}% connections busy
      @circuit_half_open_timeout 30_000  # Try again after 30s
      @slow_query_threshold 10_000  # Queries > 10s are "slow"
      @very_slow_query_threshold 30_000  # Queries > 30s are "very slow"

      defstruct [
        circuit_state: :closed,  # :closed, :open, :half_open
        circuit_opened_at: nil,
        consecutive_failures: 0,
        last_check: nil,
        stats: %{
          total_queries: 0,
          timeout_queries: 0,
          slow_queries: 0,
          very_slow_queries: 0,
          pool_saturation_events: 0,
          last_pool_utilization: 0.0
        }
      ]

      ## Public API

      def start_link(opts \\\\ []) do
        GenServer.start_link(__MODULE__, opts, name: __MODULE__)
      end

      @doc \"\"\"
      Check if queries should be allowed based on circuit breaker state.
      \"\"\"
      @spec allow_query? :: boolean()
      def allow_query? do
        case GenServer.call(__MODULE__, :get_circuit_state, 1000) do
          :closed -> true
          :half_open -> true
          :open -> false
        catch
          :exit, _ -> true
        end
      end

      @doc \"\"\"
      Get current circuit breaker state.
      \"\"\"
      @spec circuit_state :: :closed | :open | :half_open
      def circuit_state do
        GenServer.call(__MODULE__, :get_circuit_state, 1000)
      catch
        :exit, _ -> :closed
      end

      @doc \"\"\"
      Get performance statistics.
      \"\"\"
      @spec stats :: map()
      def stats do
        GenServer.call(__MODULE__, :get_stats, 1000)
      catch
        :exit, _ -> %{error: "Monitor not available"}
      end

      @doc \"\"\"
      Record a timeout event.
      \"\"\"
      @spec record_timeout :: :ok
      def record_timeout do
        GenServer.cast(__MODULE__, :timeout_error)
      end

      @doc \"\"\"
      Record a slow query.
      \"\"\"
      @spec record_slow_query(non_neg_integer()) :: :ok
      def record_slow_query(duration_ms) do
        GenServer.cast(__MODULE__, {:slow_query, duration_ms})
      end

      @doc \"\"\"
      Record a completed query.
      \"\"\"
      @spec record_query(non_neg_integer()) :: :ok
      def record_query(duration_ms) do
        GenServer.cast(__MODULE__, {:query_completed, duration_ms})
      end

      ## GenServer Callbacks

      @impl GenServer
      def init(_opts) do
        schedule_check()

        state = %__MODULE__{
          circuit_state: :closed,
          circuit_opened_at: nil,
          consecutive_failures: 0,
          last_check: System.monotonic_time(:millisecond),
          stats: %{
            total_queries: 0,
            timeout_queries: 0,
            slow_queries: 0,
            very_slow_queries: 0,
            pool_saturation_events: 0,
            last_pool_utilization: 0.0
          }
        }

        Logger.info("[QueryTimeoutMonitor] Started monitoring")
        {:ok, state}
      end

      @impl GenServer
      def handle_call(:get_circuit_state, _from, state) do
        {:reply, state.circuit_state, state}
      end

      @impl GenServer
      def handle_call(:get_stats, _from, state) do
        stats = Map.merge(state.stats, %{
          circuit_state: state.circuit_state,
          uptime_seconds: div(System.monotonic_time(:millisecond) - state.last_check, 1000),
          timeout_rate: calculate_rate(state.stats.timeout_queries, state.stats.total_queries),
          slow_query_rate: calculate_rate(state.stats.slow_queries, state.stats.total_queries)
        })

        {:reply, stats, state}
      end

      @impl GenServer
      def handle_cast(:timeout_error, state) do
        new_stats = Map.update!(state.stats, :timeout_queries, &(&1 + 1))
        {:noreply, %{state | stats: new_stats}}
      end

      @impl GenServer
      def handle_cast({:slow_query, duration_ms}, state) do
        new_stats = state.stats
        |> Map.update!(:slow_queries, &(&1 + 1))

        new_stats = if duration_ms >= @very_slow_query_threshold do
          Map.update!(new_stats, :very_slow_queries, &(&1 + 1))
        else
          new_stats
        end

        {:noreply, %{state | stats: new_stats}}
      end

      @impl GenServer
      def handle_cast({:query_completed, duration_ms}, state) do
        new_stats = Map.update!(state.stats, :total_queries, &(&1 + 1))

        new_stats = if duration_ms >= @slow_query_threshold do
          new_stats
          |> Map.update!(:slow_queries, &(&1 + 1))
          |> then(fn stats ->
            if duration_ms >= @very_slow_query_threshold do
              Map.update!(stats, :very_slow_queries, &(&1 + 1))
            else
              stats
            end
          end)
        else
          new_stats
        end

        {:noreply, %{state | stats: new_stats}}
      end

      @impl GenServer
      def handle_info(:check_pool_health, state) do
        new_state = check_pool_health(state)
        schedule_check()
        {:noreply, new_state}
      end

      ## Private Functions

      defp check_pool_health(state) do
        try do
          case DBConnection.status(#{inspect(repo_module)}) do
            %{available: available, size: size} when size > 0 ->
              utilization = (size - available) / size

              new_stats = Map.put(state.stats, :last_pool_utilization, utilization)
              state = %{state | stats: new_stats}

              handle_circuit_state(state, utilization)

            _ ->
              state
          end
        rescue
          error ->
            Logger.warning("[QueryTimeoutMonitor] Error checking pool health: \#{inspect(error)}")
            state
        catch
          :exit, reason ->
            Logger.warning("[QueryTimeoutMonitor] Pool health check exited: \#{inspect(reason)}")
            state
        end
      end

      defp handle_circuit_state(state, utilization) do
        case state.circuit_state do
          :closed ->
            if utilization >= @circuit_open_threshold do
              open_circuit(state, utilization)
            else
              state
            end

          :open ->
            time_since_opened = System.monotonic_time(:millisecond) - state.circuit_opened_at

            if time_since_opened >= @circuit_half_open_timeout do
              Logger.info("[QueryTimeoutMonitor] Circuit breaker HALF-OPEN - testing recovery")
              %{state | circuit_state: :half_open}
            else
              state
            end

          :half_open ->
            if utilization < 0.5 do
              close_circuit(state)
            elsif utilization >= @circuit_open_threshold do
              open_circuit(state, utilization)
            else
              state
            end
        end
      end

      defp open_circuit(state, utilization) do
        Logger.error("[QueryTimeoutMonitor] Circuit breaker OPEN - pool saturation \#{Float.round(utilization * 100, 1)}%")

        %{state |
          circuit_state: :open,
          circuit_opened_at: System.monotonic_time(:millisecond),
          consecutive_failures: state.consecutive_failures + 1,
          stats: Map.update!(state.stats, :pool_saturation_events, &(&1 + 1))
        }
      end

      defp close_circuit(state) do
        Logger.info("[QueryTimeoutMonitor] Circuit breaker CLOSED - pool recovered")

        %{state |
          circuit_state: :closed,
          circuit_opened_at: nil,
          consecutive_failures: 0
        }
      end

      defp schedule_check do
        Process.send_after(self(), :check_pool_health, @check_interval)
      end

      defp calculate_rate(0, _), do: 0.0
      defp calculate_rate(_, 0), do: 0.0
      defp calculate_rate(part, total), do: Float.round(part / total * 100, 2)
    end
    """
  end
end