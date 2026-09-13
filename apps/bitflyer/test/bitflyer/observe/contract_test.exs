defmodule Bitflyer.Observe.ContractTest do
  use ExUnit.Case, async: true

  alias Bitflyer.Observe.Contract

  defmodule StubHTTP do
    @moduledoc false

    def get(url, opts) do
      notify({:http_get, url, Keyword.get(opts, :params, [])})

      cond do
        String.contains?(url, "/v1/ticker") ->
          {:ok, corpus_json("public/ticker_btc_jpy.json")}

        String.contains?(url, "/v1/getexecutions") ->
          {:ok, corpus_json("public/executions_btc_jpy.json")}

        String.contains?(url, "/v1/getmarkets") ->
          {:ok, corpus_json("public/markets.json")}

        true ->
          {:error, {:unexpected_url, url}}
      end
    end

    defp corpus_json(rel) do
      Contract.corpus_dir()
      |> Path.join(rel)
      |> File.read!()
      |> Jason.decode!()
    end

    defp notify(msg) do
      case Process.whereis(:contract_probe) do
        nil -> :ok
        pid -> send(pid, msg)
      end
    end
  end

  defmodule FailHTTP do
    @moduledoc false
    def get(_url, _opts), do: {:error, :nxdomain}
  end

  defmodule RecordingExchange do
    @moduledoc false

    def get_permissions do
      notify({:exchange, :get_permissions})
      {:ok, ["/v1/me/getbalance", "/v1/me/getchildorders"]}
    end

    def fetch_reconcile_snapshot do
      notify({:exchange, :fetch_reconcile_snapshot})

      {:ok,
       %{
         balances: [%{currency: "JPY"}],
         positions: [],
         open_orders: []
       }}
    end

    def place_order(_order) do
      notify({:exchange, :place_order})
      {:error, :contract_must_not_place}
    end

    def cancel_order(_order) do
      notify({:exchange, :cancel_order})
      {:error, :contract_must_not_cancel}
    end

    defp notify(msg) do
      case Process.whereis(:contract_probe) do
        nil -> :ok
        pid -> send(pid, msg)
      end
    end
  end

  defmodule WithdrawExchange do
    @moduledoc false

    def get_permissions do
      {:ok,
       [
         "/v1/me/getbalance",
         "/v1/me/withdraw",
         "/v1/me/sendcoin"
       ]}
    end

    def fetch_reconcile_snapshot do
      {:ok, %{balances: [%{}, %{}], positions: [%{}], open_orders: []}}
    end
  end

  setup do
    Process.register(self(), :contract_probe)

    on_exit(fn ->
      if Process.whereis(:contract_probe) == self() do
        Process.unregister(:contract_probe)
      end
    end)

    :ok
  end

  test "committed anonymized corpus passes offline semantics" do
    assert {:ok, checks} = Contract.check_corpus()
    names = Enum.map(checks, & &1.name)
    assert names == [:corpus_ticker, :corpus_executions, :corpus_markets]
    assert Enum.all?(checks, &(&1.status == :ok))
    assert {:ok, ^checks} = Bitflyer.System.contract_corpus()
  end

  test "run/1 uses public GET only and never posts" do
    assert {:ok, report} = Contract.run(http: StubHTTP)

    assert report.product_code == "BTC_JPY"
    assert report.private == :skipped

    assert Enum.map(report.public, &{&1.name, &1.status}) == [
             {:ticker, :ok},
             {:executions, :ok},
             {:markets, :ok}
           ]

    assert_received {:http_get, ticker_url, ticker_params}
    assert ticker_url =~ "/v1/ticker"
    assert Keyword.get(ticker_params, :product_code) == "BTC_JPY"

    assert_received {:http_get, exec_url, exec_params}
    assert exec_url =~ "/v1/getexecutions"
    assert Keyword.get(exec_params, :count) == 5

    assert_received {:http_get, markets_url, []}
    assert markets_url =~ "/v1/getmarkets"

    refute_received {:http_post, _, _}
    refute_received {:exchange, _}

    assert {:ok, facade} = Bitflyer.System.contract_probe(http: StubHTTP)
    assert facade.private == :skipped
  end

  test "private? uses signed GET only and never places or cancels" do
    assert {:ok, report} =
             Contract.run(http: StubHTTP, exchange: RecordingExchange, private?: true)

    assert Enum.map(report.private, &{&1.name, &1.status}) == [
             {:permissions, :ok},
             {:reconcile_snapshot, :ok}
           ]

    perm = Enum.find(report.private, &(&1.name == :permissions))
    assert perm.detail.result == %{count: 2, withdraw: false, sendcoin: false}

    snap = Enum.find(report.private, &(&1.name == :reconcile_snapshot))
    assert snap.detail.result == %{balances: 1, positions: 0, open_orders: 0}

    assert_received {:exchange, :get_permissions}
    assert_received {:exchange, :fetch_reconcile_snapshot}
    refute_received {:exchange, :place_order}
    refute_received {:exchange, :cancel_order}

    assert "/v1/me/sendchildorder" in Contract.forbidden_private_paths()
    assert "/v1/me/cancelchildorder" in Contract.forbidden_private_paths()
  end

  test "permissions summary flags withdraw and sendcoin without printing paths" do
    assert {:ok, report} =
             Contract.run(http: StubHTTP, exchange: WithdrawExchange, private?: true)

    perm = Enum.find(report.private, &(&1.name == :permissions))
    assert perm.detail.result == %{count: 3, withdraw: true, sendcoin: true}

    snap = Enum.find(report.private, &(&1.name == :reconcile_snapshot))
    assert snap.detail.result == %{balances: 2, positions: 1, open_orders: 0}

    perm_line = Contract.format_ok_detail(perm)
    snap_line = Contract.format_ok_detail(snap)

    assert perm_line == " count=3 withdraw=true sendcoin=true"
    assert snap_line == " balances=2 positions=1 open_orders=0"
    refute perm_line =~ "/v1/me/"
    refute snap_line =~ "/v1/me/"
    refute inspect(perm.detail.result) =~ "/v1/me/"
  end

  test "write_corpus? anonymizes execution ids into a temp dir" do
    dir =
      Path.join(
        System.tmp_dir!(),
        "bitflyer-contract-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(dir) end)

    assert {:ok, _} =
             Contract.run(http: StubHTTP, write_corpus?: true, corpus_dir: dir)

    assert {:ok, _} = Contract.check_corpus(corpus_dir: dir)

    executions =
      dir
      |> Path.join("public/executions_btc_jpy.json")
      |> File.read!()
      |> Jason.decode!()

    assert executions != []

    Enum.each(executions, fn row ->
      assert row["buy_child_order_acceptance_id"] == "JRF-REDACTED-BUY"
      assert row["sell_child_order_acceptance_id"] == "JRF-REDACTED-SELL"
    end)

    manifest =
      dir
      |> Path.join("manifest.json")
      |> File.read!()
      |> Jason.decode!()

    assert manifest["product_code"] == "BTC_JPY"
    assert "buy_child_order_acceptance_id" in manifest["anonymized"]
  end

  test "public HTTP failure fails the report" do
    assert {:error, report} = Contract.run(http: FailHTTP)
    assert Enum.all?(report.public, &(&1.status == :error))
    assert Enum.all?(report.public, &(&1.reason == :nxdomain))
  end

  test "invalid corpus ticker fails closed" do
    dir =
      Path.join(
        System.tmp_dir!(),
        "bitflyer-contract-bad-#{System.unique_integer([:positive])}"
      )

    public_dir = Path.join(dir, "public")
    File.mkdir_p!(public_dir)
    on_exit(fn -> File.rm_rf(dir) end)

    File.cp!(
      Path.join(Contract.corpus_dir(), "public/executions_btc_jpy.json"),
      Path.join(public_dir, "executions_btc_jpy.json")
    )

    File.cp!(
      Path.join(Contract.corpus_dir(), "public/markets.json"),
      Path.join(public_dir, "markets.json")
    )

    File.write!(
      Path.join(public_dir, "ticker_btc_jpy.json"),
      Jason.encode!(%{
        "product_code" => "BTC_JPY",
        "ltp" => 1,
        "best_bid" => 3,
        "best_ask" => 2,
        "timestamp" => "2026-09-12T07:01:33.33"
      })
    )

    assert {:error, checks} = Contract.check_corpus(corpus_dir: dir)
    ticker = Enum.find(checks, &(&1.name == :corpus_ticker))
    assert ticker.status == :error
    assert ticker.reason == :crossed_book
  end
end
