defmodule Bitflyer.Trading.Order do
  @moduledoc """
  内部注文の永続記録。

  `internal_order_id` は冪等キー（DB 一意）。取引所注文 ID との対応、
  未約定・部分約定の状態を復元可能にする。
  """
  use Ash.Resource,
    otp_app: :bitflyer,
    domain: Bitflyer.Trading,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "orders"
    repo Bitflyer.Repo

    custom_indexes do
      index [:exchange_order_id], name: "orders_exchange_order_id_index"
    end
  end

  actions do
    defaults [
      :read,
      :destroy,
      create: [
        :internal_order_id,
        :exchange_order_id,
        :product_code,
        :side,
        :status,
        :order_type,
        :price,
        :size,
        :filled_size,
        :trade_mode
      ],
      update: [
        :exchange_order_id,
        :status,
        :price,
        :size,
        :filled_size
      ]
    ]
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :internal_order_id, :string do
      allow_nil? false
      public? true
    end

    attribute :exchange_order_id, :string do
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

    attribute :status, :atom do
      allow_nil? false
      public? true
      default :pending
      constraints one_of: [:pending, :partially_filled, :filled, :cancelled, :rejected, :expired]
    end

    attribute :order_type, :atom do
      allow_nil? false
      public? true
      default :limit
      constraints one_of: [:limit, :market]
    end

    attribute :price, :decimal do
      allow_nil? true
      public? true
    end

    attribute :size, :decimal do
      allow_nil? false
      public? true
    end

    attribute :filled_size, :decimal do
      allow_nil? false
      public? true
      default Decimal.new("0")
    end

    attribute :trade_mode, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:dry_run, :paper, :live]
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :unique_internal_order_id, [:internal_order_id]
  end
end
