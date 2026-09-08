defmodule Bitflyer.Readiness do
  @moduledoc """
  起動・稼働の Ready 状態の正本。

  状態は次のいずれか。

  - `:not_ready` — 起動途中、または Ready 解除後。発注不可
  - `:ready` — 復元・突合などが完了し、発注経路が開いてよい
  - `{:halted, reason}` — 不整合・サーキット等で停止。Ready には直接戻さない

  書き込みは GenServer のみ。読み取りは ETS（`read_concurrency`）から行い、
  発注経路のゲート判定がプロセス間通信に依存しないようにする。
  テーブル消失時は `:not_ready`（fail-closed）。

  UI・executor・health はすべて `get/0`（または `ready?/0`）を読む。
  Boot reconcile（improvement-plan #12）が `mark_ready/0` / `halt/1` を呼ぶ想定。
  現状は起動時 `:not_ready` のまま。
  """

  use GenServer

  @type reason :: atom()
  @type state :: :not_ready | :ready | {:halted, reason()}

  @name __MODULE__

  # —— Client API ——

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, @name)
    GenServer.start_link(__MODULE__, %{table: name}, name: name)
  end

  @doc """
  現在の Ready 状態。名前付きサーバーは ETS から直接読む。
  """
  @spec get(GenServer.server()) :: state()
  def get(server \\ @name)

  def get(server) when is_atom(server) do
    ets_get(server)
  end

  def get(server) do
    GenServer.call(server, :get)
  end

  @doc """
  `:ready` かどうか。
  """
  @spec ready?(GenServer.server()) :: boolean()
  def ready?(server \\ @name) do
    get(server) == :ready
  end

  @doc """
  発注経路が開いてよいか（`:ready` のみ）。
  """
  @spec allow_orders?(GenServer.server()) :: boolean()
  def allow_orders?(server \\ @name), do: ready?(server)

  @doc """
  発注ゲート。`:ok` / `{:error, :not_ready}` / `{:halted, reason}`。
  """
  @spec gate(GenServer.server()) :: :ok | {:error, :not_ready} | {:halted, reason()}
  def gate(server \\ @name) do
    case get(server) do
      :ready -> :ok
      :not_ready -> {:error, :not_ready}
      {:halted, reason} -> {:halted, reason}
    end
  end

  @doc """
  `:not_ready` から `:ready` へ。halted 中は拒否する。
  """
  @spec mark_ready(GenServer.server()) :: :ok | {:error, state()}
  def mark_ready(server \\ @name) do
    GenServer.call(server, :mark_ready)
  end

  @doc """
  Ready を外して `:not_ready` に戻す。halted は維持する。
  """
  @spec mark_not_ready(GenServer.server()) :: :ok
  def mark_not_ready(server \\ @name) do
    GenServer.call(server, :mark_not_ready)
  end

  @doc """
  どの状態からでも `{:halted, reason}` にする。
  """
  @spec halt(reason(), GenServer.server()) :: :ok
  def halt(reason, server \\ @name) when is_atom(reason) do
    GenServer.call(server, {:halt, reason})
  end

  @doc """
  halted を解除して `:not_ready` に戻す。再 Ready は `mark_ready/0` が必要。
  """
  @spec clear_halt(GenServer.server()) :: :ok | {:error, :not_halted}
  def clear_halt(server \\ @name) do
    GenServer.call(server, :clear_halt)
  end

  @doc """
  表示・ログ用の短い文字列。
  """
  @spec format(state()) :: String.t()
  def format(:not_ready), do: "not_ready"
  def format(:ready), do: "ready"
  def format({:halted, reason}), do: "halted:#{reason}"

  # —— Server ——

  @impl true
  def init(%{table: table}) do
    _ = ensure_table(table)
    ets_put(table, :not_ready)
    {:ok, table}
  end

  @impl true
  def handle_call(:get, _from, table) do
    {:reply, ets_get(table), table}
  end

  def handle_call(:mark_ready, _from, table) do
    case ets_get(table) do
      :not_ready ->
        ets_put(table, :ready)
        {:reply, :ok, table}

      :ready ->
        {:reply, :ok, table}

      {:halted, _} = halted ->
        {:reply, {:error, halted}, table}
    end
  end

  def handle_call(:mark_not_ready, _from, table) do
    case ets_get(table) do
      {:halted, _} ->
        {:reply, :ok, table}

      _ ->
        ets_put(table, :not_ready)
        {:reply, :ok, table}
    end
  end

  def handle_call({:halt, reason}, _from, table) when is_atom(reason) do
    ets_put(table, {:halted, reason})
    {:reply, :ok, table}
  end

  def handle_call(:clear_halt, _from, table) do
    case ets_get(table) do
      {:halted, _} ->
        ets_put(table, :not_ready)
        {:reply, :ok, table}

      _ ->
        {:reply, {:error, :not_halted}, table}
    end
  end

  defp ensure_table(table) when is_atom(table) do
    case :ets.whereis(table) do
      :undefined ->
        :ets.new(table, [:named_table, :protected, :set, read_concurrency: true])

      _tid ->
        table
    end
  end

  defp ets_put(table, state) do
    true = :ets.insert(table, {:state, state})
    :ok
  end

  defp ets_get(table) when is_atom(table) do
    :ets.lookup_element(table, :state, 2)
  rescue
    ArgumentError -> :not_ready
  end
end
