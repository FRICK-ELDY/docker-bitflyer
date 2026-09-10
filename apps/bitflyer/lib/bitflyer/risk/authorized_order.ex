defmodule Bitflyer.Risk.AuthorizedOrder do
  @moduledoc """
  `Risk.authorize/2` 成功時のみ発行される発注意図トークン。

  公開コンストラクタは無い。`OrderExecutor.submit/2` は `consume/1` で
  ワンショット検証し、偽造・再利用・TTL 超過を拒否する。
  未消費の期限切れトークンは周期スイープで ETS から除去する（発注ホットパスでは掃除しない）。
  ETS は `:protected`（書き込みはオーナーのみ）。クライアント直 `take` のための `:public` 化はしない
  （任意プロセスの insert で Risk を迂回できるため）。

  GenServer 差し替えは `:authorized_order_server`（MarketData Cache の `:server` と衝突させない）。
  """

  use GenServer

  @enforce_keys [:token, :command, :authorized_at_ms]
  defstruct [:token, :command, :authorized_at_ms]

  @opaque t :: %__MODULE__{
            token: reference(),
            command: map(),
            authorized_at_ms: integer()
          }

  @name __MODULE__
  @default_ttl_ms 30_000
  @purge_interval_ms 5_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, @name)
    GenServer.start_link(__MODULE__, %{table: name}, name: name)
  end

  @doc """
  認可トークンを一度だけ消費する。偽造・再利用・TTL 超過はエラー。

  ## Options
  - `:authorized_order_server` — GenServer 名（既定 `__MODULE__`）。Cache 用 `:server` とは別
  - `:now_ms` / `:ttl_ms` — テスト用
  """
  @spec consume(t(), keyword()) :: {:ok, map()} | {:error, :unauthorized, map()}
  def consume(%__MODULE__{} = authorized, opts \\ []) do
    server = Keyword.get(opts, :authorized_order_server, @name)
    call_opts = Keyword.take(opts, [:now_ms, :ttl_ms])
    GenServer.call(server, {:consume, authorized, call_opts})
  end

  @doc """
  認可済み command map（参照用。実行経路は `consume/1`）。
  """
  @spec command(t()) :: map()
  def command(%__MODULE__{command: command}), do: command

  @doc false
  @spec clear(keyword()) :: :ok
  def clear(opts \\ []) do
    server = Keyword.get(opts, :authorized_order_server, @name)
    GenServer.call(server, :clear)
  end

  @doc false
  @spec size(keyword()) :: non_neg_integer()
  def size(opts \\ []) do
    server = Keyword.get(opts, :authorized_order_server, @name)
    GenServer.call(server, :size)
  end

  @impl true
  def init(%{table: table_name}) do
    # :protected 必須。:public にすると任意プロセスが :ets.insert でき、
    # Risk.authorize を通さず有効トークンを偽造できる（P3 #17 の境界破壊）。
    # consume の GenServer 直列化は意図的。本システムの発注頻度ではボトルネックにならない。
    table =
      :ets.new(table_name, [
        :set,
        :protected,
        :named_table,
        read_concurrency: true
      ])

    state = schedule_purge(%{table: table})
    {:ok, state}
  end

  @impl true
  def handle_call({:mint, command, opts}, _from, state) when is_map(command) do
    now_ms = Keyword.get_lazy(opts, :now_ms, &monotonic_ms/0)

    token = make_ref()
    true = :ets.insert(state.table, {token, command, now_ms})

    authorized = %__MODULE__{
      token: token,
      command: command,
      authorized_at_ms: now_ms
    }

    {:reply, authorized, state}
  end

  def handle_call({:consume, authorized, opts}, _from, state) do
    %__MODULE__{token: token, command: command, authorized_at_ms: authorized_at_ms} = authorized
    now_ms = Keyword.get_lazy(opts, :now_ms, &monotonic_ms/0)
    ttl = Keyword.get_lazy(opts, :ttl_ms, &ttl_ms/0)

    reply =
      case :ets.take(state.table, token) do
        [{^token, stored_command, stored_at}] ->
          cond do
            stored_command != command or stored_at != authorized_at_ms ->
              {:error, :unauthorized, %{reason: :authorization_mismatch}}

            now_ms - stored_at > ttl ->
              {:error, :unauthorized, %{reason: :authorization_expired, ttl_ms: ttl}}

            true ->
              {:ok, stored_command}
          end

        [] ->
          {:error, :unauthorized, %{reason: :authorization_missing}}
      end

    {:reply, reply, state}
  end

  def handle_call(:clear, _from, state) do
    true = :ets.delete_all_objects(state.table)
    {:reply, :ok, state}
  end

  def handle_call(:size, _from, state) do
    {:reply, :ets.info(state.table, :size), state}
  end

  @impl true
  def handle_info(:purge_expired, state) do
    _ = purge_expired(state.table, monotonic_ms(), ttl_ms())
    {:noreply, schedule_purge(state)}
  end

  defp schedule_purge(state) do
    Process.send_after(self(), :purge_expired, @purge_interval_ms)
    state
  end

  defp purge_expired(table, now_ms, ttl) do
    expired_before = now_ms - ttl

    match_spec = [
      {{:"$1", :"$2", :"$3"}, [{:<, :"$3", expired_before}], [true]}
    ]

    :ets.select_delete(table, match_spec)
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)

  defp ttl_ms do
    Application.get_env(:bitflyer, __MODULE__, [])
    |> Keyword.get(:ttl_ms, @default_ttl_ms)
  end
end
