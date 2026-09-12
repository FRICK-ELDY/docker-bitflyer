defmodule Bitflyer.Repo.Migrations.AddFillsFee do
  @moduledoc """
  P1 #4: Fill に取引所 execution 手数料（quote 通貨）を残す。
  既存行は NULL（未記録）。新規 live は 0 以上を書く。
  """

  use Ecto.Migration

  def up do
    alter table(:fills) do
      add(:fee, :decimal, null: true)
    end
  end

  def down do
    alter table(:fills) do
      remove(:fee)
    end
  end
end
