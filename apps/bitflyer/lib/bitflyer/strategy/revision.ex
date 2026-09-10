defmodule Bitflyer.Strategy.Revision do
  @moduledoc """
  戦略パラメータ revision の確定とハッシュ。

  Runner 起動時に `ensure_current/1` で履歴行を確定し、注文にはその UUID を載せる。
  判定ループ内では Resource を触らない。
  """

  require Ash.Query

  alias Bitflyer.Strategy
  alias Bitflyer.Trading.StrategyParameterRevision

  @type ensure_opts :: [
          trade_mode: atom(),
          module: module(),
          params: map() | keyword(),
          throttle_ms: non_neg_integer(),
          source: :boot | :ops,
          operator: String.t()
        ]

  @doc """
  現行戦略設定の revision を返す。

  `(trade_mode, params_hash)` が既存なら再利用。無ければ create。
  一意制約競合時は再読込する（並行 ensure 向け）。
  """
  @spec ensure_current(ensure_opts()) ::
          {:ok, StrategyParameterRevision.t()} | {:error, term()}
  def ensure_current(opts \\ []) do
    trade_mode = Keyword.get_lazy(opts, :trade_mode, &Bitflyer.TradeMode.current/0)
    module = Keyword.get_lazy(opts, :module, &Strategy.module/0)
    params = normalize_params(Keyword.get_lazy(opts, :params, &Strategy.params/0))
    throttle_ms = Keyword.get(opts, :throttle_ms, Strategy.throttle_ms())
    source = Keyword.get(opts, :source, :boot)
    operator = Keyword.get(opts, :operator, "system")

    strategy_module = module_name(module)
    params_map = stringify_params(params)
    hash = params_hash(strategy_module, params_map, throttle_ms)

    case find_by_hash(trade_mode, hash) do
      {:ok, %StrategyParameterRevision{} = revision} ->
        {:ok, revision}

      {:ok, nil} ->
        attrs = %{
          trade_mode: trade_mode,
          strategy_module: strategy_module,
          params: params_map,
          params_hash: hash,
          throttle_ms: throttle_ms,
          source: source,
          operator: operator
        }

        case create_revision(attrs) do
          {:ok, revision} ->
            {:ok, revision}

          {:error, _error} ->
            # 並行 create で一意制約に負けた場合は勝ち行を返す
            case find_by_hash(trade_mode, hash) do
              {:ok, %StrategyParameterRevision{} = revision} -> {:ok, revision}
              {:ok, nil} -> {:error, :revision_create_race}
              {:error, error} -> {:error, error}
            end
        end

      {:error, error} ->
        {:error, error}
    end
  end

  @doc """
  発注意図 command の安定ハッシュ（由来追跡用）。
  """
  @spec command_hash(map()) :: String.t()
  def command_hash(command) when is_map(command) do
    payload = %{
      "internal_order_id" =>
        Map.get(command, :internal_order_id) || Map.get(command, "internal_order_id"),
      "product_code" => Map.get(command, :product_code) || Map.get(command, "product_code"),
      "side" => atom_or_string(Map.get(command, :side) || Map.get(command, "side")),
      "size" => decimal_or_string(Map.get(command, :size) || Map.get(command, "size")),
      "order_type" =>
        atom_or_string(Map.get(command, :order_type) || Map.get(command, "order_type") || :market),
      "price" => decimal_or_string(Map.get(command, :price) || Map.get(command, "price"))
    }

    payload
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc false
  @spec params_hash(String.t(), map(), non_neg_integer()) :: String.t()
  def params_hash(strategy_module, params_map, throttle_ms)
      when is_binary(strategy_module) and is_map(params_map) and is_integer(throttle_ms) do
    %{
      "strategy_module" => strategy_module,
      "params" => params_map,
      "throttle_ms" => throttle_ms
    }
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp create_revision(attrs) do
    applied_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    StrategyParameterRevision
    |> Ash.Changeset.for_create(:create, Map.put(attrs, :applied_at, applied_at))
    |> Ash.create()
  end

  defp find_by_hash(trade_mode, hash) do
    StrategyParameterRevision
    |> Ash.Query.filter(trade_mode == ^trade_mode and params_hash == ^hash)
    |> Ash.Query.limit(1)
    |> Ash.read_one()
  end

  defp normalize_params(params) when is_map(params), do: params
  defp normalize_params(params) when is_list(params), do: Map.new(params)

  defp stringify_params(params) when is_map(params) do
    params
    |> Enum.map(fn {k, v} -> {to_string(k), json_value(v)} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Map.new()
  end

  defp json_value(%Decimal{} = d), do: Decimal.to_string(d, :normal)
  defp json_value(v) when is_atom(v), do: Atom.to_string(v)
  defp json_value(v) when is_binary(v) or is_number(v) or is_boolean(v) or is_nil(v), do: v

  defp json_value(v) when is_list(v), do: Enum.map(v, &json_value/1)

  defp json_value(v) when is_map(v) do
    v
    |> Enum.map(fn {k, val} -> {to_string(k), json_value(val)} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Map.new()
  end

  defp json_value(v), do: inspect(v)

  defp module_name(module) when is_atom(module), do: Atom.to_string(module)
  defp module_name(module) when is_binary(module), do: module

  defp atom_or_string(nil), do: nil
  defp atom_or_string(v) when is_atom(v), do: Atom.to_string(v)
  defp atom_or_string(v) when is_binary(v), do: v
  defp atom_or_string(v), do: inspect(v)

  defp decimal_or_string(nil), do: nil
  defp decimal_or_string(%Decimal{} = d), do: Decimal.to_string(d, :normal)
  defp decimal_or_string(v) when is_binary(v) or is_number(v), do: to_string(v)
  defp decimal_or_string(v), do: inspect(v)
end
