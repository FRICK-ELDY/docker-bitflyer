defmodule Bitflyer.Repo.Migrations.AddOrdersFilledNotional do
  @moduledoc """
  Order.filled_notional — 取引所累積約定金額（remote_avg × remote_filled）の baseline。

  Fill からの backfill はしない。旧 LiveFills は累積 average_price を差分 Fill に
  掛けていたため、連続部分約定済みの Fill.price は取引所真値とずれうる。
  誤 Fill から作った notional は次の増分価格を再び壊す。

  既定 0 のままにする。`filled_size > 0` かつ notional 0 のオープン live 注文は
  runtime が fail-closed する（Ready / 認可前 sync で止まる）。
  """

  use Ecto.Migration

  def up do
    alter table(:orders) do
      add(:filled_notional, :decimal, null: false, default: "0")
    end
  end

  def down do
    alter table(:orders) do
      remove(:filled_notional)
    end
  end
end
