defmodule LibclusterCloudFoundry.Mixfile do
  use Mix.Project

  def project do
    [app: :libcluster_cloud_foundry,
     version: "0.1.0",
     elixir: "~> 1.4",
     build_embedded: Mix.env == :prod,
     start_permanent: Mix.env == :prod,
     deps: deps()]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:poison, "~> 3.1"},
      {:libcluster, "~> 2.1", [only: [:test]]},
    ]
  end
end
