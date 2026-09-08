defmodule Bitflyer.System.Heartbeat do
  @moduledoc """
  稼働記録。DB 接続と Ash 経路の生存確認用。
  """
  use Ash.Resource,
    otp_app: :bitflyer,
    domain: Bitflyer.System,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "heartbeats"
    repo Bitflyer.Repo
  end

  actions do
    defaults [:read, :destroy, create: [:note], update: [:note]]
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :note, :string do
      allow_nil? false
      public? true
      default "ok"
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end
end
