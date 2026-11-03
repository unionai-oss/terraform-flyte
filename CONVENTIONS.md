# Conventions

This file is byte-identical in `unionai-oss/terraform-flyte` and `unionai-oss/terraform-union-dataplane`.
Change it in both repositories in the same change, or not at all. `AGENTS.md` holds the lockstep rules;
this file holds the conventions those rules refer to.

Where a convention here departs from HashiCorp's standard module structure, the departure and the reason are
stated next to it.

## 1. Layout

Each repository root holds:

| Path | What |
|---|---|
| `<cloud>/` | One folder per cloud (`aws/`, `azure/`, `gcp/`, ...) holding two root modules, `infra/` and `helm/`, applied in that order (section 10), and the cloud's README. A reader deploying on one cloud reads one folder. No module is shared between cloud folders, and neither repository consumes the other. |
| `examples/<cloud>/<root>/*.tfvars` | Example inputs for one root of that cloud folder, with the same scenario name in both roots (`examples/aws/infra/tailscale.tfvars`, then `examples/aws/helm/tailscale.tfvars`). Each one is planned against mock providers by `checks.sh`. |
| `AGENTS.md` | Lockstep rules for both repositories. |
| `CONVENTIONS.md` | This file. |
| `checks.sh` | Static checks for every root of every cloud folder. Byte-identical in both repositories. |
| `README.md` | What the repository deploys, and the coverage table (section 9). |
| `.github/workflows/checks.yml` | CI: runs `checks.sh`. |

Each cloud folder holds `README.md`, the only README for that cloud (section 9), and the two roots. Nothing else:
no Terraform at the cloud level, and no other subfolder.

**The boundary between the roots:**

- `infra/` is everything created through a cloud API: network, cluster, node pools, IAM and workload identities,
  storage, registry, database, identity-provider clients (Cognito, Entra ID). It never talks to the Kubernetes API,
  except where the cloud's cluster module itself needs it (GKE).
- `helm/` is everything created through the Kubernetes API: Helm releases and plain `kubernetes_*` objects
  (namespaces, Ingresses, Secrets, Deployments). It declares no cloud provider, and it learns everything about the
  cloud from the infra root's state (section 10).

A cloud may have no `helm/` where the product installs nothing into the cluster; `infra/` is always there.

Each root holds:

| File | `infra/` | `helm/` |
|---|---|---|
| `terraform.tf` | `terraform { required_version, required_providers }` and nothing else. | The same. |
| `main.tf` | Provider blocks for the cloud, shared locals, the random naming suffix, and the **base**: network and Kubernetes cluster built from the endorsed upstream modules (section 2). | The **helm base**: `data.terraform_remote_state.infra`, `local.infra`, the `kubernetes` and `helm` provider blocks, and what every product needs in the cluster (the NVIDIA device plugin for the GPU pool). |
| `<product>.tf` | The product's cloud resources: object storage, registry, database, workload identity, Helm values that only infra knows. `flyte.tf` in terraform-flyte, `dataplane.tf` in terraform-union-dataplane. | The product's Helm release and Kubernetes objects, under the same file name. |
| `exposure.tf`, `oauth.tf` | terraform-flyte only: the exposure locals and `flyte_url` (section 6); the identity provider's clients (section 7). | terraform-flyte only: Traefik, cert-manager and the Ingresses; oauth2-proxy. |
| `<addon>.tf` | - | One file per optional add-on (section 4), same file name in every cloud and both repositories where the add-on applies. |
| `variables.tf`, `outputs.tf` | Every `variable` / `output` block, alphabetical by name. | The same. |
| `tests/*.tftest.hcl` | `terraform test` files using mock providers (section 8). `tests/examples.tftest.hcl` plans the root's examples. | The same, plus `tests/fixtures/<scenario>.json`: the infra outputs the tests plan against. |
| `templates/*.tmpl`, `files/` | - | Templates, named after their destination plus `.tmpl` (for example `flyte-values.yaml.tmpl`), and files the releases read. |
| `.tflint.hcl`, `.terraform.lock.hcl`, `.gitignore` | Lint config with pinned plugins; the committed provider lock file. | The same. |

The same file name in both roots means "this root's part of that topic": `oauth.tf` is the Cognito clients in infra
and oauth2-proxy in helm. A reader finds things by topic first and by root second.

