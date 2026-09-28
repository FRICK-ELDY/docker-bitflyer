defmodule Bitflyer.Risk.DrainHalt do
  @moduledoc """
  HWM の drain 失敗を、Postgres の外に残す。

  drain が落ちるときは DB も書けないことが多い。RiskState への halt が
  失敗すると、メモリ上の停止は再起動で消える。先にローカルファイルを置き、
  次の起動の突合が Ready にする前に止める。印を消したあとも、DB に残った
  halt を ETS へ載せてから Ready を判定する。成功した突合は停止を解除しない。
  """

  alias Bitflyer.Readiness

  @default_name "persist_failed"

  @spec path() :: String.t()
  def path do
    Application.get_env(:bitflyer, __MODULE__, [])
    |> Keyword.get_lazy(:path, &default_path/0)
  end

  # 本番 Compose は BITFLYER_DRAIN_HALT_PATH を halt_marker ボリュームへ向ける。
  # 未設定時だけ tmp。tmp は同じコンテナの再起動では残るが、作り直しや掃除では消える。
  defp default_path do
    case System.get_env("BITFLYER_DRAIN_HALT_PATH") do
      path when is_binary(path) and path != "" -> path
      _ -> Path.join(System.tmp_dir!(), "bitflyer-hwm-drain-halt")
    end
  end

  @doc """
  drain 失敗を記録する。ファイルを先に書き、その後 RiskState へ halt する。

  `:persisted` は DB に halt がある。`:marker_only` はファイルだけが残っている。
  """
  @spec record(keyword()) :: :persisted | :marker_only | :unrecorded
  def record(opts \\ []) do
    marker = write_marker()
    readiness = Keyword.get(opts, :readiness, Readiness)
    _ = readiness.halt(:persist_failed)

    case open_circuit(opts) do
      :ok ->
        _ = clear_marker()
        :persisted

      {:error, error} ->
        if marker == :ok do
          Bitflyer.Telemetry.log(
            :critical,
            "peak drain halt is only on the local marker; RiskState was not updated",
            %{reason: inspect(error)}
          )

          :marker_only
        else
          Bitflyer.Telemetry.log(
            :critical,
            "peak drain halt was not written to RiskState or the local marker",
            %{reason: inspect(error)}
          )

          :unrecorded
        end
    end
  end

  @doc """
  起動時。印が無ければ `:clear`。あればメモリを止め、DB へ書き直す。

  DB に書けたら印を消す。書けなければ印を残し、この起動は Ready にしない。
  """
  @spec enforce(keyword()) :: :clear | :halted
  def enforce(opts \\ []) do
    if File.exists?(path()) do
      readiness = Keyword.get(opts, :readiness, Readiness)
      _ = readiness.halt(:persist_failed)

      case open_circuit(opts) do
        :ok ->
          _ = clear_marker()

          Bitflyer.Telemetry.log(:info, "peak drain halt restored into RiskState", %{
            reason: :persist_failed
          })

        {:error, error} ->
          Bitflyer.Telemetry.log(
            :critical,
            "peak drain halt remains on the local marker; RiskState update failed",
            %{reason: inspect(error)}
          )
      end

      :halted
    else
      :clear
    end
  end

  @doc """
  印のファイルがあるか。
  """
  @spec marker_written?() :: boolean()
  def marker_written?, do: File.exists?(path())

  @doc """
  手動復帰が成功したあとに印を消す。失敗のままでは消さない。
  """
  @spec clear_marker() :: :ok | {:error, term()}
  def clear_marker do
    case File.rm(path()) do
      :ok ->
        :ok

      {:error, :enoent} ->
        :ok

      {:error, reason} = error ->
        Bitflyer.Telemetry.log(:critical, "failed to remove peak drain halt marker", %{
          reason: inspect(reason)
        })

        error
    end
  end

  defp open_circuit(opts) do
    case Keyword.get(opts, :open_circuit) do
      fun when is_function(fun, 1) ->
        if test_injections_allowed?() do
          fun.(:persist_failed)
        else
          Bitflyer.Risk.open_circuit(:persist_failed)
        end

      _ ->
        Bitflyer.Risk.open_circuit(:persist_failed)
    end
  end

  defp write_marker do
    path = path()
    File.mkdir_p!(Path.dirname(path))

    # :sync で fsync する。本番の置き場所は halt_marker ボリューム。
    File.open!(path, [:write, :binary, :sync], fn io ->
      IO.binwrite(io, @default_name)
    end)

    :ok
  rescue
    error ->
      Bitflyer.Telemetry.log(:critical, "failed to write peak drain halt marker", %{
        reason: inspect(error)
      })

      :error
  end

  defp test_injections_allowed? do
    :bitflyer
    |> Application.get_env(Bitflyer.Risk, [])
    |> Keyword.get(:allow_test_injections, false) == true
  end
end
