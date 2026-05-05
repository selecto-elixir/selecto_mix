defmodule Mix.Tasks.Selecto.Gen.ApiTest do
  use ExUnit.Case

  import ExUnit.CaptureIO

  test "generated API surfaces the domain-authored Updato write contract" do
    in_tmp_dir("selecto_mix_gen_api_contract", fn ->
      Mix.Task.reenable("selecto.gen.api")

      output =
        capture_io(fn ->
          Mix.Tasks.Selecto.Gen.Api.run([
            "orders",
            "--domain",
            "Shop.SelectoDomains.OrderDomain",
            "--schema",
            "Shop.Orders.Order",
            "--repo",
            "Shop.Repo",
            "--api-path",
            "/api/v1/updato/orders",
            "--panel-path",
            "/updato/orders/control"
          ])
        end)

      api_module = File.read!("lib/selecto_mix/updato_api/orders_api.ex")
      controller = File.read!("lib/selecto_mix_web/controllers/orders_api_controller.ex")
      control_panel = File.read!("lib/selecto_mix_web/live/orders_api_control_panel_live.ex")

      assert api_module =~ "alias SelectoUpdato.DomainContract"
      assert api_module =~ "def write_contract(config \\\\ @default_config, opts \\\\ [])"
      assert api_module =~ "def write_contract_summary(config \\\\ @default_config)"
      assert api_module =~ "def validate_intent(params, config \\\\ @default_config)"
      assert api_module =~ "|> DomainContract.json_document(opts)"

      assert controller =~ "write_contract: write_contract"
      assert controller =~ "capabilities: OrderApi.write_contract_summary()"

      assert control_panel =~ ~s(id="updato-write-contract")
      assert control_panel =~ "OrderApi.write_contract()"
      assert control_panel =~ ~s(phx-click="validate_request")

      config_index = output_index(output, ~s(get "/v1/updato/orders/config"))
      show_index = output_index(output, ~s(get "/v1/updato/orders/:id"))

      assert is_integer(config_index)
      assert is_integer(show_index)
      assert config_index < show_index
    end)
  end

  defp in_tmp_dir(prefix, fun) do
    tmp_dir = Path.join(System.tmp_dir!(), "#{prefix}_#{System.unique_integer([:positive])}")
    File.rm_rf!(tmp_dir)
    File.mkdir_p!(tmp_dir)

    try do
      File.cd!(tmp_dir, fun)
    after
      File.rm_rf!(tmp_dir)
    end
  end

  defp output_index(output, value) do
    case :binary.match(output, value) do
      {index, _length} -> index
      :nomatch -> nil
    end
  end
end