Departure from the four-file standard module structure (Terraform standard TF-001: every module uses `terraform.tf`,
`main.tf`, `variables.tf` and `outputs.tf`, with submodules as chapters): in each root, product, add-on, exposure and
OAuth code is split out of `main.tf` into the files above, in the same root module rather than in submodules. Every
cloud and both repositories use the same file names, so a reader finds the same thing in the same place; one 800-line
`main.tf` per root would hide the base, which is the part the two repositories share.

## 2. The base: endorsed upstream modules

Both repositories build the network and cluster in `infra/main.tf` from the same modules at the same exact versions,
and for a cloud both repositories support, `infra/main.tf` is the same text in both; product needs go in the
product file. `helm/main.tf`, the helm base, is likewise the same text in both repositories for a cloud. A module
`version` is always an exact version (`"21.29.0"`), never a range; `checks.sh` and TFLint's
`terraform_module_version` rule (`exact = true` in every `.tflint.hcl`) reject anything else.

| Cloud | Network | Cluster |
|---|---|---|
| AWS | `terraform-aws-modules/vpc/aws` `6.7.3` | `terraform-aws-modules/eks/aws` `21.29.0` |
| GCP | `terraform-google-modules/network/google` `18.3.1`, Cloud NAT from `terraform-google-modules/cloud-router/google` `9.1.0` | `terraform-google-modules/kubernetes-engine/google//modules/private-cluster` `47.0.0` |
| Azure | `Azure/avm-res-network-virtualnetwork/azurerm` `0.22.3`, NAT from `Azure/avm-res-network-natgateway/azurerm` `0.3.2` | `Azure/avm-res-containerservice-managedcluster/azurerm` `0.8.7` |
| OCI, CoreWeave, Crusoe, Nebius | provider resources directly | provider resources directly |

Clouds without an endorsed module use provider resources directly, and their README says so. No aws, gcp or
azure infra root declares a VPC/VNet, subnet, cluster or node-pool resource of its own; the product layer adds only
what the product needs on top (buckets, identities and databases in infra, Helm releases in helm).

Cluster defaults that both repositories share: private worker nodes behind NAT egress; a system node pool of
three non-burstable nodes; an optional worker pool and an optional GPU pool that may scale down to zero; workload
identity (IRSA, GKE Workload Identity, Entra Workload ID) for anything that reaches cloud APIs. Where nothing in the
cluster scales a pool by itself (AWS managed node groups: no autoscaler is installed), an enabled optional pool is
created with `desired_size` nodes (default 1) rather than zero, so it has capacity; `min_size` (default 0) and
`max_size` bound an autoscaler you install, and a validation enforces `0 <= min_size <= desired_size <= max_size`.

**The Kubernetes API is never open to any address by default; opening it takes `allow_public_api_endpoint = true`.**
Where the API endpoint is public, the CIDRs allowed to reach it are a required input (`master_authorized_networks` on
GCP, `api_server_authorized_ip_ranges` on Azure, `api_allowed_cidr` on OCI, `public_endpoint_allowed_cidrs` on
Nebius), and an empty list (or on OCI, unset or a `/0`) is rejected unless `allow_public_api_endpoint = true`. Where
the public endpoint takes no CIDRs (CoreWeave), it is off unless `allow_public_api_endpoint = true`. On AWS the
endpoint is private unless `cluster_endpoint_public_access = true`, which then requires its CIDRs. Crusoe's API endpoint is
always public and has no CIDR list (its `private` switch is unverified), so there `allow_public_api_endpoint = true`
is required: the open endpoint is an explicit choice, never a default. Elsewhere the tests
assert that the default is rejected or private, that the CIDRs reach the cluster, and that the opt-in opens it.

## 3. Naming

**Variables.** `snake_case`. Every variable has a `type` and a `description`; most are optional with a sensible
default. For a cloud both repositories support, equivalent inputs have the same name in both. The common ones:

| Name | Meaning |
|---|---|
| `name` | Prefix for every resource name. Default differs by product (`flyte`, `union-dataplane`). |
| `region` | Region (on Azure: the location). Required, no default: these repositories hard-code no region. |
| `project_id` | GCP only. Required, no default. |
| `tags` / `labels` | Extra tags (AWS, Azure) or labels (GCP, OCI, CoreWeave, Crusoe, Nebius), merged over the defaults (section 5). |
| `kubernetes_version` | Cluster version, explicit default. |
| `system_node_pool`, `worker_node_pool`, `gpu_node_pool` | One object per pool; attributes use the cloud's own terms (`instance_types`, `vm_size`, `machine_type`, ...). Optional pools carry `enabled`. |
| `enable_<addon>`, `<addon>` | An add-on toggle and its settings (section 4). |
| `infra_state` | helm only: where the infra root keeps its state, `{ backend, config }`, the same as that root's backend block. The default is the local state of `../infra` (section 10). |

