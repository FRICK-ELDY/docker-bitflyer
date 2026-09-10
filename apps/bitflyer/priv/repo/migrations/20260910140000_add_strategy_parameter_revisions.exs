defmodule Bitflyer.Repo.Migrations.AddStrategyParameterRevisions do
  @moduledoc """
  戦略パラメータ適用履歴と Order への由来カラム（FK・一意制約付き）。
  """

  use Ecto.Migration

  def up do
    create table(:strategy_parameter_revisions, primary_key: false) do
      add(:id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true)
      add(:trade_mode, :text, null: false)
      add(:strategy_module, :text, null: false)
      add(:params, :map, null: false)
      add(:params_hash, :text, null: false)
      add(:throttle_ms, :bigint, null: false)
      add(:source, :text, null: false)
      add(:operator, :text, null: false)
      add(:applied_at, :utc_datetime_usec, null: false)

      add(:inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )

      add(:updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )
    end

    create index(:strategy_parameter_revisions, [:trade_mode, :applied_at],
             name: "strategy_parameter_revisions_trade_mode_applied_at_index"
           )

    create unique_index(:strategy_parameter_revisions, [:trade_mode, :params_hash],
             name: "spr_trade_mode_params_hash_index"
           )

    alter table(:orders) do
      add(
        :strategy_parameter_revision_id,
        references(:strategy_parameter_revisions,
          type: :uuid,
          on_delete: :restrict,
          name: "orders_strategy_parameter_revision_id_fkey"
        )
      )

      add(:strategy_module, :text)
      add(:command_hash, :text)
    end

    create index(:orders, [:strategy_parameter_revision_id],
             name: "orders_strategy_parameter_revision_id_index"
           )
  end

  def down do
    drop_if_exists(
      index(:orders, [:strategy_parameter_revision_id],
        name: "orders_strategy_parameter_revision_id_index"
      )
    )

    drop_if_exists(
      constraint(:orders, "orders_strategy_parameter_revision_id_fkey")
    )

    alter table(:orders) do
      remove(:command_hash)
      remove(:strategy_module)
      remove(:strategy_parameter_revision_id)
    end

    drop_if_exists(
      index(:strategy_parameter_revisions, [:trade_mode, :params_hash],
        name: "spr_trade_mode_params_hash_index"
      )
    )

    drop_if_exists(
      index(:strategy_parameter_revisions, [:trade_mode, :applied_at],
        name: "strategy_parameter_revisions_trade_mode_applied_at_index"
      )
    )

    drop(table(:strategy_parameter_revisions))
  end
end
