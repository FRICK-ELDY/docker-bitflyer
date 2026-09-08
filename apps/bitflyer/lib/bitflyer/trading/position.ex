defmodule Bitflyer.Trading.Position do
  @moduledoc """
  現在建玉の正本。

  銘柄 × 取引モードごとに 1 行（paper と live を同居できる）。
  サイズと平均単価は Decimal。ドテン等で `side` は更新可、
  `trade_mode` は作成時に固定する。
  """
  use Ash.Resource,
    otp_app: :bitflyer,
    domain: Bitflyer.Trading,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "positions"
    repo Bitflyer.Repo
  end

  actions do
    defaults [
      :read,
      :destroy,
      create: [:product_code, :side, :size, :average_price, :trade_mode],
      update: [:side, :size, :average_price]
    ]
  end

  attributes do
    uuid_v7_primary_key :id

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

    attribute :average_price, :decimal do
      allow_nil? false
      public? true
      constraints greater_than: 0
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
    identity :unique_product_code_and_trade_mode, [:product_code, :trade_mode]
  end
end
