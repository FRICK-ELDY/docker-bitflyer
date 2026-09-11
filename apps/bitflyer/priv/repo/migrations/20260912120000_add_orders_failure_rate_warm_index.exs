defmodule Bitflyer.Repo.Migrations.AddOrdersFailureRateWarmIndex do
  @moduledoc """
  `FailureRate` warm（rejected × trade_mode × updated_at）用の複合索引。
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    create index(:orders, [:trade_mode, :status, :updated_at],
             name: "orders_trade_mode_status_updated_at_index",
             concurrently: true
           )
  end

  def down do
    drop_if_exists(
      index(:orders, [:trade_mode, :status, :updated_at],
        name: "orders_trade_mode_status_updated_at_index",
        concurrently: true
      )
    )
  end
end
