# Add-on: the Flyte SDK's own MCP server (flyte-mcp) in the cluster, talking to Flyte over the in-cluster Service.
# Off by default. The pod installs flyte[mcp] with uv at start-up (needs egress to PyPI), which keeps the add-on
# free of an image build; the trade-off is a slower start and a dependency on PyPI being reachable.

locals {
  # In-cluster callers stay unauthenticated (CONVENTIONS section 7): the cluster network is the trust boundary.
  flyte_internal_endpoint = "http://flyte-http.${kubernetes_namespace_v1.flyte.metadata[0].name}.svc.cluster.local:8090"

  # Tools served: every group except search, whose tools clone git repositories at start-up (git is not in the image).
  mcp_tool_groups = "core,task,run,action,logs,app,trigger,project,secret,condition,identity"

  mcp_path = "/flyte-mcp"
}

resource "kubernetes_namespace_v1" "mcp" {
  # Only with the add-on.
  count = var.enable_mcp ? 1 : 0

  metadata {
    name = "flyte-mcp"
  }
}

resource "kubernetes_config_map_v1" "mcp" {
  # Only with the add-on.
  count = var.enable_mcp ? 1 : 0

  metadata {
    name      = "flyte-mcp"
    namespace = kubernetes_namespace_v1.mcp[0].metadata[0].name
  }

  # The SDK config file the server loads (FLYTECTL_CONFIG): endpoint, no credentials, and the default project; and
  # the entry script that makes the server listen on all interfaces (files/mcp-serve.py says why).
  data = {
    "serve.py" = file("${path.module}/files/mcp-serve.py")
    "config.yaml" = yamlencode({
      admin = {
        endpoint = local.flyte_internal_endpoint
        insecure = true
      }
      task = {
        domain  = var.mcp.domain
        project = var.mcp.project
      }
    })
  }
}

resource "kubernetes_deployment_v1" "mcp" {
  # Only with the add-on.
  count = var.enable_mcp ? 1 : 0

  metadata {
    name      = "flyte-mcp"
    namespace = kubernetes_namespace_v1.mcp[0].metadata[0].name
    labels    = { app = "flyte-mcp" }
  }

  spec {
    replicas = 1

    selector {
      match_labels = { app = "flyte-mcp" }
    }

    template {
      metadata {
        labels = { app = "flyte-mcp" }
        # The config file is a ConfigMap, which does not restart the pod when it changes.
        annotations = { "checksum/config" = sha256(jsonencode(kubernetes_config_map_v1.mcp[0].data)) }
      }

      spec {
        container {
          name  = "flyte-mcp"
          image = var.mcp.image

          command = ["sh", "-c"]
          args = [join(" ", compact([
            "exec uv run --no-project --with 'flyte[mcp]==${var.mcp.flyte_sdk_version}' python /etc/flyte/serve.py",
            "--transport streamable-http --port 8080 --mcp-mount-path ${local.mcp_path}",
            "--tool-groups ${local.mcp_tool_groups}",
            var.mcp.read_only ? "--read-only" : "",
          ]))]

          env {
            name  = "FLYTECTL_CONFIG"
            value = "/etc/flyte/config.yaml"
          }
          # A non-root user has no home directory: keep uv's cache and the SDK's state on the writable volume.
          env {
            name  = "HOME"
            value = "/tmp"
          }
          env {
            name  = "UV_CACHE_DIR"
            value = "/tmp/uv-cache"
          }

          port {
            name           = "http"
            container_port = 8080
          }

          readiness_probe {
            tcp_socket {
              port = "http"
            }
            initial_delay_seconds = 20
            period_seconds        = 10
          }

          security_context {
            allow_privilege_escalation = false
            run_as_non_root            = true
            run_as_user                = 1000
            capabilities {
              drop = ["ALL"]
            }
          }

          volume_mount {
            name       = "config"
            mount_path = "/etc/flyte"
            read_only  = true
          }
          volume_mount {
            name       = "tmp"
            mount_path = "/tmp"
          }
        }

        volume {
          name = "config"
          config_map {
            name = kubernetes_config_map_v1.mcp[0].metadata[0].name
          }
        }
        volume {
          name = "tmp"
          empty_dir {}
        }
      }
    }
  }

  depends_on = [helm_release.flyte]
}

resource "kubernetes_service_v1" "mcp" {
  # Only with the add-on.
  count = var.enable_mcp ? 1 : 0

  metadata {
    name      = "flyte-mcp"
    namespace = kubernetes_namespace_v1.mcp[0].metadata[0].name
  }

  spec {
    selector = { app = "flyte-mcp" }

    port {
      name        = "http"
      port        = 80
      target_port = "http"
    }
  }
}

resource "kubernetes_ingress_v1" "mcp_tailnet" {
  # Only in tailscale mode with the MCP add-on (tailscale mode requires the Tailscale add-on), and not with OAuth:
  # this Ingress would reach the Service directly, around the middlewares.
  count = var.enable_mcp && local.infra.exposure == "tailscale" && !local.oauth ? 1 : 0

  metadata {
    name      = "flyte-mcp-tailnet"
    namespace = kubernetes_namespace_v1.mcp[0].metadata[0].name
  }

  spec {
    ingress_class_name = "tailscale"

    tls {
      hosts = [local.infra.tailscale.mcp_hostname]
    }

    default_backend {
      service {
        name = kubernetes_service_v1.mcp[0].metadata[0].name
        port {
          number = 80
        }
      }
    }
  }

  depends_on = [helm_release.tailscale_operator]
}

# With OAuth on, the MCP endpoint is also served on the Flyte host behind the same middlewares.
resource "kubernetes_ingress_v1" "mcp" {
  # Only with the add-on and OAuth.
  count = var.enable_mcp && local.oauth ? 1 : 0

  metadata {
    name      = "flyte-mcp"
    namespace = kubernetes_namespace_v1.mcp[0].metadata[0].name

    annotations = {
      "traefik.ingress.kubernetes.io/router.middlewares" = local.oauth_middlewares
    }
  }

  spec {
    ingress_class_name = "traefik"

    rule {
      host = local.public ? local.infra.public.hostname : null

      http {
        path {
          path      = local.mcp_path
          path_type = "Prefix"

          backend {
            service {
              name = kubernetes_service_v1.mcp[0].metadata[0].name
              port {
                number = 80
              }
            }
          }
        }
      }
    }
  }

  depends_on = [helm_release.traefik]
}
