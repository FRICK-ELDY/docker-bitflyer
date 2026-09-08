defmodule Bitflyer.System do
  @moduledoc """
  開発・稼働確認用の Domain。取引エンティティは置かない。
  """
  use Ash.Domain,
    otp_app: :bitflyer

  resources do
    resource Bitflyer.System.Heartbeat
  end

  @doc """
  Repo 経由で PostgreSQL に到達できるか確認する。
  """
  def check_database do
    try do
      case Ecto.Adapters.SQL.query(Bitflyer.Repo, "SELECT 1", [], timeout: 2_000) do
        {:ok, _} -> :ok
        {:error, error} -> {:error, Exception.message(error)}
      end
    rescue
      error -> {:error, Exception.message(error)}
    catch
      :exit, reason -> {:error, "Database repo is not running: #{inspect(reason)}"}
    end
  end

  @doc """
  現在の取引モード（`dry_run` / `paper` / `live`）。
  """
  def trade_mode do
    Application.get_env(:bitflyer, :trade_mode, "dry_run")
  end
end
