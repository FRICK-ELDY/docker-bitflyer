defmodule Bitflyer.Trading.Fill do
  @moduledoc """
  約定明細の正本。

  建玉反映と同一トランザクションで 1 行ずつ残す。
  `realized_pnl` は決済分のみ（建増しは 0）。日次損失はここから集計する。
  """
  use Ash.Resource,
    otp_app: :bitflyer,
    domain: Bitflyer.Trading,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "fills"
    repo Bitflyer.Repo

    custom_indexes do
      index [:trade_mode, :filled_at], name: "fills_trade_mode_filled_at_index"
      index [:internal_order_id], name: "fills_internal_order_id_index"
    end
  end

  actions do
    defaults [
      :read,
      :destroy,
      create: [
        :internal_order_id,
        :exchange_execution_id,
        :product_code,
        :side,
        :size,
        :price,
        :realized_pnl,
        :trade_mode,
        :filled_at
      ]
    ]
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :internal_order_id, :string do
      allow_nil? false
      public? true
    end

    attribute :exchange_execution_id, :string do
      allow_nil? true
      public? true
    end

    attribute :product_code, :string do
      allow_nil? false
      public? true
    end

    attribute :side, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:buy, :sell]
    end

    attribute :size, :decimal do
      allow_nil? false
      public? true
      constraints greater_than: 0
    end

    attribute :price, :decimal do
      allow_nil? false
      public? true
      constraints greater_than: 0
    end

    attribute :realized_pnl, :decimal do
      allow_nil? false
      public? true
      default Decimal.new("0")
    end

    attribute :trade_mode, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:dry_run, :paper, :live]
    end

    attribute :filled_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end
end
