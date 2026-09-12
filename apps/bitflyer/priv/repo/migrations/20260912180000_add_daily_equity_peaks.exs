defmodule Bitflyer.Repo.Migrations.AddDailyEquityPeaks do
  @moduledoc """
  P1 #3: 当日 equity ピーク（HWM）を (trade_mode, trading_day) で永続化する。
  """

  use Ecto.Migration

  def up do
    create table(:daily_equity_peaks, primary_key: false) do
      add(:id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true)
      add(:trade_mode, :text, null: false)
      add(:trading_day, :date, null: false)
      add(:peak, :decimal, null: false)

      add(:inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )

      add(:updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )
    end

    create unique_index(:daily_equity_peaks, [:trade_mode, :trading_day],
             name: "daily_equity_peaks_unique_mode_day_index"
           )
  end

  def down do
    drop_if_exists(
      unique_index(:daily_equity_peaks, [:trade_mode, :trading_day],
        name: "daily_equity_peaks_unique_mode_day_index"
      )
    )

    drop(table(:daily_equity_peaks))
  end
end
