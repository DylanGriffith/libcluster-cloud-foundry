# Libcluster - Cloud Foundry

This is a Cloud Foundry strategy for [libcluster](https://github.com/bitwalker/libcluster).

It makes use of Container to Container (C2C) networking and the "Spring Cloud Services" Service Registry service. This service is essentially just a [Eureka](https://github.com/Netflix/eureka) server that your instances will register with and poll periodically to find the other nodes.

# Configuration

Add this dependency to your project:

```elixir
defp deps do
  [
    {:libcluster, "~> 2.1"},
    {:libcluster_cloud_foundry, git: "https://github.com/DylanGriffith/libcluster-cloud-foundry.git"},
  ]
end
```

You will also need to update your start command in `mix.exs` to set the correct name for your node. The following example is something that has worked for me:

```yaml
---
applications:
  - name: my-clustered-app
    instances: 4
    memory: 1G
    buildpack: https://github.com/HashNuke/heroku-buildpack-elixir.git
    command: elixir --name app$CF_INSTANCE_INDEX@$CF_INSTANCE_INTERNAL_IP --cookie secret-cookie --erl "-kernel inet_dist_listen_min 9001 inet_dist_listen_max 9001" -S mix run --no-halt
```

You will need to create a Service Registry for this plugin to work:

```
$ cf create-service p-service-registry standard service-registry
```

This usually takes a few minutes to finish setting up before you can bind it to your app. You can check the status by running `cf services`.

Once the service status changes to `create succeeded` you can bind it to your app like so:

```
$ cf bind-service my-clustered-app service-registry
```

In order to access the new C2C features you need to install the [network-policy plugin](https://github.com/cloudfoundry-incubator/cf-networking-release) if you don't already have it installed:

```
$ cf install-plugin -r CF-Community network-policy
```

Next you'll need to enable TCP access via the epmd port (4369) and the TCP port your app is configured to listen on:

```
$ cf allow-access my-clustered-app my-clustered-app --protocol tcp --port 4369
$ cf allow-access my-clustered-app my-clustered-app --protocol tcp --port 9001
```

You then want to update your `config/prod.exs` to use the strategy:

```elixir
use Mix.Config

config :libcluster,
  topologies: [
    cf_clustering: [
      strategy: Cluster.Strategy.CloudFoundryEureka,
      config: [
      ]
    ]
  ]
```

Now after deploying your app you should find that nodes are correctly discovering and connecting to each other. You can view the logs to see when nodes are connecting to each other.
