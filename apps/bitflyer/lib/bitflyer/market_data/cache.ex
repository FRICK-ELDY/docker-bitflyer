defmodule Bitflyer.MarketData.Cache do
  @moduledoc """
  市場データの鮮度付き ETS キャッシュ。

  エントリは `{value, received_at}`（`received_at` は monotonic ms）。
  読み取りは ETS 直読（`read_concurrency`）。書き込みは GenServer のみ。

  `fresh?/2` は miss / 期限切れ / テーブル消失をすべて false（fail-closed）。
  risk-manager（`Bitflyer.Risk.authorize/2`）はここを見て stale を拒否する。
  """

  use GenServer

  @type key :: term()
  @type value :: term()
  @type received_at :: integer()
  @type entry :: {value(), received_at()}

  @name __MODULE__

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, @name)
    GenServer.start_link(__MODULE__, %{table: name}, name: name)
  end

  @doc """
  値を書き込む。`received_at` 未指定時はいまの monotonic ms。
  """
  @spec put(key(), value(), keyword()) :: :ok
  def put(key, value, opts \\ []) do
    server = Keyword.get(opts, :server, @name)
    GenServer.call(server, {:put, key, value, opts})
  end

  @doc """
  エントリを読む。無い／テーブル消失は `:miss`。
  """
  @spec get(key(), GenServer.server()) :: {:ok, value(), received_at()} | :miss
  def get(key, server \\ @name)

  def get(key, server) when is_atom(server) do
    case ets_lookup(server, key) do
      {:ok, value, received_at} -> {:ok, value, received_at}
      :miss -> :miss
    end
  end

  def get(key, server) do
    GenServer.call(server, {:get, key})
  end

  @doc """
  エントリが `max_age_ms` 以内か。miss / stale / 消失は false。

  境界は `age <= max_age_ms` を fresh とする。
  テストでは `now:` で monotonic 時刻を注入できる。
  """
  @spec fresh?(key(), non_neg_integer(), keyword()) :: boolean()
  def fresh?(key, max_age_ms, opts \\ [])
      when is_integer(max_age_ms) and max_age_ms >= 0 do
    server = Keyword.get(opts, :server, @name)
    now = Keyword.get_lazy(opts, :now, &monotonic_ms/0)

    case get(key, server) do
      {:ok, _value, received_at} -> entry_fresh?(received_at, max_age_ms, now)
      :miss -> false
    end
  end

  @doc """
  純関数の鮮度判定（ETS 非依存）。risk / テストから再利用する。
  """
  @spec entry_fresh?(received_at(), non_neg_integer(), received_at()) :: boolean()
  def entry_fresh?(received_at, max_age_ms, now)
      when is_integer(received_at) and is_integer(max_age_ms) and max_age_ms >= 0 and
             is_integer(now) do
    now - received_at <= max_age_ms
  end

  @doc """
  経過ミリ秒。miss は `:miss`。
  """
  @spec age_ms(key(), keyword()) :: non_neg_integer() | :miss
  def age_ms(key, opts \\ []) do
    server = Keyword.get(opts, :server, @name)
    now = Keyword.get_lazy(opts, :now, &monotonic_ms/0)

    case get(key, server) do
      {:ok, _value, received_at} -> max(now - received_at, 0)
      :miss -> :miss
    end
  end

  @doc """
  1 キー削除。
  """
  @spec delete(key(), keyword()) :: :ok
  def delete(key, opts \\ []) do
    server = Keyword.get(opts, :server, @name)
    GenServer.call(server, {:delete, key})
  end

  @doc """
  全消し（テスト用）。
  """
  @spec clear(keyword()) :: :ok
  def clear(opts \\ []) do
    server = Keyword.get(opts, :server, @name)
    GenServer.call(server, :clear)
  end

  @doc """
  設定の既定 max age（ms）。未設定時は 5_000。
  """
  @spec default_max_age_ms() :: pos_integer()
  def default_max_age_ms do
    Application.get_env(:bitflyer, __MODULE__, [])
    |> Keyword.get(:default_max_age_ms, 5_000)
  end

  @doc """
  いまの monotonic 時刻（ms）。
  """
  @spec monotonic_ms() :: received_at()
  def monotonic_ms, do: System.monotonic_time(:millisecond)

  # —— Server ——

  @impl true
  def init(%{table: table}) do
    _ = ensure_table(table)
    {:ok, table}
  end

  @impl true
  def handle_call({:put, key, value, opts}, _from, table) do
    received_at = Keyword.get_lazy(opts, :received_at, &monotonic_ms/0)
    true = :ets.insert(table, {key, value, received_at})
    {:reply, :ok, table}
  end

  def handle_call({:get, key}, _from, table) do
    {:reply, ets_lookup(table, key), table}
  end

  def handle_call({:delete, key}, _from, table) do
    true = :ets.delete(table, key)
    {:reply, :ok, table}
  end

  def handle_call(:clear, _from, table) do
    true = :ets.delete_all_objects(table)
    {:reply, :ok, table}
  end

  defp ensure_table(table) when is_atom(table) do
    # 同名テーブルが他プロセス所有なら :ets.new が失敗し、init で fail-fast する
    :ets.new(table, [:named_table, :protected, :set, read_concurrency: true])
  end

  defp ets_lookup(table, key) when is_atom(table) do
    case :ets.lookup(table, key) do
      [{^key, value, received_at}] -> {:ok, value, received_at}
      [] -> :miss
    end
  rescue
    ArgumentError -> :miss
  end
end
