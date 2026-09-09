defmodule Bitflyer.Repo.Migrations.AddOrdersInsertedAtIndex do
  @moduledoc """
  Strategy.Runner の submitted ID 復元（inserted_at lookback）用インデックス。
  """

  use Ecto.Migration

  def up do
    create index(:orders, [:inserted_at], name: "orders_inserted_at_index")
  end

  def down do
    drop_if_exists(index(:orders, [:inserted_at], name: "orders_inserted_at_index"))
  end
end
