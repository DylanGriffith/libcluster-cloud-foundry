defmodule Cluster.Strategy.CloudFoundryEureka do
  @moduledoc """
  An example configuration is below:
      config :libcluster,
        topologies: [
          cf_clustering: [
            strategy: #{__MODULE__},
            config: [
              polling_interval: 10_000]]]
  """
  use GenServer
  use Cluster.Strategy
  import Cluster.Logger

  alias Cluster.Strategy.State

  @default_polling_interval 10_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def init(opts) do
    vcap_application = Poison.decode!(System.get_env("VCAP_APPLICATION"))
    app_name = vcap_application["application_name"]
    %{
      access_token_uri: access_token_uri,
      client_id: client_id,
      client_secret: client_secret,
      eureka_base_uri: eureka_base_uri,
    } = parse_eureka_credentials(System.get_env("VCAP_SERVICES"))

    config = Enum.into(Keyword.fetch!(opts, :config), %{})

    state = %State{
      topology: Keyword.fetch!(opts, :topology),
      connect: Keyword.fetch!(opts, :connect),
      disconnect: Keyword.fetch!(opts, :disconnect),
      list_nodes: Keyword.fetch!(opts, :list_nodes),
      config: Map.merge(
        config,
        %{
          app_name: app_name,
          access_token_uri: access_token_uri,
          client_id: client_id,
          client_secret: client_secret,
          eureka_base_uri: eureka_base_uri,
        }
      ),
      meta: MapSet.new([])
    }

    {:ok, state, 0}
  end

  def handle_info(:timeout, state) do
    handle_info(:load, state)
  end
  def handle_info(:load, %State{topology: topology, connect: connect, disconnect: disconnect, list_nodes: list_nodes} = state) do
    new_nodelist = MapSet.new(get_nodes(state))
    added        = MapSet.difference(new_nodelist, state.meta)
    removed      = MapSet.difference(state.meta, new_nodelist)
    new_nodelist = case Cluster.Strategy.disconnect_nodes(topology, disconnect, list_nodes, MapSet.to_list(removed)) do
                :ok ->
                  new_nodelist
                {:error, bad_nodes} ->
                  # Add back the nodes which should have been removed, but which couldn't be for some reason
                  Enum.reduce(bad_nodes, new_nodelist, fn {n, _}, acc ->
                    MapSet.put(acc, n)
                  end)
              end
    new_nodelist = case Cluster.Strategy.connect_nodes(topology, connect, list_nodes, MapSet.to_list(added)) do
              :ok ->
                new_nodelist
              {:error, bad_nodes} ->
                # Remove the nodes which should have been added, but couldn't be for some reason
                Enum.reduce(bad_nodes, new_nodelist, fn {n, _}, acc ->
                  MapSet.delete(acc, n)
                end)
            end
    Process.send_after(self(), :load, Map.get(state.config, :polling_interval, @default_polling_interval))
    {:noreply, %{state | :meta => new_nodelist}}
  end

  def handle_info(_, state) do
    {:noreply, state}
  end

  @spec get_nodes(State.t) :: [atom()]
  defp get_nodes(%State{config: config}) do
    access_token = get_token(config.access_token_uri, config.client_id, config.client_secret)
    register_instance(config.eureka_base_uri, config.app_name, access_token)
    get_instances(config.eureka_base_uri, config.app_name, access_token)
  end

  def get_instances(base_uri, app_name, access_token, node_name \\ :erlang.node, httpc \\ :httpc) do
    auth = 'Bearer #{access_token}'
    uri = '#{base_uri}/eureka/apps/#{app_name}'
    case httpc.request(:get, {uri, [{'Authorization', auth}, {'Accept', 'application/json'}]}, [], []) do
      {:ok, {{_version, 200, _status}, _headers, body}} ->
        data = Poison.decode!(body)
        data["application"]["instance"]
        |> Enum.map(fn(i) -> String.to_atom(i["hostName"]) end)
        |> Enum.reject(fn(n) -> n == node_name end)
      {:ok, {{_version, status, _status}, _headers, body}} ->
        error Cluster.Strategy.CloudFoundryEureka, "cannot get instances (#{status}): #{body}"
        []
      {:error, reason} ->
        error Cluster.Strategy.CloudFoundryEureka, "request to get instances failed!: #{inspect reason}"
        []
    end
  end

  def register_instance(base_uri, app_name, access_token, node_name \\ :erlang.node, httpc \\ :httpc) do
    auth = 'Bearer #{access_token}'
    uri = '#{base_uri}/eureka/apps/#{app_name}'
    body = Poison.encode!(%{
                        instance: %{
                          hostName: node_name,
                          status: "UP",
                          app: app_name,
                          dataCenterInfo: %{
                            "@class" => "com.netflix.appinfo.InstanceInfo$DefaultDataCenterInfo",
                            "name" => "MyOwn",
                          }
                        }
                      })
    case httpc.request(:post, {uri, [{'Authorization', auth}], 'application/json', String.to_charlist(body)}, [], []) do
      {:ok, {{_version, 204, _status}, _headers, _body}} ->
        :ok
      {:ok, {{_version, status, _status}, _headers, body}} ->
        error Cluster.Strategy.CloudFoundryEureka, "cannot register instance (#{status}): #{body}"
        :error
      {:error, reason} ->
        error Cluster.Strategy.CloudFoundryEureka, "request to get token failed!: #{inspect reason}"
        :error
    end
  end

  def get_token(uri, client_id, client_secret, httpc \\ :httpc) do
    basic_auth = 'Basic #{:base64.encode_to_string('#{client_id}:#{client_secret}')}'
    case httpc.request(:post, {String.to_charlist(uri), [{'Authorization', basic_auth}], 'application/x-www-form-urlencoded', 'grant_type=client_credentials'}, [], []) do
      {:ok, {{_version, 200, _status}, _headers, body}} ->
        Poison.decode!(body)["access_token"]
      {:ok, {{_version, status, _status}, _headers, body}} ->
        error Cluster.Strategy.CloudFoundryEureka, "cannot get token (#{status}): #{body}"
        nil
      {:error, reason} ->
        error Cluster.Strategy.CloudFoundryEureka, "request to get token failed!: #{inspect reason}"
        nil
    end
  end

  def parse_eureka_credentials(vcap_services) do
    data = Poison.decode!(vcap_services)

    [service] = data["p-service-registry"]
    %{
      access_token_uri: service["credentials"]["access_token_uri"],
      client_id: service["credentials"]["client_id"],
      client_secret: service["credentials"]["client_secret"],
      eureka_base_uri: service["credentials"]["uri"]
    }
  end
end
