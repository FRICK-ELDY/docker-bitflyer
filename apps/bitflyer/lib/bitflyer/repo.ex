defmodule Bitflyer.Repo do
  use AshPostgres.Repo,
    otp_app: :bitflyer

  @impl true
  def installed_extensions do
    ["ash-functions"]
  end

  @impl true
  def min_pg_version do
    %Version{major: 16, minor: 0, patch: 0}
  end
end
