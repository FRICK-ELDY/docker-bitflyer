defmodule Bitflyer.Risk.AuthorizedOrderTest do
  use Bitflyer.DataCase, async: false

  require Ash.Query

  import Bitflyer.TestSupport.MarketDataCacheHelper
  import Bitflyer.TestSupport.OrderRateHelper
  import Bitflyer.TestSupport.DailyLossHelper
  import Bitflyer.TestSupport.BalanceCacheHelper
  import Bitflyer.TestSupport.ReadinessHelper
  import Bitflyer.TestSupport.InFlightHelper

  alias Bitflyer.OrderExecutor
  alias Bitflyer.OrderExecutor.InFlight
  alias Bitflyer.Readiness
  alias Bitflyer.Risk
  alias Bitflyer.Risk.AuthorizedOrder
  alias Bitflyer.System
  alias Bitflyer.Trading.Order

  @market_key {:ticker, "FX_BTC_JPY"}

  setup do
    reset_readiness()
    reset_market_data_cache()
    reset_order_rate()
    reset_daily_loss()
    reset_balance_cache()
    reset_inflight()
    _ = AuthorizedOrder.clear()

    on_exit(fn ->
      reset_readiness()
      reset_market_data_cache()
      reset_order_rate()
      reset_daily_loss()
      reset_balance_cache()
      reset_inflight()
      _ = AuthorizedOrder.clear()
    end)

    :ok
  end

  test "no public new!/1 constructor" do
    refute function_exported?(AuthorizedOrder, :new!, 1)
    refute function_exported?(AuthorizedOrder, :mint, 1)
    refute function_exported?(AuthorizedOrder, :mint, 2)
  end

  test "forged AuthorizedOrder is rejected by submit" do
    Application.put_env(:bitflyer, :trade_mode, :dry_run)
    assert Readiness.mark_ready() == :ok
    put_fresh_ticker(@market_key)

    forged = %AuthorizedOrder{
      token: make_ref(),
      command: valid_command("forge-1"),
      authorized_at_ms: Elixir.System.monotonic_time(:millisecond)
    }

    assert {:error, :unauthorized, %{reason: :authorization_missing}} =
             OrderExecutor.submit(forged, trade_mode: :dry_run, positions: [])

    assert {:ok, nil} =
             Order
             |> Ash.Query.filter(internal_order_id == "forge-1")
             |> Ash.read_one()
  end

  test "authorized token is one-shot" do
    Application.put_env(:bitflyer, :trade_mode, :dry_run)
    assert Readiness.mark_ready() == :ok
    put_fresh_ticker(@market_key)

    assert {:ok, auth} =
             Risk.authorize(valid_command("once-1"), positions: [], trade_mode: :dry_run)

    assert {:ok, %Order{status: :pending}} =
             OrderExecutor.submit(auth, trade_mode: :dry_run, positions: [])

    assert {:error, :unauthorized, %{reason: :authorization_missing}} =
             OrderExecutor.submit(auth, trade_mode: :dry_run, positions: [])
  end

  test "expired authorization is rejected" do
    Application.put_env(:bitflyer, :trade_mode, :dry_run)
    assert Readiness.mark_ready() == :ok
    put_fresh_ticker(@market_key)

    now = Elixir.System.monotonic_time(:millisecond)

    assert {:ok, auth} =
             Risk.authorize(valid_command("ttl-1"),
               positions: [],
               trade_mode: :dry_run,
               now_ms: now
             )

    assert {:error, :unauthorized, %{reason: :authorization_expired}} =
             OrderExecutor.submit(auth,
               trade_mode: :dry_run,
               positions: [],
               now_ms: now + 60_000,
               ttl_ms: 1_000
             )

    assert {:ok, nil} =
             Order
             |> Ash.Query.filter(internal_order_id == "ttl-1")
             |> Ash.read_one()
  end

  test "System.submit_order still works end-to-end" do
    Application.put_env(:bitflyer, :trade_mode, :dry_run)
    assert Readiness.mark_ready() == :ok
    put_fresh_ticker(@market_key)

    assert {:ok, %Order{status: :pending, internal_order_id: "sys-auth-1"}} =
             System.submit_order(valid_command("sys-auth-1"),
               positions: [],
               trade_mode: :dry_run
             )
  end

  test "Cache :server option does not divert AuthorizedOrder.consume" do
    Application.put_env(:bitflyer, :trade_mode, :dry_run)
    assert Readiness.mark_ready() == :ok
    put_fresh_ticker(@market_key)

    assert {:ok, auth} =
             Risk.authorize(valid_command("server-opt-1"),
               positions: [],
               trade_mode: :dry_run
             )

    # MarketData Cache 用の :server を渡しても認可トークンは既定 GenServer を使う
    assert {:ok, %Order{status: :pending}} =
             OrderExecutor.submit(auth,
               trade_mode: :dry_run,
               positions: [],
               server: :not_an_authorized_order_server
             )
  end

  test "shutting down rejects before consuming token" do
    Application.put_env(:bitflyer, :trade_mode, :dry_run)
    assert Readiness.mark_ready() == :ok
    put_fresh_ticker(@market_key)

    assert {:ok, auth} =
             Risk.authorize(valid_command("gate-1"), positions: [], trade_mode: :dry_run)

    assert :ok = InFlight.drain(timeout_ms: 100)

    assert {:error, :shutting_down, %{reason: :inflight_closed}} =
             OrderExecutor.submit(auth, trade_mode: :dry_run, positions: [])

    assert AuthorizedOrder.size() == 1

    reset_inflight()

    assert {:ok, %Order{status: :pending}} =
             OrderExecutor.submit(auth, trade_mode: :dry_run, positions: [])
  end

  test "expired tokens are purged from ETS without consume" do
    Application.put_env(:bitflyer, :trade_mode, :dry_run)
    assert Readiness.mark_ready() == :ok
    put_fresh_ticker(@market_key)

    now = Elixir.System.monotonic_time(:millisecond)
    previous_ttl = Application.get_env(:bitflyer, AuthorizedOrder, [])

    Application.put_env(:bitflyer, AuthorizedOrder, ttl_ms: 1_000)

    on_exit(fn ->
      if previous_ttl == nil do
        Application.delete_env(:bitflyer, AuthorizedOrder)
      else
        Application.put_env(:bitflyer, AuthorizedOrder, previous_ttl)
      end
    end)

    assert {:ok, _auth} =
             Risk.authorize(valid_command("purge-1"),
               positions: [],
               trade_mode: :dry_run,
               now_ms: now - 5_000
             )

    assert AuthorizedOrder.size() == 1

    assert {:ok, _} =
             Risk.authorize(valid_command("purge-2"),
               positions: [],
               trade_mode: :dry_run,
               now_ms: now
             )

    # mint 時の purge で期限切れを落とす
    assert AuthorizedOrder.size() == 1
  end

  defp valid_command(id, overrides \\ %{}) do
    Map.merge(
      %{
        product_code: "FX_BTC_JPY",
        side: :buy,
        size: Decimal.new("0.01"),
        order_type: :market,
        market_key: @market_key,
        internal_order_id: id,
        intent_id: id
      },
      overrides
    )
  end
end
