# MCP add-on (mcp.tf): off by default, in-cluster and unauthenticated, and how it is exposed.

mock_provider "kubernetes" {}
mock_provider "helm" {}
mock_provider "random" {}
mock_provider "time" {}

# The infra root's outputs for a tailnet deployment without OAuth (infra's contract.tftest.hcl keeps the fixture
# equal to them). Null outputs are left out, as Terraform leaves them out of state.
override_data {
  target = data.terraform_remote_state.infra
  values = {
    outputs = { for k, v in jsondecode(file("tests/fixtures/tailscale.json")) : k => v if v != null }
  }
}

variables {
  tailscale_oauth_client_secret = join("", ["placeholder"])
}

run "off_by_default" {
  command = plan

  assert {
    condition = (
      length(kubernetes_namespace_v1.mcp) == 0 && length(kubernetes_config_map_v1.mcp) == 0 &&
      length(kubernetes_deployment_v1.mcp) == 0 && length(kubernetes_service_v1.mcp) == 0 &&
      length(kubernetes_ingress_v1.mcp_tailnet) == 0 && length(kubernetes_ingress_v1.mcp) == 0
    )
    error_message = "no MCP resources by default"
  }

  assert {
    condition     = output.mcp_url == null
    error_message = "no MCP URL when disabled"
  }
}

run "enabled_on_the_tailnet" {
  command = plan

  variables {
    enable_mcp = true
  }

  assert {
    condition     = length(kubernetes_deployment_v1.mcp) == 1 && length(kubernetes_service_v1.mcp) == 1 && kubernetes_namespace_v1.mcp[0].metadata[0].name == "flyte-mcp"
    error_message = "namespace, Deployment and Service exist"
  }

  assert {
    condition     = yamldecode(kubernetes_config_map_v1.mcp[0].data["config.yaml"]).admin.endpoint == "http://flyte-http.flyte.svc.cluster.local:8090" && yamldecode(kubernetes_config_map_v1.mcp[0].data["config.yaml"]).admin.insecure
    error_message = "the server calls Flyte in-cluster, over plain HTTP"
  }

  assert {
    condition     = !contains(keys(yamldecode(kubernetes_config_map_v1.mcp[0].data["config.yaml"]).admin), "authType") && !strcontains(kubernetes_config_map_v1.mcp[0].data["config.yaml"], "client")
    error_message = "in-cluster callers carry no credentials"
  }

  assert {
    condition     = yamldecode(kubernetes_config_map_v1.mcp[0].data["config.yaml"]).task.project == "flytesnacks" && yamldecode(kubernetes_config_map_v1.mcp[0].data["config.yaml"]).task.domain == "development"
    error_message = "default project and domain"
  }

  assert {
    condition     = strcontains(kubernetes_deployment_v1.mcp[0].spec[0].template[0].spec[0].container[0].args[0], "uv run --no-project --with 'flyte[mcp]==2.12.0' python /etc/flyte/serve.py") && strcontains(kubernetes_deployment_v1.mcp[0].spec[0].template[0].spec[0].container[0].args[0], "--read-only") && strcontains(kubernetes_deployment_v1.mcp[0].spec[0].template[0].spec[0].container[0].args[0], "--mcp-mount-path /flyte-mcp")
    error_message = "flyte-mcp is run read-only from the pinned SDK version"
  }

  assert {
    condition     = strcontains(kubernetes_config_map_v1.mcp[0].data["serve.py"], "kwargs.setdefault(\"host\", \"0.0.0.0\")") && strcontains(kubernetes_config_map_v1.mcp[0].data["serve.py"], "from flyte._bin.mcp import main")
    error_message = "the entry script makes uvicorn bind all interfaces (the SDK offers no --host), or the pod is never Ready"
  }

  assert {
    condition     = kubernetes_deployment_v1.mcp[0].spec[0].template[0].spec[0].container[0].port[0].container_port == 8080 && strcontains(kubernetes_deployment_v1.mcp[0].spec[0].template[0].spec[0].container[0].args[0], "--port 8080") && one([for v in kubernetes_deployment_v1.mcp[0].spec[0].template[0].spec[0].volume : v if v.name == "config"]).config_map[0].name == "flyte-mcp"
    error_message = "the script comes from the ConfigMap mounted at /etc/flyte, and the port matches the container port"
  }

  assert {
    condition     = strcontains(kubernetes_deployment_v1.mcp[0].spec[0].template[0].spec[0].container[0].image, "@sha256:")
    error_message = "the image is pinned by digest"
  }

  assert {
    condition     = kubernetes_deployment_v1.mcp[0].spec[0].template[0].spec[0].container[0].security_context[0].run_as_non_root
    error_message = "the server runs as non-root"
  }

  assert {
    condition     = kubernetes_ingress_v1.mcp_tailnet[0].spec[0].ingress_class_name == "tailscale" && toset(one(kubernetes_ingress_v1.mcp_tailnet[0].spec[0].tls).hosts) == toset(["flyte-mcp"])
    error_message = "the tailnet host is flyte-mcp"
  }

  assert {
    condition     = length(kubernetes_ingress_v1.mcp) == 0
    error_message = "without OAuth there is no Traefik route"
  }

  assert {
    condition     = output.mcp_url == "https://flyte-mcp.${local.infra.tailnet_domain}/flyte-mcp/mcp"
    error_message = "the MCP URL is on the tailnet"
  }
}

