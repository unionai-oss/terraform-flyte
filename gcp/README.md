# terraform-flyte: GCP (pending)

**Status: pending.** This folder has no Terraform yet, so nothing here has been validated. It is not yet applied live.

TODO: port the GCP OSS-Flyte stack from
[`flyte-gke/`](https://github.com/chrismatteson/agent-sandbox/tree/factory/flyte-gke/flyte-gke) (branch
`factory/flyte-gke`) once that project passes review. The port uses the same two roots as every other cloud
([CONVENTIONS.md](../CONVENTIONS.md) section 10), applied in order:

- `gcp/infra/`: the network, Cloud NAT and GKE cluster on `terraform-google-modules/network`,
  `terraform-google-modules/cloud-router` and `terraform-google-modules/kubernetes-engine` at the versions pinned in
  CONVENTIONS.md, with `infra/main.tf` the same text as
  [`terraform-union-dataplane/gcp/infra/main.tf`](https://github.com/unionai-oss/terraform-union-dataplane/tree/main/gcp/infra/main.tf),
  plus Flyte's buckets, database, Workload Identity and the exposure settings in `flyte.tf`, `exposure.tf` and
  `oauth.tf`. It outputs everything the helm root reads.
- `gcp/helm/`: the Flyte release, the front door and the add-ons (`flyte.tf`, `exposure.tf`, `oauth.tf`,
  `tailscale.tf`, `mcp.tf`). Its `main.tf` is the same text as `terraform-union-dataplane/gcp/helm/main.tf`: it reads
  the infra root through `data.terraform_remote_state.infra` (`infra_state`) and reaches the cluster with
  `gke-gcloud-auth-plugin`, with no google provider.

Examples go in `examples/gcp/infra/` and `examples/gcp/helm/`, with the same scenario names in both, and the file
names, variables and outputs match
[`terraform-union-dataplane/gcp`](https://github.com/unionai-oss/terraform-union-dataplane/tree/main/gcp).

## Differences from the sibling repo

Everything: the sibling repository's `gcp/` folder exists and this one is a placeholder until the port lands.
