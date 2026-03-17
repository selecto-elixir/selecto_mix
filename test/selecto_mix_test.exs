defmodule SelectoMixTest do
  use ExUnit.Case
  doctest SelectoMix

  alias SelectoMix.{
    AdapterResolver,
    ConfigMerger,
    ConnectionOpts,
    DomainGenerator,
    LiveViewGenerator,
    SchemaIntrospector
  }

  describe "SelectoMix basic functionality" do
    test "version/0 returns version string" do
      version = SelectoMix.version()
      assert is_binary(version)
      assert String.match?(version, ~r/\d+\.\d+\.\d+/)
    end

    test "config/0 returns configuration" do
      config = SelectoMix.config()
      assert is_list(config)
    end

    test "default_output_dir/0 returns valid directory path" do
      dir = SelectoMix.default_output_dir()
      assert is_binary(dir)
      assert String.contains?(dir, "selecto_domains")
    end
  end

  describe "schema validation" do
    test "validate_schema_module/1 with invalid module" do
      result = SelectoMix.validate_schema_module("NotAModule")
      assert {:error, _reason} = result
    end
  end

  describe "SchemaIntrospector" do
    # These tests would require actual Ecto schemas to be meaningful
    # For demonstration purposes, showing the test structure

    test "introspect_schema/2 handles missing schema gracefully" do
      # This would fail with a real schema module, but shows error handling
      result = SchemaIntrospector.introspect_schema(NonExistentSchema, [])
      assert Map.has_key?(result, :error)
    end
  end

  describe "ConfigMerger" do
    test "merge_with_existing/2 with nil existing content" do
      new_config = %{schema_module: TestSchema, fields: [:id, :name]}
      result = ConfigMerger.merge_with_existing(new_config, nil)

      assert result == new_config
    end

    test "merge_with_existing/2 with existing content" do
      new_config = %{schema_module: TestSchema, fields: [:id, :name, :email]}

      existing_content = """
      defmodule TestDomain do
        def domain do
          %{
            source: %{
              fields: [:id, :name] # CUSTOM: added custom field
            }
          }
        end
      end
      """

      result = ConfigMerger.merge_with_existing(new_config, existing_content)

      # Should preserve customizations
      assert Map.has_key?(result, :preserve_existing)
    end

    test "detect_customizations/1 finds custom markers" do
      content_with_custom = "field: :test # CUSTOM"
      content_without_custom = "field: :test"

      # Test through parse_existing_config since detect_customizations is private
      result1 = ConfigMerger.parse_existing_config(content_with_custom)
      result2 = ConfigMerger.parse_existing_config(content_without_custom)

      assert result1[:has_customizations] == true
      assert result2[:has_customizations] == false
    end
  end

  describe "DomainGenerator" do
    test "generate_domain_file/2 creates valid Elixir code" do
      schema_module = TestSchema

      config = %{
        schema_module: schema_module,
        table_name: "test_table",
        primary_key: :id,
        fields: [:id, :name],
        field_types: %{id: :integer, name: :string},
        associations: %{},
        suggested_defaults: %{
          default_selected: [:name],
          default_filters: %{},
          default_order: []
        },
        metadata: %{
          module_name: "TestSchema",
          context_name: "Test"
        }
      }

      result = DomainGenerator.generate_domain_file(schema_module, config)

      assert is_binary(result)
      assert String.contains?(result, "defmodule")
      assert String.contains?(result, "def domain do")
      assert String.contains?(result, "source:")
      assert String.contains?(result, "test_table")
    end

    test "generate_domain_map/1 creates proper domain configuration" do
      config = %{
        schema_module: TestSchema,
        table_name: "tests",
        primary_key: :id,
        fields: [:id, :name],
        field_types: %{id: :integer, name: :string},
        associations: %{},
        suggested_defaults: %{
          default_selected: [:name],
          default_filters: %{},
          default_order: []
        },
        metadata: %{module_name: "Test"}
      }

      result = DomainGenerator.generate_domain_map(config)

      assert is_binary(result)
      assert String.contains?(result, "source:")
      assert String.contains?(result, "source_table: \"tests\"")
      assert String.contains?(result, "primary_key: :id")
    end

    test "generate_domain_map/1 emits many-to-many join table metadata" do
      config = %{
        schema_module: TestSchema,
        table_name: "products",
        primary_key: :id,
        fields: [:id],
        field_types: %{id: :integer},
        associations: %{
          tags: %{
            association_type: :many_to_many,
            related_schema: TestTag,
            queryable: :tags,
            owner_key: :id,
            related_key: :id,
            join_type: :left,
            join_through: "product_tags",
            join_keys: [product_id: :id, tag_id: :id]
          }
        },
        suggested_defaults: %{
          default_selected: [],
          default_filters: %{},
          default_order: []
        },
        metadata: %{module_name: "Product"}
      }

      result = DomainGenerator.generate_domain_map(config)

      assert String.contains?(result, "join_table: \"product_tags\"")
      assert String.contains?(result, "join_keys: [product_id: :id, tag_id: :id]")
      assert String.contains?(result, "main_foreign_key: \"product_id\"")
      assert String.contains?(result, "tag_foreign_key: \"tag_id\"")
    end

    test "generate_domain_file/3 creates DB-backed helper functions" do
      source = {:db, SelectoDBPostgreSQL.Adapter, :fake_conn, "products", schema: "public"}

      config = %{
        table_name: "products",
        primary_key: :id,
        fields: [:id, :name],
        field_types: %{id: :integer, name: :string},
        associations: %{},
        suggested_defaults: %{
          default_selected: [:name],
          default_filters: %{},
          default_order: []
        },
        metadata: %{
          module_name: "Product",
          context_name: "PostgreSQL"
        },
        source_type: :db,
        adapter: SelectoDBPostgreSQL.Adapter
      }

      result = DomainGenerator.generate_domain_file(source, config, app_name: "Shop")

      assert String.contains?(result, "defmodule Shop.SelectoDomains.ProductDomain")
      assert String.contains?(result, "def source_table, do: \"products\"")
      assert String.contains?(result, "def adapter_module, do: SelectoDBPostgreSQL.Adapter")
      refute String.contains?(result, "def from_ecto")

      assert String.contains?(
               result,
               "mix selecto.gen.domain --adapter postgresql --table products"
             )
    end
  end

  describe "adapter-backed helpers" do
    test "adapter resolver accepts short adapter names" do
      assert {:ok, SelectoDBPostgreSQL.Adapter} = AdapterResolver.resolve("postgresql")
    end

    test "connection opts parse convenience flags" do
      opts =
        ConnectionOpts.from_parsed_args(%{
          database: "shop_dev",
          host: "localhost",
          port: 5432,
          username: "postgres",
          password: "secret"
        })

      assert opts[:database] == "shop_dev"
      assert opts[:hostname] == "localhost"
      assert opts[:port] == 5432
      assert opts[:username] == "postgres"
      assert opts[:password] == "secret"
    end
  end

  describe "LiveViewGenerator" do
    test "renders DB-backed live view template with database connection" do
      source = {:db, SelectoDBPostgreSQL.Adapter, :fake_conn, "products", schema: "public"}

      result =
        LiveViewGenerator.render_live_view_template(
          "Shop",
          source,
          "Shop.SelectoDomains.ProductDomain",
          [connection_name: "Shop.Database"],
          "deps"
        )

      assert String.contains?(result, "defmodule ShopWeb.ProductLive")
      assert String.contains?(result, "Selecto.configure(domain, Shop.Database)")
      refute String.contains?(result, "Shop.Repo")
    end

    test "builds DB-backed live view file paths from table names" do
      source = {:db, SelectoDBPostgreSQL.Adapter, :fake_conn, "order_items", schema: "public"}

      assert LiveViewGenerator.live_view_file_path("shop", source) ==
               "lib/shop_web/live/order_item_live.ex"

      assert LiveViewGenerator.live_view_html_file_path("shop", source) ==
               "lib/shop_web/live/order_item_live.html.heex"
    end
  end

  describe "integration" do
    test "full workflow without actual file creation" do
      # Test the complete workflow without actually creating files
      config = %{
        schema_module: TestSchema,
        table_name: "test_table",
        primary_key: :id,
        fields: [:id, :name],
        field_types: %{id: :integer, name: :string},
        associations: %{},
        suggested_defaults: %{
          default_selected: [:name],
          default_filters: %{},
          default_order: []
        },
        metadata: %{
          module_name: "TestSchema",
          context_name: "Test"
        }
      }

      # Step 1: Merge with existing (none in this case)
      merged_config = ConfigMerger.merge_with_existing(config, nil)
      assert merged_config == config

      # Step 2: Generate domain file
      domain_content = DomainGenerator.generate_domain_file(TestSchema, merged_config)
      assert is_binary(domain_content)
      assert String.contains?(domain_content, "defmodule")

      # This demonstrates the complete workflow works end-to-end
      assert true
    end
  end
end
