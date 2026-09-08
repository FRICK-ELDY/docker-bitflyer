defmodule Bitflyer.Readiness do
  @moduledoc """
  起動・稼働の Ready 状態の正本。

  状態は次のいずれか。

  - `:not_ready` — 起動途中、または Ready 解除後。発注不可
  - `:ready` — 復元・突合などが完了し、発注経路が開いてよい
  - `{:halted, reason}` — 不整合・サーキット等で停止。Ready には直接戻さない

  UI・executor・health はすべて `get/0`（または `ready?/0`）を読む。
  Boot reconcile（improvement-plan #12）が `mark_ready/0` / `halt/1` を呼ぶ想定。
  現状は起動時 `:not_ready` のまま（fail-closed）。
  """

  use GenServer

  @type reason :: atom()
  @type state :: :not_ready | :ready | {:halted, reason()}

  @name __MODULE__

  # —— Client API ——

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, @name)
    GenServer.start_link(__MODULE__, :not_ready, name: name)
  end

  @doc """
  現在の Ready 状態。
  """
  @spec get(GenServer.server()) :: state()
  def get(server \\ @name) do
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
  def init(:not_ready), do: {:ok, :not_ready}
  def init(:ready), do: {:ok, :ready}
  def init({:halted, reason} = state) when is_atom(reason), do: {:ok, state}

  @impl true
  def handle_call(:get, _from, state), do: {:reply, state, state}

  def handle_call(:mark_ready, _from, :not_ready), do: {:reply, :ok, :ready}
  def handle_call(:mark_ready, _from, :ready), do: {:reply, :ok, :ready}

  def handle_call(:mark_ready, _from, {:halted, _} = halted) do
    {:reply, {:error, halted}, halted}
  end

  def handle_call(:mark_not_ready, _from, {:halted, _} = halted) do
    {:reply, :ok, halted}
  end

  def handle_call(:mark_not_ready, _from, _state), do: {:reply, :ok, :not_ready}

  def handle_call({:halt, reason}, _from, _state) when is_atom(reason) do
    {:reply, :ok, {:halted, reason}}
  end

  def handle_call(:clear_halt, _from, {:halted, _}) do
    {:reply, :ok, :not_ready}
  end

  def handle_call(:clear_halt, _from, state) do
    {:reply, {:error, :not_halted}, state}
  end
end
