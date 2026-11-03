# Flyte on AWS

Terraform that deploys open-source [Flyte 2](https://www.union.ai/docs/v2/flyte/) (`flyte-binary` chart) on Amazon
EKS: VPC and cluster, an S3 bucket, RDS for PostgreSQL, IRSA roles for Flyte's service accounts, and a front door
that is either a Tailscale tailnet or a public hostname behind OAuth. Optional add-ons: Tailscale access and the
Flyte MCP server.

Two root modules, applied in order: `infra/` creates everything through the AWS API, then `helm/` installs
everything through the Kubernetes API. `helm/` reads all it needs from the state of `infra/`; nothing is copied
between the two by hand.

Validated (fmt, validate, tflint, terraform test with mock providers) but not yet applied live.

## What it creates

`infra/`:

| File | Resources |
| --- | --- |
| `main.tf` | The base, identical to `terraform-union-dataplane/aws/infra`: VPC, EKS cluster with IRSA, system node group (3 non-burstable nodes), optional worker and GPU node groups, each created with `desired_size` nodes (default 1). |
| `flyte.tf` | S3 bucket (public access blocked, plain-HTTP requests denied); RDS PostgreSQL 17 in the private subnets (encrypted, not public, its own security group allowing 5432 only from the node security group); `random_password` for the database; IRSA roles for the Kubernetes service accounts `flyte/flyte-backend` and `flyte/flyte-task` with bucket-only S3 policies (the task role cannot delete objects). |
| `exposure.tf` | No resources: the exposure mode, whether OAuth is on, and the Flyte URL, which the Cognito clients need. |
| `oauth.tf` | When OAuth is on: Amazon Cognito user pool, domain, and two app clients (`proxy`: confidential, for oauth2-proxy; `cli`: public PKCE, for the `flyte` CLI and SDK). |

`helm/`:

| File | Resources |
| --- | --- |
| `main.tf` | The helm base, identical to `terraform-union-dataplane/aws/helm`: the remote state of `infra/`, the `kubernetes` and `helm` providers, and with `gpu_node_pool.enabled` the NVIDIA device plugin. |
| `flyte.tf` | The `flyte` namespace, the `flyte-task` service account, and the `flyte-binary` `v2.0.51` Helm release (values in `templates/flyte-values.yaml.tmpl`; the console image is pinned by tag and digest). |
| `exposure.tf` | The front door (below): Traefik, cert-manager (public only), the Flyte and discovery Ingresses, and the `load_balancer_address` lookup. In public mode a `time_sleep` that gives Traefik's load balancer time to disappear on destroy. |
| `oauth.tf` | When OAuth is on: a cookie secret and oauth2-proxy. |
| `tailscale.tf` | Add-on: Tailscale operator and the Ingress for the tailnet. |
| `mcp.tf` | Add-on: the Flyte MCP server. |

Base modules: `terraform-aws-modules/vpc/aws` `6.7.3` and `terraform-aws-modules/eks/aws` `21.29.0`. Everything else
is provider resources and Helm charts, pinned exactly: `flyte-binary` v2.0.51, `traefik` 42.2.0, `cert-manager`
v1.21.3, `oauth2-proxy` 10.7.1, `tailscale-operator` 1.104.2, `nvidia-device-plugin` 0.20.1. `helm/` uses the
`hashicorp/time` provider (`~> 0.13`) for the destroy pause.

## Prerequisites

- Terraform `>= 1.11.0, < 2.0.0`, and the **AWS CLI on `PATH`** for the helm apply: its Kubernetes and Helm
  providers fetch short-lived cluster tokens with `aws eks get-token`, so no cluster credential is stored.
- AWS credentials from the standard chain (`AWS_PROFILE`, `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` /
  `AWS_SESSION_TOKEN`, or `aws sso login`) with permission to create VPC, EKS, EC2, IAM, RDS, S3 and Cognito
  resources. Credentials are never Terraform variables. The identity that runs the infra apply becomes cluster admin;
  run the helm apply as that identity (or one you grant access).
- **A route to the EKS API endpoint for the helm apply** (the infra apply only talks to AWS APIs). The endpoint is
  private by default. Run the helm apply from a host inside (or routed to) the VPC, or set
  `cluster_endpoint_public_access = true` with `cluster_endpoint_public_access_cidrs` limited to your own address, or
  set `cluster_endpoint_private_access_cidrs` to the CIDRs of a network that is connected to the VPC (peering, VPN,
  Direct Connect) and run it from a host in those CIDRs: that opens 443 on the cluster security group to them (hosts
  inside the VPC need no rule). All three are `infra/` variables, and exist in the sibling repo as well.
- For `exposure = "tailscale"`: a tailnet with MagicDNS and HTTPS enabled, an ACL tag for the proxies (default
  `tag:k8s`) owned by `tag:k8s-operator`, and a Tailscale OAuth client with the `Devices: Core` and `Auth Keys`
  write scopes (see the operator docs). Pass its secret to the helm apply with `TF_VAR_tailscale_oauth_client_secret`.
- For `exposure = "public"`: a DNS name you control. After the helm apply, create a CNAME from it to the
  `load_balancer_address` output.

## Apply

```bash
terraform -chdir=aws/infra init && terraform -chdir=aws/infra apply -var-file=../../examples/aws/infra/tailscale.tfvars
terraform -chdir=aws/helm  init && terraform -chdir=aws/helm  apply -var-file=../../examples/aws/helm/tailscale.tfvars
```

Use the same scenario in both roots, edited for your values: `tailscale.tfvars` (tailnet only, no OAuth; the helm
one turns MCP on) or `public.tfvars` (public, OAuth for an allowed email domain; the helm one sets nothing). Every
choice about the deployment (exposure mode, OAuth, Tailscale, the GPU pool) is an `infra/` input, so a
misconfiguration fails the first plan, before anything is built. `helm/` takes only the MCP add-on, the Tailscale
client secret and `infra_state`.

## State and backends

Neither root has a `backend` block: where state lives is your choice.

1. **First run, nothing configured:** both roots use local state, and `helm/` reads `../infra/terraform.tfstate`
   (`infra_state` defaults to that).
2. **Remote state (recommended):** add a `backend.tf` to both roots, then tell `helm/` where the infra state is,
   once, in its tfvars, with the same settings as the infra backend block:
   ```hcl
   infra_state = { backend = "s3", config = { bucket = "example-tfstate", key = "flyte/aws/infra.tfstate", region = "us-east-2", use_lockfile = true } }
   ```
3. Both states are secrets. `infra/` holds the database password and the Cognito client secret; `helm/` holds them
   again (it reads them from `infra/` and passes them to Helm releases), plus the cookie secret and the Tailscale
   secret. Use backends with encryption at rest and restricted access, and give the helm runner read-only access to
   the infra state.

Terraform workspaces are not supported: `helm/` reads the infra root's default workspace.

## Destroy, in reverse

```bash
terraform -chdir=aws/helm  destroy -var-file=../../examples/aws/helm/tailscale.tfvars
terraform -chdir=aws/infra destroy -var-file=../../examples/aws/infra/tailscale.tfvars
```

`helm/` first: it removes Traefik's load balancer and then waits two minutes (`time_sleep.traefik_destroy`) for AWS to
delete it. Destroying `infra/` first orphans that load balancer and blocks the VPC delete; recovering takes
`terraform -chdir=aws/helm state rm` of everything, and deleting the load balancer by hand. The database has
deletion protection and a final snapshot by default; set `database.deletion_protection = false` and
`database.skip_final_snapshot = true` and apply `infra/` before destroying it.

## Inputs

`infra/`:

| Variable | Meaning |
| --- | --- |
| `region` | Required, no default. |
| `exposure` | Required: `tailscale` or `public`. |
| `name` | Prefix for resource names and the cluster name (default `flyte`). Lowercase letters, digits and single hyphens, starting with a letter, at most 29 characters (the EKS cluster IAM role prefix `<name>-cluster-` is capped at 38). |
| `database` | `{ allocated_storage = 20, instance_class = "db.t4g.small", multi_az = false, deletion_protection = true, skip_final_snapshot = false }`. |
| `system_node_pool`, `worker_node_pool`, `gpu_node_pool` | Node groups. The optional ones are off by default; enabled, each is created with `desired_size` nodes (default 1) and `min_size` (default 0) and `max_size` bound an autoscaler if you install one (`0 <= min_size <= desired_size <= max_size`). The EKS module ignores later changes to `desired_size`, so resize a running pool with the EKS console or CLI. |
| `cluster_endpoint_private_access_cidrs`, `cluster_endpoint_public_access`, `cluster_endpoint_public_access_cidrs` | See Prerequisites. |
| `vpc_cidr`, `private_subnet_cidrs`, `public_subnet_cidrs`, `single_nat_gateway`, `kubernetes_version`, `tags` | Base, same as the dataplane. |
| `public`, `oauth`, `enable_oauth` | Public mode and OAuth settings. |
| `enable_tailscale`, `tailscale` | Tailscale add-on (installed by `helm/`). |

`helm/`:

| Variable | Meaning |
| --- | --- |
| `infra_state` | Where the infra state is (State and backends). Default: `../infra/terraform.tfstate`. |
| `tailscale_oauth_client_secret` | Required when `infra/` has `enable_tailscale = true`; set it with `TF_VAR_tailscale_oauth_client_secret`. An input of this root, not of `infra/`, so it never reaches the infra state that this root reads in full. |
| `enable_mcp`, `mcp` | MCP add-on. |

## Outputs

`infra/`: `account_id`, `backend_role_arn`, `bucket_name`, `cluster_ca_certificate`, `cluster_endpoint`,
`cluster_name`, `database_host`, `database_name`, `database_password` (sensitive), `database_username`,
`enable_tailscale`, `exposure`, `flyte_config`, `flyte_url`, `gpu_node_pool`, `gpu_node_selector`, `kubeconfig_command`, `oauth`,
`oauth_callback_url`, `oauth_cli_client_id`, `oauth_cli_redirect_uri`, `oauth_client_id`, `oauth_client_secret`
(sensitive), `oauth_enabled`, `oauth_issuer_url`, `oidc_provider_arn`, `public`, `region`, `service_accounts`,
`tailnet_domain`, `tailscale`, `task_role_arn`. Most exist for `helm/`; `enable_tailscale`, `exposure`,
`gpu_node_pool`, `oauth`, `public` and `tailscale` pass the inputs of the same name through.

`helm/`: `load_balancer_address`, `mcp_url`.

`flyte_config` is a minimal `~/.flyte/config.yaml` for the `flyte` CLI and SDK
(`terraform -chdir=aws/infra output -raw flyte_config`). Behind OAuth it sets `authType: Pkce` (see Exposure for how
that works).

## Exposure

`exposure` has no default; choose one.

| | `tailscale` | `public` |
| --- | --- | --- |
| URL | `https://<tailscale.flyte_hostname>.<tailnet MagicDNS name>` | `https://<public.hostname>` |
| Needs | `enable_tailscale = true`, `tailscale.tailnet`, `tailscale.oauth_client_id`, and `tailscale_oauth_client_secret` for `helm/` | `public.hostname`, `public.acme_email`, a DNS record |
| Front door | Tailscale Ingress to the Flyte Services | Traefik `LoadBalancer` (an NLB), TLS from cert-manager (Let's Encrypt, HTTP-01) |
| OAuth | off; `enable_oauth = true` adds Traefik and oauth2-proxy | always on (`enable_oauth = false` is rejected) |

With OAuth on, requests pass Traefik's `strip-identity` middleware (removes any client-sent `X-Auth-Request-*`
headers) and then forward-auth to oauth2-proxy, which signs users in against **Amazon Cognito**. Flyte attributes
runs from `X-Auth-Request-User` / `X-Auth-Request-Email`; on the tailnet without OAuth, from `Tailscale-User-Login`.
`oauth` (`allowed_email_domains`, `allowed_emails`) must have at least one entry when OAuth is on.

Cognito users are created by an administrator. Create each allowed user with a verified address, for example:

```bash
aws cognito-idp admin-create-user --user-pool-id <pool id> --username alice@example.com \
  --user-attributes Name=email,Value=alice@example.com Name=email_verified,Value=true
```

(The pool id is the last part of the `oauth_issuer_url` output. oauth2-proxy rejects addresses Cognito has not
marked verified.)

How requests are routed with OAuth on (the pattern from the oauth2-proxy Traefik docs, "ForwardAuth with static
upstreams"): Traefik forward-auths to the oauth2-proxy **root**, which answers 202 for a signed-in session, redirects
a browser to Cognito sign-in, and answers 401 (no redirect) for `/flyteidl2.*` and `/flyte-mcp` (`api-route`) and for
JSON clients. `/oauth2/auth`, the other option, only ever answers 202 or 401. A request for the bare root `/` is
redirected to the console at `<flyte_url>/v2`. The target is the configured `https://` URL, not the request's own
scheme: Traefik rebuilds the URL it redirects from the connection it received, and behind the Tailscale Ingress that
connection is plain HTTP.

SDK and CLI access: `terraform -chdir=aws/infra output -raw flyte_config` sets `authType: Pkce`. The `flyte` client
asks Flyte for its auth metadata (`/flyteidl2.auth.AuthMetadataService/*` and `/.well-known/oauth-authorization-server`),
which a separate Ingress serves **without** forward-auth because the client has no token yet. Flyte answers from
`runs.authMetadata`: the Cognito issuer (its OIDC discovery document, as Cognito has no OAuth authorization-server
metadata) and the public `cli` app client with redirect `http://localhost:53593/callback`, the port the SDK listens
on. The client signs in through Cognito and sends the access token as a bearer; oauth2-proxy verifies it
(`--skip-jwt-bearer-tokens`), with `oidc-audience-claim=aud,client_id` and the `cli` client as
`oidc-extra-audience`, because Cognito access tokens carry `client_id` and no `aud`. Bearer callers are not checked
against `oauth.allowed_email_domains` / `allowed_emails` (an access token has no email): the Cognito user pool, where
only administrators create users, is their allow-list. This flow follows the SDK and server sources but has not been
exercised against a live cluster; if it does not work in your setup, use `authType: ExternalCommand` with a command
that prints a Cognito access token.

Sign out in the console goes through `/oauth2/sign_out` (`OIDC_LOGOUT_URL`). Cognito's own session is not ended.

**Tailscale without OAuth** (the default tailnet setup): `executed_by` can be spoofed. Requests from tagged
devices (servers, CI runners) carry no `Tailscale-User-Login` header, and Flyte then takes `executed_by` from the
bearer JWT the client sends without verifying it, so a tagged device can make its runs appear to be anyone's. Access
is still limited to what your tailnet ACL lets reach the Flyte host; only attribution is affected. When run
attribution matters, set `enable_oauth = true`: every caller then signs in through oauth2-proxy, and Flyte reads the
identity oauth2-proxy verified.

In-cluster callers (task pods, the MCP server) call `http://flyte-http.flyte.svc.cluster.local:8090` with no
credentials: the cluster network is the trust boundary, so do not run untrusted workloads in this cluster.

## Add-ons

**Tailscale** (`enable_tailscale` and `tailscale` in `infra/`, the client secret in `helm/`): `helm/` installs the
operator and, in tailscale mode, the Ingress that publishes Flyte on the tailnet. `tailscale.tailnet` is the MagicDNS
name without its domain suffix (for example `tail1234`); the code appends it.

**MCP** (`enable_mcp` and `mcp` in `helm/`): runs the Flyte SDK's own `flyte-mcp` server (`flyte[mcp]==2.12.0`) in
the `flyte-mcp` namespace, read-only by default, reaching Flyte in-cluster without credentials. It is served on its
own tailnet host (`tailscale.mcp_hostname`) in tailscale mode, and on the Flyte host under `/flyte-mcp` when OAuth is
on (behind the same middlewares). The search tool group is left out because it clones git repositories at start-up.
The pod installs the SDK with `uv` when it starts: that avoids building an image, at the cost of a slower start and
a dependency on PyPI being reachable from the cluster. `mcp.image` can be replaced, but whatever image you use must
provide `uv` and Python 3.12. The default image is pinned by digest. The SDK's server binds `127.0.0.1` and has no
`--host` option, so the pod runs a small ConfigMap-mounted script (`helm/files/mcp-serve.py`) that makes uvicorn
default to `0.0.0.0` and then calls the SDK's own entry point. With OAuth on there is no tailnet Ingress for MCP: it
is reachable only through the Traefik route on the Flyte host.

**GPU** (`gpu_node_pool.enabled` in `infra/`): `helm/` installs the NVIDIA device plugin on the GPU nodes only
(selected by the node label `node-pool=gpu`, tolerating the `nvidia.com/gpu` taint), so pods can request
`nvidia.com/gpu`.

## Not covered, and why

- **EBS CSI driver**: nothing here uses a PersistentVolumeClaim.
- **Cluster autoscaler / Karpenter**: install the one you prefer; managed node groups do not scale by themselves, so
  without one an enabled optional pool stays at its `desired_size`.
- **Automatic DNS**: the public hostname's record is yours (any DNS provider).
- **Backups beyond RDS automated backups** (7 days) and the final snapshot.
- **Verifying the RDS certificate** (`sslmode=verify-full`): the connection is encrypted (`sslmode=require`) but the
  server certificate is not checked, because that needs the RDS CA bundle mounted into the Flyte pod, which the chart
  cannot do without extra volumes. The database is private and reachable only from the node security group.
- **Flyte's own authorization**: Flyte 2 attributes runs to the identity headers; it does not enforce per-user policy.

## Differences from the sibling repo

The sibling `terraform-union-dataplane/aws` deploys the Union dataplane on the same base, with the same two roots:
`infra/main.tf` and `helm/main.tf` are byte-identical.

### infra

Here and not there:

- `flyte.tf`, `exposure.tf`, `oauth.tf`: the Flyte product layer, and the exposure mode and Cognito identity provider
  (CONVENTIONS sections 6 and 7).
- `tests/flyte.tftest.hcl`, `tests/storage_policies.tftest.hcl`, `tests/exposure.tftest.hcl`,
  `tests/oauth.tftest.hcl`, `tests/tailscale.tftest.hcl`: their tests.
- Variables `database`, `enable_oauth`, `enable_tailscale`, `exposure`, `oauth`, `public` and `tailscale`: Flyte
  brings its own database, front door, identity and Tailscale add-on. The front-door settings live in this root, not
  the helm one, because the Cognito callbacks need the URL and they are validated together.
- Outputs `backend_role_arn`, `database_host`, `database_name`, `database_password`, `database_username`,
  `flyte_config`, `flyte_url`, `oauth_callback_url`, `oauth_cli_client_id`, `oauth_cli_redirect_uri`,
  `oauth_client_id`, `oauth_client_secret`, `oauth_enabled`, `oauth_issuer_url`, `service_accounts`,
  `tailnet_domain` and `task_role_arn`, and the pass-throughs `enable_tailscale`, `exposure`, `oauth`, `public` and
  `tailscale`: what the Flyte helm root reads.

Same name, different meaning or default:

- `bucket_name`: here the bucket holding Flyte's data; there the dataplane's metadata bucket.
- `name`: defaults to `flyte` here and `union-dataplane` there (CONVENTIONS section 3).

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

The sibling's own extras are listed in its README.
