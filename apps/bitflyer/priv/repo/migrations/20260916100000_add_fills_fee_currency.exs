defmodule Bitflyer.Repo.Migrations.AddFillsFeeCurrency do
  @moduledoc """
  P0 #1: Fill.fee の通貨を product ごとに残す。

  既存行は NULL（`fee` ありの live 記帳も含む）。読取時は `Product.fee_currency/1` で補完する。
  """

  use Ecto.Migration

  def up do
    alter table(:fills) do
      add(:fee_currency, :text, null: true)
    end
  end

  def down do
    alter table(:fills) do
      remove(:fee_currency)
    end
  end
end
