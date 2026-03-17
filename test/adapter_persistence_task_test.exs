defmodule SelectoMix.AdapterPersistenceTaskTest do
  use ExUnit.Case, async: false

  test "saved_views task supports SQLite dry run" do
    {output, 0} =
      System.cmd(
        "mix",
        ["selecto.gen.saved_views", "TmpApp", "--adapter", "sqlite", "--dry-run"],
        stderr_to_stdout: true
      )

    assert output =~ "Selecto SavedViews Generation (DRY RUN)"
    assert output =~ "Adapter: sqlite"
    assert output =~ "priv/sql/create_saved_views.sql"
    assert output =~ "lib/tmp_app/saved_view_context.ex"
  end

  test "saved_view_configs task supports PostgreSQL dry run" do
    {output, 0} =
      System.cmd(
        "mix",
        ["selecto.gen.saved_view_configs", "TmpApp", "--adapter", "postgresql", "--dry-run"],
        stderr_to_stdout: true
      )

    assert output =~ "Selecto SavedViewConfigs Generation (DRY RUN)"
    assert output =~ "Adapter: postgresql"
    assert output =~ "priv/sql/create_saved_view_configs.sql"
    assert output =~ "lib/tmp_app/saved_view_config_context.ex"
  end
end
