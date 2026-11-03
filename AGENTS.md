# AGENTS.md

Instructions for AI coding agents (and humans) working in this repository.

## This repo and its sibling

- **This repo:** `unionai-oss/terraform-flyte`: Terraform to deploy open-source Flyte 2 on each cloud, with optional add-ons (Tailscale access, Flyte MCP gateway).
- **Sibling:** [`unionai-oss/terraform-union-dataplane`](https://github.com/unionai-oss/terraform-union-dataplane)

The two repos are maintained **in lockstep**. A reader who knows one should find the other
familiar: same layout, same file structure, same naming, same conventions, as if written by one
author from one point of view. Only the infrastructure each deploys differs.

## Lockstep rules

1. **Same top-level layout.** One standalone folder per cloud at the repo root (`aws/`, `gcp/`,
   `azure/`, and any other cloud both support, e.g. `coreweave/`, `crusoe/`, `nebius/`), plus
   `CONVENTIONS.md`, `checks.sh`, `examples/` and `README.md`. A cloud folder holds the two root
   modules `infra/` and `helm/`, applied in that order, and one README: someone deploying on one
   cloud reads one folder. No cross-cloud abstraction layer.
2. **`CONVENTIONS.md` is byte-identical in both repos.** It is the single source of truth for file
   layout, variable/output naming, optional add-on toggles, labels/tags, version pinning and tests.
   Change it in both repos in the same change, or not at all.
3. **Same cloud, same shape.** For a given cloud, both repos use the same file names, the same names
   for equivalent variables and outputs (`project_id`, `region`, `name`, `labels`/`tags`,
   cluster and bucket outputs, ...), the same provider and Terraform version pins, and the same
   network/cluster defaults unless the product genuinely needs something different.
4. **Optional add-ons look the same everywhere.** An add-on (e.g. Tailscale access, the Flyte MCP
   gateway) is off by default, enabled by a single `enable_<addon>` boolean plus an `<addon>`
   object variable, and lives in `<addon>.tf` (or a submodule) in the root that holds its
   resources, with the same name in every cloud and both repos where it applies.
5. **Same checks.** `checks.sh` runs the same steps in both repos for every root of every cloud
   folder (`terraform fmt -check`, `init -backend=false`, `validate`, `tflint`, `terraform test`,
   and for `helm/` the contract with `infra/`). CI mirrors it.
6. **Paired changes.** Any change to a convention, a shared variable/output name, a pin, an add-on
   interface or a cloud folder's or root's structure must land in **both** repos (paired PRs that link each
   other). If a change only makes sense for one product, say why in the PR and in that cloud's
   README.
7. **Coverage tables match.** Each `README.md` lists the clouds covered with a per-cloud status
   table in the same format.

8. **Consume the well-known upstream modules for the base, don't hand-roll primitives.** Per cloud,
   both repos build the network and Kubernetes cluster from the same endorsed modules at the same
   pinned versions, in `infra/main.tf`: AWS `terraform-aws-modules/vpc` + `terraform-aws-modules/eks`; GCP
   `terraform-google-modules/network` + `terraform-google-modules/kubernetes-engine`; Azure the Azure
   Verified Modules (AKS managed cluster + network). Only clouds without such modules (e.g. CoreWeave,
   Crusoe, Nebius) use provider resources directly, and their README says so. Neither repo consumes
   the other; each adds only its product layer on top of the shared base.

## Always

- Pin `required_version` and every provider. Every variable has a type and description; every
  output has a description; variables and outputs are alphabetical.
- No hard-coded account/project IDs, regions, tailnet names, domains or secrets. These repos are
  public.
- Prefer the smallest set of resources on top of the shared base that meets the documented requirement; justify any helper
  script in the README (why Terraform/Helm cannot do it).
- Before finishing, diff your change against the sibling repo's equivalent root and fix any
  unintended divergence.
