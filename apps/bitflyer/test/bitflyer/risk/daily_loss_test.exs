defmodule Bitflyer.Risk.DailyLossTest do
  use Bitflyer.DataCase, async: false

  import Bitflyer.TestSupport.DailyLossHelper

  alias Bitflyer.Risk.DailyLoss
  alias Bitflyer.Trading.Fill

  setup do
    reset_daily_loss()
    on_exit(fn -> reset_daily_loss() end)
    :ok
  end

  test "safe reload cannot sync while invalidate barrier is held" do
    assert {:ok, gen} = DailyLoss.invalidate(:live)

    assert {:ok, :deferred} = DailyLoss.reload(trade_mode: :live)
    assert {:error, :unsynced} = DailyLoss.get(:live)

    assert :ok =
             DailyLoss.reload(
               trade_mode: :live,
               generation: gen,
               release_barrier: true
             )

    assert {:ok, %Decimal{}} = DailyLoss.get(:live)
  end

  test "force reload also cannot sync over an open invalidate barrier" do
    assert {:ok, gen} = DailyLoss.invalidate(:paper)

    # resume / 旧 API の force でも barrier を踏み潰さない
    assert {:ok, :deferred} = DailyLoss.reload(trade_mode: :paper, force: true)
    assert {:error, :unsynced} = DailyLoss.get(:paper)

    assert :ok =
             DailyLoss.reload(
               trade_mode: :paper,
               generation: gen,
               release_barrier: true
             )

    assert {:ok, %Decimal{}} = DailyLoss.get(:paper)
  end

  test "stale generation snapshot cannot overwrite after fill completes" do
    assert {:ok, _} =
             Fill
             |> Ash.Changeset.for_create(:create, %{
               internal_order_id: "dl-race-1",
               product_code: "FX_BTC_JPY",
               side: :sell,
               size: Decimal.new("0.1"),
               price: Decimal.new("3999000"),
               realized_pnl: Decimal.new("-100100"),
               trade_mode: :live,
               filled_at: DateTime.utc_now()
             })
             |> Ash.create()

    stale_gen = 0

    assert {:ok, fill_gen} = DailyLoss.invalidate(:live)
    assert fill_gen == 1

    assert :ok =
             DailyLoss.reload(
               trade_mode: :live,
               generation: fill_gen,
               release_barrier: true
             )

    assert {:ok, loss} = DailyLoss.get(:live)
    assert Decimal.eq?(loss, Decimal.new("100100"))

    assert {:ok, :deferred} =
             DailyLoss.reload(trade_mode: :live, generation: stale_gen)

    assert {:ok, loss_after} = DailyLoss.get(:live)
    assert Decimal.eq?(loss_after, Decimal.new("100100"))
  end

  test "stuck barrier after crash-like invalidate is cleared by reset not force" do
    assert {:ok, _gen} = DailyLoss.invalidate(:paper)
    assert {:error, :unsynced} = DailyLoss.get(:paper)
    assert {:ok, :deferred} = DailyLoss.reload(trade_mode: :paper, force: true)
    assert {:error, :unsynced} = DailyLoss.get(:paper)

    # 本番では DailyLoss 再起動（init）。テストは reset で同等に barrier を落とす。
    assert :ok = DailyLoss.reset()
    assert {:ok, loss} = DailyLoss.get(:paper)
    assert Decimal.eq?(loss, Decimal.new(0))
  end
end