Network inputs use the cloud's terms (`vpc_cidr` on AWS, `address_space` on Azure, ...), identical across the two
repositories for that cloud.

**Which root a variable is in.** A variable lives in `infra/` if an infra resource, local or validation uses it,
including a variable that is cross-validated with one infra uses; everything else lives in `helm/`. So the exposure
and add-on settings that decide `flyte_url` and that are validated together (`exposure`, `enable_oauth`, `public`,
`oauth`, `enable_tailscale`, `tailscale`) are infra variables, and a misconfiguration fails the first plan, before
anything is built. One exception: **a secret lives in the root that consumes it**, so it never reaches the infra state
that the helm root reads in full. Its "required when X" validation then reads X from `local.infra`. Each variable is in
exactly one root, under the same name in both repositories. The helm root has no `name`, `region` or `tags`: it creates
no cloud resources, and the region comes from the infra state.

**Secrets** are their own `sensitive = true` string variables, named `<owner>_<secret>`
(`tailscale_oauth_client_secret`), default `null`, required by a validation only when the thing that needs them is
on. Set them with `TF_VAR_<name>` from a secret store, never in a committed file. Anything Terraform passes to a
Helm release is written to state, so use a remote backend with encryption at rest and restricted access, for both
roots.

Provider credentials are never Terraform variables: each README names the provider's environment variables or
CLI login instead.

**Outputs.** `snake_case`, every output has a `description`, alphabetical. Shared names: `cluster_name`,
`cluster_endpoint`, `cluster_ca_certificate`, `kubeconfig_command` (the CLI command that writes a kubeconfig),
`region`, and `bucket_name` for the main object store bucket or container.

The infra root outputs every value the helm root reads, under one name. A setting both roots need is passed through
under the variable's own name (`exposure`, `tailscale`); a derived value gets a noun name (`flyte_url`,
`oauth_enabled`). An output that needs the cluster or a helm variable (`load_balancer_address`, `mcp_url`) is a helm
output.

**Remote state drops the sensitive mark.** An infra output marked `sensitive = true` comes back from
`terraform_remote_state` unmarked, so a helm output or argument that uses it plainly would show it in plan output. In
the helm root a sensitive infra output is only ever used as `sensitive(local.infra.<name>)` or as the `value` of a
`set_sensitive` entry; `checks.sh` enforces this (section 8).

**Resources.** Named with a noun that does not repeat the resource type (`aws_s3_bucket.metadata`, not
`aws_s3_bucket.metadata_bucket`); `this` when there is exactly one. Globally unique cloud names (buckets,
storage accounts, registries, Cognito domains) are `"${var.name}-${random_id.suffix.hex}"` (or the shortest legal
form of it), so two copies can run side by side.

## 4. Optional add-ons

An add-on is **off by default**, enabled by one boolean `enable_<addon>` and configured by one object variable
`<addon>` whose attributes are all `optional(...)` with defaults. Its resources live in `<addon>.tf` in the root that
holds them (`helm/` for both add-ons today), with the same file name in every cloud and both repositories where the
add-on applies. The toggle and the object live in the root that section 3's rule places them in: `enable_tailscale`
and `tailscale` in `infra/` (the tailnet decides `flyte_url` and is validated with `exposure`, and both are passed
through as outputs), `enable_mcp` and `mcp` in `helm/` (nothing in infra uses them).

```hcl
variable "enable_tailscale" {
  type        = bool
  description = "Install the Tailscale Kubernetes operator."
  default     = false
}

variable "tailscale" {
  type = object({
    flyte_hostname = optional(string, "flyte")
    ...
  })
  description = "Tailscale add-on settings. Used only when enable_tailscale is true."
  default     = {}
}
```

Add-on resources use `count = var.enable_<addon> ? 1 : 0`, or `count = local.infra.enable_<addon> ? 1 : 0` when
the toggle is an infra variable.

**Departure from TF-008 and TF-001.** The Terraform standard says (TF-008, SHOULD) not to use `count` as an on/off
switch in modules that are not general-purpose registry-style modules, but to copy and adapt the module instead, and
(TF-001) to structure code as the four standard files with submodules as chapters. Both repositories use
`count = <condition> ? 1 : 0` as an on/off switch inside each cloud's root module, for these kinds of condition:

