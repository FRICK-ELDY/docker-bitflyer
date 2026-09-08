defmodule Bitflyer.Trading.Position do
  @moduledoc """
  現在建玉の正本。

  銘柄ごとに 1 行。サイズと平均単価は Decimal。
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
      update: [:side, :size, :average_price, :trade_mode]
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
    end

    attribute :average_price, :decimal do
      allow_nil? false
      public? true
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
    identity :unique_product_code, [:product_code]
  end
end