run "writable_mode" {
  command = plan

  variables {
    enable_mcp = true
    mcp        = { read_only = false, project = "example" }
  }

  assert {
    condition     = !strcontains(kubernetes_deployment_v1.mcp[0].spec[0].template[0].spec[0].container[0].args[0], "--read-only")
    error_message = "read_only = false drops the flag"
  }

  assert {
    condition     = yamldecode(kubernetes_config_map_v1.mcp[0].data["config.yaml"]).task.project == "example"
    error_message = "mcp.project is honoured"
  }
}

run "public_with_oauth" {
  command = plan

  override_data {
    target = data.terraform_remote_state.infra
    values = {
      outputs = { for k, v in jsondecode(file("tests/fixtures/public.json")) : k => v if v != null }
    }
  }

  variables {
    enable_mcp = true
  }

  assert {
    condition     = length(kubernetes_ingress_v1.mcp) == 1 && length(kubernetes_ingress_v1.mcp_tailnet) == 0
    error_message = "public MCP goes through Traefik only"
  }

  assert {
    condition     = kubernetes_ingress_v1.mcp[0].metadata[0].annotations["traefik.ingress.kubernetes.io/router.middlewares"] == "traefik-strip-identity@kubernetescrd,traefik-oauth@kubernetescrd" && one(kubernetes_ingress_v1.mcp[0].spec[0].rule).host == "flyte.example.com"
    error_message = "the same middlewares and host as Flyte"
  }

  assert {
    condition     = output.mcp_url == "https://flyte.example.com/flyte-mcp/mcp"
    error_message = "the MCP URL is under the public host"
  }
}

run "tailnet_with_oauth" {
  command = plan

  override_data {
    target = data.terraform_remote_state.infra
    values = {
      outputs = { for k, v in jsondecode(file("tests/fixtures/tailscale-oauth.json")) : k => v if v != null }
    }
  }

  variables {
    enable_mcp = true
  }

  assert {
    condition     = length(kubernetes_ingress_v1.mcp) == 1 && length(kubernetes_ingress_v1.mcp_tailnet) == 0
    error_message = "with OAuth the MCP server is reachable only through the Traefik route, not through a tailnet Ingress around the middlewares"
  }

  assert {
    condition     = kubernetes_ingress_v1.mcp[0].metadata[0].annotations["traefik.ingress.kubernetes.io/router.middlewares"] == "traefik-strip-identity@kubernetescrd,traefik-oauth@kubernetescrd"
    error_message = "the Traefik route carries the OAuth middlewares"
  }

  assert {
    condition     = output.mcp_url == "${local.infra.flyte_url}/flyte-mcp/mcp"
    error_message = "the MCP URL is under the Flyte host"
  }
}

run "rejects_a_flyte_sdk_version_that_is_not_a_version" {
  command = plan

  variables {
    enable_mcp = true
    mcp        = { flyte_sdk_version = "1.0.0; rm -rf /" }
  }

  expect_failures = [var.mcp]
}
