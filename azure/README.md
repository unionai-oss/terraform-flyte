# Flyte on Azure

Terraform that deploys open-source [Flyte 2](https://www.union.ai/docs/v2/flyte/) (`flyte-binary` chart) on Azure
Kubernetes Service: VNet and cluster, a blob container, Azure Database for PostgreSQL (flexible server), Entra
Workload ID identities for Flyte's service accounts, and a front door that is either a Tailscale tailnet or a public
hostname behind OAuth. Optional add-ons: Tailscale access and the Flyte MCP server.

Two root modules, applied in order: `infra/` creates everything through the Azure and Entra APIs, then `helm/`
installs everything through the Kubernetes API. `helm/` reads all it needs from the state of `infra/`; nothing is
copied between the two by hand.

Validated (fmt, validate, tflint, terraform test with mock providers) but not yet applied live.

## What it creates

`infra/`:

| File | Resources |
| --- | --- |
| `main.tf` | The base, identical to `terraform-union-dataplane/azure/infra`: resource group, VNet and private node subnet, NAT gateway, AKS (Azure CNI overlay, OIDC issuer, workload identity, Entra ID with Azure RBAC, no local accounts, Container Insights with its data collection rule and association), a system pool (3 non-burstable nodes), optional worker and GPU pools that scale from zero, Log Analytics workspace, cluster-admin role assignments, and a 120 s wait after them so the role reaches the Kubernetes API before the infra apply returns. |
| `flyte.tf` | Storage account (shared-key access off, TLS 1.2, no public blobs) and one private container; PostgreSQL flexible server 17 in a subnet delegated to it (no public endpoint) with a private DNS zone `<name>.private.postgres.database.azure.com` linked to the VNet, the `flyte` database and a `random_password`; user-assigned identities `<name>-backend` and `<name>-task` federated to the service accounts `flyte/flyte-backend` and `flyte/flyte-task`, with their storage roles; the `postgres` subnet that `main.tf` merges into the VNet (`local.product_subnets`). |
| `exposure.tf` | No resources: the exposure mode, whether OAuth is on, and the Flyte URL, which the Entra redirect URIs need. |
| `oauth.tf` | When OAuth is on: one Microsoft Entra ID app registration (web platform for oauth2-proxy, public-client platform for the `flyte` CLI and SDK), its service principal, and a federated credential that lets oauth2-proxy sign in with its pod's workload identity token instead of a client secret. |

`helm/`:

| File | Resources |
| --- | --- |
| `main.tf` | The helm base, identical to `terraform-union-dataplane/azure/helm`: the remote state of `infra/`, the `kubernetes` and `helm` providers, and with `gpu_node_pool.enabled` the NVIDIA device plugin. |
| `flyte.tf` | The `flyte` namespace, the `flyte-task` service account, and the `flyte-binary` `v2.0.51` Helm release (values in `templates/flyte-values.yaml.tmpl`; the console image is pinned by tag and digest). |
| `exposure.tf` | The front door (below): Traefik, cert-manager (public only), the Flyte and discovery Ingresses, and the `load_balancer_address` lookup. In public mode a `time_sleep` that gives AKS time to delete Traefik's load balancer on destroy. |
| `oauth.tf` | When OAuth is on: a cookie secret and oauth2-proxy. |
| `tailscale.tf` | Add-on: Tailscale operator and the Ingress for the tailnet. |
| `mcp.tf` | Add-on: the Flyte MCP server. |

Role assignments (`infra/`): `Storage Blob Data Contributor` for the backend identity on the storage account (the
storage client resolves the container through account-level calls) and for the task identity on the container only
(task pods touch nothing else); `Azure Kubernetes Service RBAC Cluster Admin` for whoever runs Terraform (from
`main.tf`).

Base modules: `Azure/avm-res-network-virtualnetwork/azurerm` `0.22.3`, `Azure/avm-res-network-natgateway/azurerm`
`0.3.2` (the VNet module has no NAT gateway) and `Azure/avm-res-containerservice-managedcluster/azurerm` `0.8.7`.
Everything else is provider resources and Helm charts, pinned exactly: `flyte-binary` v2.0.51, `traefik` 42.2.0,
`cert-manager` v1.21.3, `oauth2-proxy` 10.7.1, `tailscale-operator` 1.104.2, `nvidia-device-plugin` 0.20.1. Providers
besides the shared pins: `hashicorp/time` `~> 0.13` (the waits, in both roots) and `azure/modtm` `~> 0.4` (in
`infra/`, declared so the tests can mock the AVM modules' telemetry provider; telemetry is off). `helm/` declares no
Azure provider.

## Prerequisites

- Terraform `>= 1.11.0, < 2.0.0` and the **Azure CLI** signed in (`az login`). For the helm apply also
  **[kubelogin](https://azure.github.io/kubelogin/) on `PATH`**: its Kubernetes and Helm providers run
  `kubelogin get-token --login azurecli --server-id <cluster's Entra server application>`, reusing the `az login`
  session, so no cluster credential is stored. The server application ID is an output of `infra/`
  (`kubelogin_server_id`, read from the user kubeconfig the AKS module exposes), so none is written into the
  configuration. Local accounts are disabled, so there is no static admin kubeconfig. In CI, set the `ARM_*`
  variables and sign in with `az login --service-principal`.
- `ARM_SUBSCRIPTION_ID` set for the infra apply (the provider requires it); other `ARM_*` variables work too.
  Credentials are never Terraform variables. The `azuread` provider uses the same sign-in.
- Owner, or Contributor plus User Access Administrator, on the subscription (role assignments), and the Entra
  permission to create app registrations (Application Developer or Application Administrator) when OAuth is on. The
  identity that runs the infra apply becomes cluster admin; run the helm apply as that identity (or add yours to
  `cluster_admin_principal_ids`).
- Resource providers registered on the subscription (`Microsoft.ContainerService`, `Storage`, `Network`,
  `OperationalInsights`, `ManagedIdentity`, `DBforPostgreSQL`, `Authorization`) and vCPU quota for the pools.
- **A route to the AKS API endpoint for the helm apply** (the infra apply only talks to Azure APIs). The endpoint is
  public (the nodes are private), and it is never open to any address by default: `api_server_authorized_ip_ranges`
  is required and must include the address you run the helm apply from (an empty list is rejected unless
  `allow_public_api_endpoint = true`). Access still needs Entra sign-in and the cluster-admin role. Azure RBAC can
  take a minute or two to reach the cluster: the infra apply waits 120 s for it; if the helm apply still fails with
  `Forbidden`, apply it again.
- For `exposure = "tailscale"`: a tailnet with MagicDNS and HTTPS enabled, an ACL tag for the proxies (default
  `tag:k8s`) owned by `tag:k8s-operator`, and a Tailscale OAuth client with the `Devices: Core` and `Auth Keys`
  write scopes (see the operator docs). Pass its secret to the helm apply with `TF_VAR_tailscale_oauth_client_secret`.
- For `exposure = "public"`: a DNS name you control. After the helm apply, create an A record from it to the
  `load_balancer_address` output (on AKS the load balancer has an IP address, not a hostname).

## Apply

```bash
az login
export ARM_SUBSCRIPTION_ID=$(az account show --query id -o tsv)
terraform -chdir=azure/infra init && terraform -chdir=azure/infra apply -var-file=../../examples/azure/infra/tailscale.tfvars
terraform -chdir=azure/helm  init && terraform -chdir=azure/helm  apply -var-file=../../examples/azure/helm/tailscale.tfvars
```

Use the same scenario in both roots, edited for your values: `tailscale.tfvars` (tailnet only, no OAuth; the helm
one turns MCP on) or `public.tfvars` (public, OAuth for an allowed email domain; the helm one sets nothing). Every
choice about the deployment (exposure mode, OAuth, Tailscale, the GPU pool) is an `infra/` input, so a
misconfiguration fails the first plan, before anything is built. `helm/` takes only the MCP add-on, the Tailscale
client secret and `infra_state`. A second deployment in the same subscription needs a different `name`.

## State and backends

Neither root has a `backend` block: where state lives is your choice.

1. **First run, nothing configured:** both roots use local state, and `helm/` reads `../infra/terraform.tfstate`
   (`infra_state` defaults to that).
2. **Remote state (recommended):** add a `backend.tf` to both roots, then tell `helm/` where the infra state is,
   once, in its tfvars, with the same settings as the infra backend block:
   ```hcl
   infra_state = { backend = "azurerm", config = { resource_group_name = "example-tfstate", storage_account_name = "exampletfstate", container_name = "tfstate", key = "flyte/azure/infra.tfstate", use_azuread_auth = true } }
   ```
3. Both states are secrets. `infra/` holds the database password; `helm/` holds it again (it reads it from `infra/`
   and passes it to the Flyte release), plus the cookie secret and the Tailscale secret. Use backends with encryption
   at rest and restricted access, and give the helm runner read-only access to the infra state.

Terraform workspaces are not supported: `helm/` reads the infra root's default workspace.

## Destroy, in reverse

```bash
terraform -chdir=azure/helm  destroy -var-file=../../examples/azure/helm/tailscale.tfvars
terraform -chdir=azure/infra destroy -var-file=../../examples/azure/infra/tailscale.tfvars
```

`helm/` first: it removes Traefik's load balancer and public IP and then waits two minutes
(`time_sleep.traefik_destroy`) for AKS' cloud controller to delete them. Destroying `infra/` first deletes the cluster
under the releases; recovering takes `terraform -chdir=azure/helm state rm` of everything.

## Inputs

`infra/`:

| Variable | Meaning |
| --- | --- |
| `region` | Required, no default. The Azure location. |
| `exposure` | Required: `tailscale` or `public`. |
| `name` | Prefix for resource names and the cluster name (default `flyte`). 4-54 characters: lowercase letters, digits and single hyphens, starting with a letter and not ending in a hyphen, so every name built from it is legal (the Log Analytics workspace needs 4, the AKS DNS prefix allows 54, blob containers reject `--`). Storage account names are the name without hyphens cut to 16 characters plus the random suffix. |
| `database` | `{ sku_name = "B_Standard_B1ms", storage_mb = 32768, version = "17" }`. The default burstable size is for trials; use a General Purpose sku in production. B1ms accepts about 50 connections, so the Flyte connection pool is capped at 25 open (`configuration.database.maxOpenConnections`); raise it in `helm/templates/flyte-values.yaml.tmpl` with a larger sku. |
| `postgres_subnet_cidr` | Subnet delegated to Postgres (default `10.0.64.0/24`); inside `address_space`, outside `nodes_cidr`. |
| `system_node_pool`, `worker_node_pool`, `gpu_node_pool` | Node pools; the worker and GPU pools scale from zero. |
| `api_server_authorized_ip_ranges`, `allow_public_api_endpoint`, `cluster_admin_principal_ids` | See Prerequisites. `api_server_authorized_ip_ranges` is required (non-empty) unless `allow_public_api_endpoint = true`. |
| `address_space`, `nodes_cidr`, `pod_cidr`, `service_cidr`, `dns_service_ip`, `kubernetes_version`, `log_analytics_workspace_id`, `tags` | Base, same as the dataplane. |
| `public`, `oauth`, `enable_oauth` | Public mode and OAuth settings. |
| `enable_tailscale`, `tailscale` | Tailscale add-on (installed by `helm/`). |

`helm/`:

| Variable | Meaning |
| --- | --- |
| `infra_state` | Where the infra state is (State and backends). Default: `../infra/terraform.tfstate`. |
| `tailscale_oauth_client_secret` | Required when `infra/` has `enable_tailscale = true`; set it with `TF_VAR_tailscale_oauth_client_secret`. An input of this root, not of `infra/`, so it never reaches the infra state that this root reads in full. |
| `enable_mcp`, `mcp` | MCP add-on. |

## Outputs

`infra/`: `backend_client_id`, `bucket_name` (the container), `cluster_ca_certificate` (sensitive),
`cluster_endpoint` (sensitive), `cluster_name`, `database_host`, `database_name`, `database_password` (sensitive),
`database_username`, `enable_tailscale`, `exposure`, `flyte_config`, `flyte_url`, `gpu_node_pool`,
`gpu_node_selector`, `kubeconfig_command`, `kubelogin_server_id` (sensitive), `log_analytics_workspace_id`, `nat_gateway_public_ip`,
`oauth`, `oauth_callback_url`, `oauth_cli_client_id`, `oauth_cli_redirect_uri`, `oauth_client_id`, `oauth_enabled`,
`oauth_issuer_url`, `oidc_issuer_url`, `public`, `region`, `resource_group_name`, `service_accounts`,
`storage_account_name`, `tailnet_domain`, `tailscale`, `task_client_id`. Most exist for `helm/`;
`enable_tailscale`, `exposure`, `gpu_node_pool`, `oauth`, `public` and `tailscale` pass the inputs of the same name
through. On Azure one app registration serves oauth2-proxy and the CLI, so `oauth_client_id` and
`oauth_cli_client_id` are the same ID, and there is no client secret.

`helm/`: `load_balancer_address`, `mcp_url`.

`flyte_config` is a minimal `~/.flyte/config.yaml` for the `flyte` CLI and SDK
(`terraform -chdir=azure/infra output -raw flyte_config`). Behind OAuth it sets `authType: Pkce` (see Exposure for
how that works). `kubeconfig_command` writes a kubeconfig for `kubectl`; it needs kubelogin too.

## Exposure

`exposure` has no default; choose one.

| | `tailscale` | `public` |
| --- | --- | --- |
| URL | `https://<tailscale.flyte_hostname>.<tailnet MagicDNS name>` | `https://<public.hostname>` |
| Needs | `enable_tailscale = true`, `tailscale.tailnet`, `tailscale.oauth_client_id`, `tailscale_oauth_client_secret` | `public.hostname`, `public.acme_email`, a DNS record |
| Front door | Tailscale Ingress to the Flyte Services | Traefik `LoadBalancer` (an Azure standard load balancer with a public IP), TLS from cert-manager (Let's Encrypt, HTTP-01) |
| OAuth | off; `enable_oauth = true` adds Traefik and oauth2-proxy | always on (`enable_oauth = false` is rejected) |

With OAuth on, requests pass Traefik's `strip-identity` middleware (removes any client-sent `X-Auth-Request-*`
headers) and then forward-auth to oauth2-proxy, which signs users in against **Microsoft Entra ID**. Flyte attributes
runs from `X-Auth-Request-User` / `X-Auth-Request-Email`; on the tailnet without OAuth, from `Tailscale-User-Login`.
`oauth` (`allowed_email_domains`, `allowed_emails`) must have at least one entry when OAuth is on.

**Identity provider.** One app registration, single tenant (`AzureADMyOrg`), in the tenant of the identity running
Terraform; the issuer is `https://login.microsoftonline.com/<tenant id>/v2.0` with the tenant read from
`data "azuread_client_config"`. Its web redirect is `<flyte url>/oauth2/callback` (oauth2-proxy);
its public-client platform has `http://localhost:53593/callback` for the CLI (PKCE, no secret).
`api.requested_access_token_version = 2` makes access tokens v2.0 tokens. oauth2-proxy has **no client secret**: it
redeems sign-ins with the token AKS projects into its pod (`--entra-id-federated-token-auth`), through Entra Workload
ID: the app registration has a federated credential for the service account `oauth2-proxy/oauth2-proxy` and the
cluster's OIDC issuer, the service account is annotated with the app's client ID and the pod carries the
`azure.workload.identity/use` label. There is nothing to rotate.

Users are identified by the `preferred_username` claim (`--oidc-email-claim`), not `email`: Entra puts `email` only
in tokens of users whose mail attribute is set, and oauth2-proxy refuses a session without an address, while
`preferred_username` (the sign-in name; for members, the UPN on one of your tenant's verified domains) is in every
v2.0 ID and access token requested with the `profile` scope. So `oauth.allowed_email_domains` / `allowed_emails`
match sign-in names, and that is what Flyte records as the user's email: list the UPN domain (for example
`<tenant>.onmicrosoft.com` in a tenant without a custom domain), and users by UPN where it differs from their mail
address. Anyone in the tenant can sign in to the application as far as Entra is concerned; who gets through is
decided by those allow lists in oauth2-proxy. To restrict it in Entra as well, set "Assignment required" on the
application's service principal in the portal and assign users. Guests sign in with their home account's name, so
they need `allowed_emails` (or their own domain in `allowed_email_domains`).

**oauth2-proxy provider.** `entra-id` (oauth2-proxy v7.10 and later, present in the v7.15.5 the 10.7.1 chart ships). It
is the `oidc` provider plus Entra specifics (issuer check against the `https://login.microsoftonline.com/<tenant>/v2.0`
template, group-overage handling), so the same OIDC arguments apply. `openid` is required and `profile` is what puts
`preferred_username` in the tokens; `email` is requested too.

How requests are routed with OAuth on (the pattern from the oauth2-proxy Traefik docs, "ForwardAuth with static
upstreams"): Traefik forward-auths to the oauth2-proxy **root**, which answers 202 for a signed-in session, redirects
a browser to Entra sign-in, and answers 401 (no redirect) for `/flyteidl2.*` and `/flyte-mcp` (`api-route`) and for
JSON clients. `/oauth2/auth`, the other option, only ever answers 202 or 401. `/` redirects to the console at `/v2`.

SDK and CLI access: `terraform -chdir=azure/infra output -raw flyte_config` sets `authType: Pkce`. The `flyte` client asks Flyte for its
auth metadata (`/flyteidl2.auth.AuthMetadataService/*` and `/.well-known/oauth-authorization-server`), which a separate
Ingress serves **without** forward-auth because the client has no token yet. Flyte answers from `runs.authMetadata`:
the Entra issuer (its OIDC discovery document) and the public client with redirect `http://localhost:53593/callback`,
the port the SDK listens on, and the scopes `openid email profile offline_access <client id>/.default`. The last one
asks Entra for an access token for this application itself (audience = its client ID, v2.0 issuer), which oauth2-proxy
verifies as a bearer token (`--skip-jwt-bearer-tokens`) without extra audience settings; `offline_access` asks for a
refresh token, so the SDK renews the access token without another browser sign-in. Bearer callers go through the
same allow lists as browser sessions: oauth2-proxy builds a session from the token's `preferred_username` and checks
it against `oauth.allowed_email_domains` / `allowed_emails`. This flow follows the SDK, server and
oauth2-proxy sources but has not been exercised against a live tenant; if it does not work in your setup, use
`authType: ExternalCommand` with a command that prints an access token (`az account get-access-token --scope
<client id>/.default`).

Sign out in the console goes through `/oauth2/sign_out` (`OIDC_LOGOUT_URL`). The Entra session is not ended.

**Tailscale without OAuth** (the default tailnet setup): tagged devices on the tailnet get no `Tailscale-User-*`
headers, so Flyte falls back to reading an unverified bearer JWT for `executed_by` when the client sends one. That is
attribution, not authorization; access control in this mode is your tailnet ACL.

In-cluster callers (task pods, the MCP server) call `http://flyte-http.flyte.svc.cluster.local:8090` with no
credentials: the cluster network is the trust boundary, so do not run untrusted workloads in this cluster.

## Storage and workload identity

`configuration.storage.provider` is `azure` with the storage account name and **no key**: the chart then configures
the storage client without credentials, and the workload identity webhook injects the federated token into pods that
carry the label `azure.workload.identity/use: "true"` and run as a service account annotated with
`azure.workload.identity/client-id`. The label is set on the Flyte backend pod (`deployment.podLabels`) and on every task
pod (`plugins.k8s.default-labels`); the task pods run as `flyte-task` (`executor.defaultK8sServiceAccount`).
Storage prefixes are `abfs://<container>/runs` and `abfs://<container>/runs/uploads`: `abfs://` is the scheme the Python
side (the SDK in task pods, which registers obstore's fsspec store for it) understands for Azure blobs and the one Flyte's Azure examples
use, and the short form without `@<account>.dfs.core.windows.net` works because the account comes from the storage
configuration (and from `AZURE_STORAGE_ACCOUNT_NAME`, which `values` sets in task pods through
`plugins.k8s.default-env-vars`; that list repeats the chart's own three entries because inline configuration replaces
the chart's list). This path follows the chart and SDK sources but has not been exercised against a live cluster.

## Add-ons

**Tailscale** (`enable_tailscale`): installs the operator and, in tailscale mode, the Ingress that publishes Flyte on
the tailnet. `tailscale.tailnet` is the MagicDNS name without its domain suffix (for example `tail1234`); the code appends it.

**MCP** (`enable_mcp`): runs the Flyte SDK's own `flyte-mcp` server (`flyte[mcp]==2.12.0`) in the `flyte-mcp`
namespace, read-only by default, reaching Flyte in-cluster without credentials. It is served on its own tailnet host
(`tailscale.mcp_hostname`) in tailscale mode, and on the Flyte host under `/flyte-mcp` when OAuth is on (behind the
same middlewares). The search tool group is left out because it clones git repositories at start-up. The pod installs
the SDK with `uv` when it starts: that avoids building an image, at the cost of a slower start and a dependency on
PyPI being reachable from the cluster (nodes have NAT egress). `mcp.image` can be replaced, but whatever image you use
must provide `uv` and Python 3.12. The default image is pinned by digest. The SDK's server binds `127.0.0.1` and has
no `--host` option, so the pod runs a small ConfigMap-mounted script (`files/mcp-serve.py`) that makes uvicorn default
to `0.0.0.0` and then calls the SDK's own entry point. With OAuth on there is no tailnet Ingress for MCP: it is
reachable only through the Traefik route on the Flyte host.

**GPU** (`gpu_node_pool.enabled`): the pool is tainted `nvidia.com/gpu=true:NoSchedule` and labelled `node-pool=gpu`
(the same key and value as on AWS); Flyte's resource tolerations match the taint. The NVIDIA device plugin is installed on
the GPU nodes only (selected by that label, tolerating the taint), so pods can request `nvidia.com/gpu`. AKS' GPU node
image ships the driver.

## Not covered, and why

- **Cluster autoscaler profile tuning**: the pools autoscale between zero and `max_nodes` with AKS defaults.
- **Automatic DNS**: the public hostname's record is yours (any DNS provider).
- **Backups beyond the flexible server's automated backups** (7 days).
- **Verifying the database certificate** (`sslmode=verify-full`): the connection is encrypted (`sslmode=require`) but
  the server certificate is not checked, because that needs the Azure CA bundle mounted into the Flyte pod, which the
  chart cannot do without extra volumes. The server has no public endpoint and resolves only inside the VNet.
- **Deletion protection**: the storage account, container, server and database have no `prevent_destroy` (a variable
  cannot toggle it, and it would block `terraform destroy` of a trial); add an Azure resource lock for production data.
- **Availability zones and high availability** for the database and the NAT public IP: not set, so the folder works in
  regions without zones.
- **Flyte's own authorization**: Flyte 2 attributes runs to the identity headers; it does not enforce per-user policy.

## Differences from the sibling repo

The sibling `terraform-union-dataplane/azure` deploys the Union dataplane on the same base, with the same two roots:
`infra/main.tf` and `helm/main.tf` are byte-identical. The only input of `infra/main.tf` that differs is
`local.product_subnets` (empty there, the Postgres subnet here).

### infra

Here and not there:

- `flyte.tf`, `exposure.tf`, `oauth.tf`: the Flyte product layer, and the exposure mode and Entra ID identity
  provider (CONVENTIONS sections 6 and 7).
- `tests/flyte.tftest.hcl`, `tests/exposure.tftest.hcl`, `tests/oauth.tftest.hcl`, `tests/tailscale.tftest.hcl`:
  their tests.
- Variables `database`, `enable_oauth`, `enable_tailscale`, `exposure`, `oauth`, `postgres_subnet_cidr`, `public`
  and `tailscale`: Flyte brings its own database, front door, identity and Tailscale add-on. The front-door settings
  live in this root, not the helm one, because the Entra redirect URIs need the URL and they are validated together.
- Outputs `database_host`, `database_name`, `database_password`, `database_username`, `flyte_config`, `flyte_url`,
  `oauth_callback_url`, `oauth_cli_client_id`, `oauth_cli_redirect_uri`, `oauth_client_id`, `oauth_enabled`,
  `oauth_issuer_url`, `service_accounts`, `tailnet_domain` and `task_client_id`, and the pass-throughs
  `enable_tailscale`, `exposure`, `oauth`, `public` and `tailscale`: what the Flyte helm root reads.
- Provider `hashicorp/azuread`: the Entra ID app registration for OAuth.

Same name, different meaning or default:

- `bucket_name`: here the blob container holding Flyte's data; there the dataplane's metadata container.
- `name`: defaults to `flyte` here and `union-dataplane` there (CONVENTIONS section 3), with the same validation.

`tests/base.tftest.hcl` tests the shared `main.tf` and is the same file in both repositories, apart from the mock
provider for `azuread`, which only this root uses.

### helm

Here and not there:

- `flyte.tf`, `exposure.tf`, `oauth.tf`, `tailscale.tf`, `mcp.tf`: the flyte-binary release, the front door,
  oauth2-proxy and the two add-ons.
- `templates/flyte-values.yaml.tmpl`: the `flyte-binary` values.
- `files/mcp-serve.py`: the MCP server's entry script.
- `tests/flyte.tftest.hcl`, `tests/exposure.tftest.hcl`, `tests/oauth.tftest.hcl`, `tests/tailscale.tftest.hcl`,
  `tests/mcp.tftest.hcl`: their tests.
- `tests/fixtures/public.json`, `tests/fixtures/tailscale.json`, `tests/fixtures/tailscale-oauth.json`: the infra
  outputs of each Flyte scenario.
- Variables `enable_mcp`, `mcp` and `tailscale_oauth_client_secret`: the MCP add-on, and the Tailscale secret (a
  secret lives in the root that uses it).
- Outputs `load_balancer_address` and `mcp_url`.
- Providers `hashicorp/random` (the cookie secret) and `hashicorp/time` (the destroy pause).

Same name, different meaning or default:

- None.

The sibling's own extras are listed in its README (`dataplane.tf`, the registry, Key Vault and worker identities,
the Union chart release, ...).