- an add-on toggle: `var.enable_<addon>`, `local.infra.enable_<addon>`, `var.enable_key_vault`;
- the exposure mode and what follows from it (section 6): `local.public`, `local.oauth`, `local.traefik`, and in
  the helm root the infra outputs they become (`local.infra.public`, `local.infra.oauth_enabled`);
- an optional node pool's `enabled` attribute (section 3);
- an optional piece of the base or product layer chosen by an input: `var.separate_fast_registration_bucket`,
  a Log Analytics workspace created only when `var.log_analytics_workspace_id == null`, static credentials only
  when `var.static_credentials_user_ocid` is set.

The reason: one pair of root modules per cloud serves both exposure modes, every add-on and the optional pools, and
that one folder is what a reader deploying on that cloud reads (section 1). Copying the module per combination, as TF-008
suggests, would give each cloud several near-identical roots in each repository, and every file, variable, output
and pin in each copy would then have to be kept identical across both repositories by hand (AGENTS.md lockstep rules
1, 3 and 6). Moving the switched parts into submodules (TF-001's chapters) would only move the `count` onto the
module call and add an interface per piece. TF-009 still applies: each such `count` carries a `#` comment saying why
the resource is optional and what turns it on.

| Add-on | File | terraform-flyte | terraform-union-dataplane |
|---|---|---|---|
| Tailscale access (`enable_tailscale`, an infra variable) | `helm/tailscale.tf` | aws, azure (gcp when ported) | not applicable: the dataplane serves no endpoint of its own |
| Flyte MCP server (`enable_mcp`, a helm variable) | `helm/mcp.tf` | aws, azure (gcp when ported) | not applicable: Union hosts its own MCP |

Optional node pools are not add-ons: they are an `enabled` attribute of the pool's object.

## 5. Labels and tags

Every taggable resource gets:

```hcl
locals {
  tags = merge({ "managed-by" = "terraform", "stack" = var.name }, var.tags)
}
```

`labels` instead of `tags` where the cloud calls them labels (GCP, OCI, CoreWeave, Crusoe, Nebius); keys and
values are lowercase so they are legal on every cloud. On AWS the map is applied once through the provider's
`default_tags`; elsewhere it is passed to each resource or module.

## 6. Exposure modes (terraform-flyte)

```hcl
variable "exposure" {
  type        = string
  description = "How the Flyte endpoint is reached: tailscale (tailnet only) or public (internet, behind OAuth)."
  # No default: the two modes need different inputs, and choosing one is the first decision.
  validation {
    condition     = contains(["tailscale", "public"], var.exposure)
    ...
  }
}
```

| | `exposure = "tailscale"` | `exposure = "public"` |
|---|---|---|
| Reached at | `https://<tailscale.flyte_hostname>.<tailscale.tailnet>.ts.net` from the tailnet (`tailscale.tailnet` is the MagicDNS name without `.ts.net`) | `https://<public.hostname>` from the internet |
| Needs | `enable_tailscale = true` and the Tailscale OAuth client | `public.hostname`, a DNS record you point at the `load_balancer_address` output, `public.acme_email` |
| Front door | Tailscale operator Ingress (TLS from Tailscale) | Traefik `LoadBalancer` Service, TLS from cert-manager (Let's Encrypt, HTTP-01) |
| OAuth | off by default; `enable_oauth = true` puts oauth2-proxy in front | always on |
| Load balancer on the internet | none | one |

```hcl
variable "enable_oauth" {
  type        = bool
  description = "Put oauth2-proxy in front of Flyte. Null follows exposure: on for public, off for tailscale."
  default     = null
  # false together with exposure = "public" is rejected: a public endpoint is never unauthenticated.
}

locals {
  oauth = var.exposure == "public" || coalesce(var.enable_oauth, false)
}
```

`exposure` and `enable_oauth` are declared and validated in `infra/variables.tf` (variables live only there).
`infra/exposure.tf` holds the locals `public`, `oauth`, `tailnet_domain` and `flyte_url` (the identity provider's
callback URLs need it). The infra root passes them to the helm root as the
outputs `exposure`, `public`, `oauth_enabled` and `flyte_url`, and `helm/exposure.tf` builds the front door from them.

The routing, in each mode:

- tailscale, no OAuth: Tailscale Ingress → `flyte-http` Service.
- tailscale with OAuth: Tailscale Ingress → Traefik (ClusterIP) → forward-auth to oauth2-proxy → `flyte-http`.
- public: Traefik (LoadBalancer, TLS) → forward-auth to oauth2-proxy → `flyte-http`.

## 7. Identity (terraform-flyte)

**Identity provider per cloud**, always through [oauth2-proxy](https://oauth2-proxy.github.io/oauth2-proxy/) in
front of Flyte. Traefik `forwardAuth` goes to the oauth2-proxy **root**, with oauth2-proxy's only upstream set to
`static://202` (the "ForwardAuth with static upstreams" pattern in oauth2-proxy's Traefik docs): the root answers 202
for a signed-in session, redirects a browser to sign-in, and answers 401 to API routes (`--api-route`) and JSON
clients. `/oauth2/auth` is not used because it only ever answers 202 or 401, which leaves a browser at a bare 401.

| Cloud | IdP | Who creates the OAuth client |
|---|---|---|
| AWS | Amazon Cognito user pool, hosted domain and app client | Terraform (`infra/oauth.tf`) |
| Azure | Microsoft Entra ID app registration | Terraform (`infra/oauth.tf`, `azuread` provider) |
| GCP | Google | You (Google OAuth clients cannot be created by Terraform); pass `oauth_client_id` and `oauth_client_secret` |

`oauth = { allowed_email_domains = optional(list(string), []), allowed_emails = optional(list(string), []) }`
says who may sign in; at least one entry is required when OAuth is on, so turning it on never admits every
account an IdP knows. oauth2-proxy itself is `helm/oauth.tf`, configured from the infra outputs. The cookie secret
is a `random_password` in the helm root. oauth2-proxy also accepts IdP-issued bearer JWTs
(`--skip-jwt-bearer-tokens`) so SDK and CLI clients can authenticate without a browser cookie.

**Flyte v2 identity headers.** Flyte attributes runs (`executed_by`) from headers the front door sets, configured in
the `flyte-binary` values at `flyte-core-components.runs.identityHeaders`:

| Front door | `subjectHeader` | `emailHeader` | `claimsJwtHeader` |
|---|---|---|---|
| Tailscale Ingress, no OAuth | `Tailscale-User-Login` | `Tailscale-User-Login` | `""` |
| oauth2-proxy (either mode) | `X-Auth-Request-User` | `X-Auth-Request-Email` | `""` |

Behind oauth2-proxy, Traefik first strips any client-sent `X-Auth-Request-*` headers, then copies them from the
oauth2-proxy response (`authResponseHeaders`), so a client cannot assert an identity itself.

**Without OAuth on the tailnet, attribution can be spoofed.** Tailscale sets `Tailscale-User-Login` only for requests
from user-owned devices. Tagged devices (servers, CI runners) send none, and Flyte then takes `executed_by` from the
bearer JWT the client sends, without verifying it, so a tagged device can make its runs appear to be anyone's. Access
is still limited to the tailnet and its ACL; only attribution is affected. Set `enable_oauth = true` when run
attribution matters: oauth2-proxy then verifies every caller.

**The bare-root redirect.** With Traefik in front, `/` redirects to the console at `/v2` through a `redirectRegex`
middleware matching only the bare root, `^https?://[^/]+/?$`, whose `replacement` is the configured `https://` URL
plus `/v2` (`"${local.infra.flyte_url}/v2"`), never a capture of the request's scheme and host such as `${1}/v2`. Traefik
rebuilds the URL it matches with the scheme taken from the connection it received (`req.TLS`), and behind the
Tailscale Ingress that connection is plain HTTP, so a captured scheme would send browsers to `http://`.

**In-cluster callers stay unauthenticated.** Task pods, apps, the MCP server and agents running in the cluster
call Flyte at the in-cluster Service (`http://flyte-http.flyte.svc.cluster.local:8090`) with no credentials and no
identity headers; the front door and its OAuth apply only to traffic entering the cluster. The cluster network is
the trust boundary, so do not run untrusted workloads in it.

## 8. Version pins and tests

**Pins.** Every root of every cloud folder in both repositories declares:

```hcl
terraform {
  required_version = ">= 1.11.0, < 2.0.0"
}
```

`checks.sh` runs Terraform `1.16.6` and TFLint `0.65.0` (it downloads and checksum-verifies them when the ones on
`PATH` are different). Providers are pinned with `~> MAJOR.MINOR` in `required_providers`, never inside a
`provider` block, and the resolved versions are fixed by the committed `.terraform.lock.hcl` (with hashes for
`linux_amd64`, `darwin_amd64` and `darwin_arm64`). The same provider has the same constraint in every folder that
uses it, in either root and both repositories:

| Provider | Constraint |
|---|---|
| `hashicorp/aws` | `~> 6.59` |
| `hashicorp/google`, `hashicorp/google-beta` | `~> 8.0` |
| `hashicorp/azurerm` | `~> 5.0` |
| `azure/azapi` | `~> 2.12` |
| `hashicorp/azuread` | `~> 3.0` |
| `hashicorp/kubernetes` | `~> 3.0` |
| `hashicorp/helm` | `~> 3.0` |
| `hashicorp/random` | `~> 3.7` |
| `hashicorp/time` | `~> 0.13` |
| `azure/modtm` | `~> 0.4` (declared only because the AVM modules require it; their telemetry is turned off) |
| `oracle/oci` | `~> 9.11` |
| `coreweave/coreweave` | `~> 0.26` |
| `crusoecloud/crusoe` | `~> 1.8` |
| `nebius/nebius` | `~> 0.6` |

Helm charts and container images are pinned to exact versions in the product file; images that the folders
reference directly are pinned by digest.

**Tests.** Each root has `tests/*.tftest.hcl` files that run `command = plan` against `mock_provider` blocks (no
credentials, nothing created). They assert, at least: names derive from `name` and the suffix; tags or labels are
applied; each validation rejects a bad value (`expect_failures`); each add-on's resources are absent by default and
present when enabled; the product's key wiring (Helm values, identity headers, workload identity); and that the
base's inputs reach the upstream modules, in a test file that plans the real modules instead of overriding them
(`infra/tests/base_modules.tftest.hcl` on AWS, byte-identical in both repositories). `tests/examples.tftest.hcl` has
no variables of its own: `checks.sh` plans its `run` blocks once per `examples/<cloud>/<root>/*.tfvars`, with the
example's values as each run's variables, in the same `terraform test` as the root's other test files (one process
per root: each process loads every provider again).

**The helm root's tests plan against fixtures of the infra outputs.** `helm/tests/fixtures/<scenario>.json` is one
JSON object per infra scenario whose keys are exactly the infra root's output names (placeholder values contain
`example`). Each test file feeds it to the remote state with a file-level `override_data` on
`data.terraform_remote_state.infra` (`values = { outputs = { for k, v in jsondecode(file("tests/fixtures/<scenario>.json")) : k => v if v != null } }`),
and a `run` changes a few values with `merge()`. A fixture rather than a plan of the infra root, because an override
cannot refer to another run's outputs; `override_data` rather than `mock_provider "terraform"`, because it targets
exactly one object. The helm `tests/examples.tftest.hcl` plans each example against every fixture, one `run` each.

Two guards keep the fixtures honest, one on each side:

- **Names, in `checks.sh`:** every `local.infra.<name>` in `helm/*.tf` is an output of `infra/outputs.tf`, and every
  fixture's keys equal the infra output names exactly.
- **Values, in `infra/tests/contract.tftest.hcl`:** one `run` per fixture plans the infra root with that scenario's
  variables, overriding the modules and resources whose outputs are unknown at plan with values from the same
  fixture, and asserts `jsonencode(output.<name>) == jsonencode(jsondecode(file("../helm/tests/fixtures/<scenario>.json")).<name>)`
  for every output known at plan: the pass-throughs, `flyte_url`, `oauth_enabled`, `service_accounts`,
  `tailnet_domain`, the names. `jsonencode` on both sides, because `==` fails between a list and a tuple.

What remains unchecked: outputs that are unknown at plan (endpoints, ARNs, the cluster CA) are checked by name only,
which is as far as tests with mock providers can go.

**Checks.** `checks.sh` (byte-identical in both repositories) checks, for every cloud folder, that there is no
Terraform at the cloud level, no subfolder other than `infra/` and `helm/`, an `infra/` root, no example outside
`examples/<cloud>/<root>/`, and a README that says whether it has been applied live and has a "Differences from the
sibling repo" section; a folder with no root and a README saying `pending` is reported as pending. Then, for every
root, as its own concurrent job: `terraform fmt -check`, `terraform init -backend=false -lockfile=readonly`,
`terraform validate`, `tflint --init && tflint`, `terraform test`, and the examples. It checks that variables and
outputs are alphabetical, that `required_version` is the one above, that `region` and `project_id` have no default,
and that every registry module `version` is an exact `X.Y.Z`. For a helm root it also checks the contract with the
infra root: `data.terraform_remote_state.infra` is declared and read exactly once, in `main.tf`; every
`local.infra.<name>` is an infra output; a sensitive infra output is only used inside `sensitive()` or as a
`set_sensitive` value; there is at least one fixture, and each fixture's keys equal the infra output names. Then it
greps every file git lists in the repository (tracked, or untracked and not ignored; without git, every file but
`.git/` and the names `.gitignore` lists for state, plans and credentials, a fixed list: the file is not read) but
`checks.sh` itself (Terraform, templates, `files/`, fixtures, READMEs, the top-level docs, workflows, lock files) for hard-coded account, subscription, tenant and GCP project IDs (the key
may be `project` or `project_id`), OCI OCIDs, Nebius project and tenant IDs, tailnet names (with or without `.ts.net`),
domains under a country-code TLD or one of the generic TLDs listed in `HYGIENE_TLD` in `checks.sh` (a domain under
another TLD, or under `.tf`/`.py`/`.sh`/`.md`/`.pb`/`.id`, is not caught; the vendor hosts it lists by name pass),
keys and secrets (`*_secret`, `clientSecret`, `api_key`, `aws_secret_access_key`, AWS access key IDs, GitHub and
Tailscale tokens, private keys; a quoted value after `=` or `:` in HCL, YAML, JSON or a shell snippet, or an unquoted
value at the start of a line as YAML `key: value` or shell `KEY=value`/`export KEY=value`), provisioners and
`external` data sources. Deliberate placeholders pass: a value containing `example` (`example-project`,
`ocid1.tenancy.oc1..example`, `project-e00example`, `flyte.example.com`), the tailnet `tail1234`, and the test
fixtures' `test-project`, `project-e00test` and `tenant-e00test`. Use a value containing `example` for a new
placeholder. A hit is reported as `file:line` and its class; the matched text is never printed.
`CLOUDS="aws azure" ./checks.sh` limits the cloud and root steps to some cloud folders. Nothing in it applies or
needs cloud credentials.

## 9. READMEs and coverage

The repository `README.md` has a coverage table in exactly this format, one row per cloud folder:

```markdown
| Cloud | Folder | Network and cluster | Status |
|---|---|---|---|
| AWS | [aws/](aws/) | terraform-aws-modules/vpc + eks | validated, not yet applied live |
```

Status is exactly one of:

| Status | Folder |
|---|---|
| `validated, not yet applied live` | has Terraform |
| `applied live on YYYY-MM-DD` | has Terraform |
| `pending ([what it waits on](link) ...)`: `pending` and a parenthesis holding a Markdown link | a placeholder `README.md`, no Terraform yet |

aws, azure and gcp are covered by both repositories (`AGENTS.md`), so each has a folder and a row in both, even while
one side is pending. A cloud has Terraform when it has `infra/terraform.tf`.

Each cloud folder has one `README.md`, for both roots. It says plainly whether it has been applied live, lists its
base modules (or says it uses provider resources directly), and has these sections, in this order:

1. An introduction and the validation status.
2. What it creates: one table per root.
3. Prerequisites. A route to the cluster API is needed for the helm apply only (and for an infra root whose cluster
   module talks to the Kubernetes API).
4. **Apply:** two numbered commands, infra then helm, each with its example:
   `terraform -chdir=aws/infra init && terraform -chdir=aws/infra apply -var-file=../../examples/aws/infra/tailscale.tfvars`,
   then the same for `aws/helm`. A manual step the product needs between the two (the Union auth Secret) goes between
   them.
5. State and backends (section 10).
6. **Destroy,** in reverse: helm first, then infra (section 10).
7. Inputs per root.
8. Outputs per root.
9. Add-ons.
10. Not covered.
11. **Differences from the sibling repo**, last.

For a cloud both repositories have Terraform for, the Differences section has a `### infra` and a `### helm`
subsection, and each holds two bullet lists, each after a paragraph ending with its heading line:

- `Here and not there:` names, in backticks, every file, variable, output, provider (by source, `hashicorp/helm`)
  and module (`module.<name>`) in this root that the sibling repository's same root for the same cloud does not
  have, with the reason. A root only this repository has is listed as `helm/` in its own subsection. A name both
  roots have does not belong here.
- `Same name, different meaning or default:` one bullet per name both roots have that means something different
  or whose variable `type` or `default` differs, the name in backticks first, then the difference and why.

## 10. Two applies

Each cloud is deployed with two applies, `infra/` and then `helm/`:

```bash
terraform -chdir=aws/infra init && terraform -chdir=aws/infra apply -var-file=../../examples/aws/infra/<scenario>.tfvars
terraform -chdir=aws/helm  init && terraform -chdir=aws/helm  apply -var-file=../../examples/aws/helm/<scenario>.tfvars
```

**Why two.** The `kubernetes` and `helm` providers are configured from the cluster's endpoint and CA. In one root,
those are unknown until the cluster exists, so a first apply, or any change that replaces the cluster, plans the
Kubernetes resources against a provider that is not configured yet and fails or misbehaves part-way. With two roots
the cluster and its API exist before anything plans against them, and each apply either succeeds or fails on its own
inputs. Node pools that the cloud's API creates are in `infra/`, so they exist too; where node pools are Kubernetes
objects themselves (CoreWeave's CKS `NodePool` custom resource, which the provider has no resource for), they are in
`helm/`, which creates them and waits for their nodes before installing anything that needs them. There is no wrapper script between the applies and nothing to copy between them by hand.

**The remote-state contract.** The helm root reads everything it knows about the cloud from the infra root's
outputs, in `helm/main.tf`:

```hcl
data "terraform_remote_state" "infra" {
  backend = var.infra_state.backend
  config  = var.infra_state.config == null ? { path = "../infra/terraform.tfstate" } : var.infra_state.config
}

locals {
  infra = data.terraform_remote_state.infra.outputs
}
```

Everything else in the helm root reads `local.infra.<name>`, and only names that are infra outputs (section 8). There
is no `defaults` argument: a helm plan before the infra apply fails with "No stored state was found", rather than
planning an empty deployment. Neither root commits a `backend` block; the choice is the operator's. With none, both
roots use local state and the default `infra_state` reads `../infra/terraform.tfstate`. With a remote backend, add
it to both roots and give the helm root the infra root's settings once, in `infra_state` (the same backend type and
settings as the infra backend block). That says where the state lives, like the backend block; it is not data copied
between the applies. The helm root's runner needs read access to the infra state, which holds secrets such as the
database password: give it read-only access, and encrypt both states at rest. Workspaces other than `default` are
not supported.

**A null output is absent, not null.** Terraform stores no root output whose value is null, so in the helm root an
infra output that is null in some configuration (an OAuth client ID with OAuth off, an optional access key) does not
exist, and `local.infra.<name>` fails with "Unsupported attribute". The helm root reads such an output only behind a
`count` or conditional that is false in exactly that case, or through `try(local.infra.<name>, null)`. The tests
behave like state: every `override_data` on `data.terraform_remote_state.infra` drops the fixture's nulls
(`outputs = { for k, v in <fixture> : k => v if v != null }`), and checks.sh fails one that does not.

**No cloud provider in the helm root.** Its `kubernetes` and `helm` providers authenticate with an `exec` plugin
that runs the cloud's CLI (`aws eks get-token`, `kubelogin get-token`, `gke-gcloud-auth-plugin`, ...), the same login
the infra root's provider uses. No token is written to plan or state, and none expires during a long Helm wait. Where
the cloud has no such command (CoreWeave, Crusoe), the providers read the kubeconfig at `KUBE_CONFIG_PATH`: a
credential, like `AWS_PROFILE`, not data passed between the applies.

**Destroy in reverse:** `terraform -chdir=<cloud>/helm destroy`, then `terraform -chdir=<cloud>/infra destroy`. The
helm destroy removes the Services that own cloud load balancers; destroying infra first orphans those load
balancers, blocks the network's deletion, and leaves a helm state that only `terraform state rm` clears.

**Readiness waits live in the root whose resources they wait on**, so a returned apply or destroy means the next
one can start. The wait for a new cluster's access to propagate (`time_sleep.cluster_access` on Azure) is in
`infra/main.tf`: an infra apply returns once the cluster is usable. The pause after the front door's load balancer is
deleted (`time_sleep.traefik_destroy`) is in `helm/exposure.tf`: a helm destroy returns once the cloud has removed
it, and the infra destroy can then delete the network.

