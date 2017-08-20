defmodule Cluster.Strategy.CloudFoundryEurekaTest do
  use ExUnit.Case
  import Cluster.Strategy.CloudFoundryEureka

  defmodule StubHttpcGetToken do
    def request(method, {uri, headers, content_type, body}, [], []) do
      send self(), %{method: method, uri: uri, headers: headers, content_type: content_type, body: body}
      response = """
      { "access_token": "the-access-token" }
      """
      {:ok, {{nil, 200, nil}, nil, '#{response}'}}
    end
  end

  defmodule StubHttpcRegisterInstance do
    def request(method, {uri, headers, content_type, body}, [], []) do
      send self(), %{method: method, uri: uri, headers: headers, content_type: content_type, body: body}
      {:ok, {{nil, 204, nil}, nil, ''}}
    end
  end

  defmodule StubHttpcGetInstances do
    def request(method, {uri, headers}, [], []) do
      send self(), %{method: method, uri: uri, headers: headers}
      response = """
        {
            "application": {
                "instance": [
                    { "hostName": "app1@host1" },
                    { "hostName": "thisapp@thishost" },
                    { "hostName": "app2@host2" }
                ]
            }
        }
      """
      {:ok, {{nil, 200, nil}, nil, '#{response}'}}
    end
  end

  test "#parse_credentials" do
    env = """
    {
      "p-service-registry": [
       {
        "credentials": {
         "access_token_uri": "https://p-spring-cloud-services.uaa.run.pivotal.io/oauth/token",
         "client_id": "the-client-id",
         "client_secret": "the-client-secret",
         "uri": "https://eureka-host.cfapps.io"
        },
        "label": "p-service-registry",
        "name": "eureka",
        "plan": "standard",
        "provider": null,
        "syslog_drain_url": null,
        "tags": [
         "eureka",
         "discovery",
         "registry",
         "spring-cloud"
        ],
        "volume_mounts": []
       }
      ]
     }
    """

    data = parse_eureka_credentials(env)

    assert data.access_token_uri == "https://p-spring-cloud-services.uaa.run.pivotal.io/oauth/token"
    assert data.client_id == "the-client-id"
    assert data.client_secret == "the-client-secret"
    assert data.eureka_base_uri == "https://eureka-host.cfapps.io"
  end

  test "#get_token" do
    token = get_token("http://example.com/oauth/token", "the-client-id", "the-client-secret", StubHttpcGetToken)
    assert token == "the-access-token"
    receive do
      message ->
        assert message == %{
          method: :post,
          uri: 'http://example.com/oauth/token',
          headers: [{'Authorization', 'Basic dGhlLWNsaWVudC1pZDp0aGUtY2xpZW50LXNlY3JldA=='}],
          content_type: 'application/x-www-form-urlencoded',
          body: 'grant_type=client_credentials'
        }
    end
  end

  test "#register_instance" do
    register_instance("http://example.com", "myApp", "the-access-token", :"foonode@barhost", StubHttpcRegisterInstance)
    receive do
      message ->
        assert message.method == :post
        assert message.uri == 'http://example.com/eureka/apps/myApp'
        assert message.headers == [{'Authorization', 'Bearer the-access-token'}]
        assert message.content_type == 'application/json'
        assert is_list(message.body)
        assert Poison.decode!(message.body, keys: :atoms!) == %{
         instance: %{
           hostName: "foonode@barhost",
           status: "UP",
           app: "myApp",
           dataCenterInfo: %{
             :"@class" => "com.netflix.appinfo.InstanceInfo$DefaultDataCenterInfo",
             name: "MyOwn",
           },
          },
        }
    end
  end

  test "#get_instances" do
    instances = get_instances("http://example.com", "myApp", "the-access-token", :"thisapp@thishost", StubHttpcGetInstances)

    assert instances == [:"app1@host1", :"app2@host2"]
    receive do
      message ->
        assert message.method == :get
        assert message.uri == 'http://example.com/eureka/apps/myApp'
        assert message.headers == [{'Authorization', 'Bearer the-access-token'}, {'Accept', 'application/json'}]
    end
  end
end
