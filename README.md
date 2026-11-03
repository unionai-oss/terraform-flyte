# terraform-flyte

Terraform to deploy open-source [Flyte 2](https://github.com/flyteorg/flyte) on each cloud: the network and Kubernetes
cluster from the well-known upstream modules, then Flyte (the `flyte-binary` Helm chart) with object storage, a managed
Postgres and workload identity, behind a front door you choose:

- `exposure = "tailscale"`: reachable only from your tailnet, through the Tailscale Kubernetes operator. OAuth is
  optional (`enable_oauth`).
- `exposure = "public"`: a public hostname with a Let's Encrypt certificate, always behind oauth2-proxy with the
  cloud's identity provider (Amazon Cognito on AWS, Microsoft Entra ID on Azure, Google on GCP).

Optional add-ons, off by default: Tailscale access (`enable_tailscale`) and the Flyte MCP server (`enable_mcp`). Task
pods, apps and the MCP server call Flyte inside the cluster without credentials; the front door applies only to
traffic entering the cluster. [CONVENTIONS.md](CONVENTIONS.md) sections 6 and 7 describe the modes, identity headers
and trust boundary.

The sibling repository [terraform-union-dataplane](https://github.com/unionai-oss/terraform-union-dataplane) builds the
same base for a Union.ai dataplane; the two are maintained in lockstep ([AGENTS.md](AGENTS.md)).

## Coverage

| Cloud | Folder | Network and cluster | Status |
|---|---|---|---|
| AWS | [aws/](aws/) | terraform-aws-modules/vpc + eks | validated, not yet applied live |
| Azure | [azure/](azure/) | Azure Verified Modules: virtual network + NAT gateway + AKS managed cluster | validated, not yet applied live |
| GCP | [gcp/](gcp/) | terraform-google-modules/network + cloud-router + kubernetes-engine | pending ([flyte-gke](https://github.com/chrismatteson/agent-sandbox/tree/factory/flyte-gke/flyte-gke)) |

## Layout

Every cloud folder holds two root modules, applied in this order, and one README (see [CONVENTIONS.md](CONVENTIONS.md)
sections 1 and 10):

| Root | What | Files |
|---|---|---|
| `<cloud>/infra/` | Everything created through the cloud's API: network, cluster, node pools, storage, identities | `terraform.tf` (pins), `main.tf` (the network and cluster from the upstream modules, the same text as in the sibling repository for that cloud), `flyte.tf`, `exposure.tf`, `oauth.tf` (the product's cloud resources: storage, database, identities, the identity provider's clients), `variables.tf`, `outputs.tf`, `tests/` |
| `<cloud>/helm/` | Everything created through the Kubernetes API. It reads the infra root's outputs from its state; nothing is entered by hand between the two applies | `terraform.tf`, `main.tf` (the remote state, the Kubernetes and Helm providers and what every product needs in the cluster, the same text as in the sibling repository for that cloud), `flyte.tf`, `exposure.tf`, `oauth.tf`, `tailscale.tf`, `mcp.tf` (the Flyte release, the front door and the add-ons), `variables.tf`, `outputs.tf`, `tests/` |

`examples/<cloud>/infra/*.tfvars` and `examples/<cloud>/helm/*.tfvars` are example inputs, with the same scenario name
in both; `checks.sh` plans each of them against mock providers.

```sh
terraform -chdir=aws/infra init && terraform -chdir=aws/infra apply -var-file=../../examples/aws/infra/tailscale.tfvars
terraform -chdir=aws/helm init && terraform -chdir=aws/helm apply -var-file=../../examples/aws/helm/tailscale.tfvars
```

Edit the placeholders in the examples first. The tailscale example enables the Tailscale operator, so the helm apply
needs the OAuth client's secret in `TF_VAR_tailscale_oauth_client_secret`; it is kept out of the example files and of
the infra state (each cloud README, Prerequisites). Destroy in reverse: `helm` first, then `infra`.

Provider credentials come from each cloud's own CLI login or environment variables, never from Terraform variables;
each cloud README says which.

## Checks

`./checks.sh` checks each cloud folder's layout and README, then runs, for every root: `terraform fmt -check`,
`terraform init -backend=false`, `terraform validate`, `tflint` and `terraform test` (mock providers, no
credentials), and plans every example. For each `helm/` root it also checks the contract with `infra/`: it reads only
outputs the infra root has, keeps the infra root's sensitive outputs sensitive, and its test fixtures have exactly the
infra root's output names. Then it greps every file git lists in the repository (tracked, or untracked and not
ignored; without git, all but `.git/` and the names `.gitignore` lists for state, plans and credentials, a fixed list:
the file is not read) but `checks.sh` itself (the cloud folders, `examples/`, these top-level docs, the workflows and
the lock files) for hard-coded account, subscription and tenant IDs, Nebius project and tenant IDs, tailnet names,
secrets (also in YAML and shell snippets) and private domains under a country-code TLD or one of the generic TLDs
listed in `HYGIENE_TLD` in `checks.sh` (a domain under another TLD is not caught). A hit is reported as `file:line`
and its class; the matched text is never printed. It uses Terraform 1.16.6 and TFLint 0.65.0 and fetches them (checksum-verified)
if the ones on `PATH` differ. `CLOUDS="aws azure" ./checks.sh` checks some cloud folders only. CI runs the same
script (`.github/workflows/checks.yml`).

**Nothing in this repository has been applied to a real cloud account yet.** Every folder is validated statically and
with mock-provider plans only; account-dependent facts (quotas, instance types and Kubernetes versions offered in
your region, real network reachability) are not verified.
