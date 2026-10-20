# Workload Identity Federation migration plan

> Traditional Chinese translation: [`wif_migration_zh.md`](wif_migration_zh.md)
> (AI-translated from this version; the English doc is authoritative).

## Status

**Draft — not yet executed.** This doc captures the design, concrete
migration steps, verification recipe, and rollback strategy so the work
can be picked up in a single focused session when prioritised.

Last reviewed: 2026-05-11.

## Why this matters

The two GitHub Actions service accounts (`gha-ci` and `gha-cd`) currently
authenticate via long-lived JSON keys stored in GHA repo secrets
(`GCP_SA_KEY_CI`, `GCP_SA_KEY_CD`). Three concrete problems:

1. **No automatic rotation.** A leaked key remains valid until manually
   rotated. Realistically this means "until someone notices".
2. **No conditional access.** A leaked key can be used from any IP, any
   workflow, any repo. GCP IAM can't distinguish "this is a CD run from
   our `main` branch" from "this is an attacker holding the key".
3. **Audit trail loses the workflow context.** Every Cloud Audit log
   entry shows the SA as the principal; reconstructing which GHA
   workflow run actually triggered the action requires correlating
   timestamps. Painful during incidents.

Workload Identity Federation (WIF) replaces the static keys with a
short-lived OIDC token issued by GitHub for each workflow run, exchanged
for an equally short-lived GCP access token. Properties:

- No long-lived credential anywhere — nothing to rotate, nothing to leak
- Conditional access via attribute mappings (repo, branch, workflow,
  actor)
- Audit logs carry the workflow run identity in the impersonation chain

## Current state

| Component | Auth today | Auth after WIF |
|---|---|---|
| `dbt_ci.yml` (PR validation) | `secrets.GCP_SA_KEY_CI` → `gha-ci@…` | OIDC token → WIF provider → `gha-ci@…` |
| `dbt_cd.yml` (image push + Job rollout) | `secrets.GCP_SA_KEY_CD` → `gha-cd@…` | OIDC token → WIF provider → `gha-cd@…` |
| `bq_cd.yml` (bronze image + Job rollout) | `secrets.GCP_SA_KEY_CD` → `gha-cd@…` | OIDC token → WIF provider → `gha-cd@…` |
| `build_dbt_docs.yml` (docs publish) | none required (just GitHub Pages) | unchanged |

Two GHA secrets are in scope: `GCP_SA_KEY_CI`, `GCP_SA_KEY_CD`. The two
corresponding JSON keys live in GCP under each SA's keys collection.

## Design

### Auth flow before / after

```
BEFORE (SA key):
   GHA workflow ─secret─► JSON key  ──► GCP IAM (key-based auth)
                                          │
                                          ▼
                                       gha-cd SA   ── runs gcloud commands

AFTER (WIF):
   GHA workflow ──OIDC JWT──► WIF pool / provider ──maps to──► principalSet
                                                                  │
                                  ┌───────────────────────────────┘
                                  │ IAM binding grants workloadIdentityUser
                                  ▼
                               gha-cd SA  (impersonated via STS token, ~1h TTL)
                                  │
                                  ▼
                              gcloud commands
```

The OIDC JWT is signed by `token.actions.githubusercontent.com`. Every
workflow run gets a fresh JWT containing claims like `repository`,
`repository_owner`, `ref`, `workflow`, `actor`, `job_workflow_ref`.

### Attribute mapping

JWT claims → GCP attributes. The mapping below covers the standard ones
plus a composite `attribute.repository_ref` used for branch-scoped
trust:

| GCP attribute | Source claim |
|---|---|
| `google.subject` | `assertion.sub` |
| `attribute.repository` | `assertion.repository` |
| `attribute.repository_owner` | `assertion.repository_owner` |
| `attribute.ref` | `assertion.ref` |
| `attribute.workflow` | `assertion.workflow` |
| `attribute.actor` | `assertion.actor` |
| `attribute.repository_ref` | `assertion.repository + ":" + assertion.ref` |

### Provider-level attribute condition

GCP refuses to create a GitHub OIDC provider without an
`attribute_condition` (since a 2023 security policy change). Without
one, *any* public workflow on GitHub.com could attempt to impersonate
our SAs and the IAM bindings would be the only line of defence.

Provider condition restricts trust at the provider level:

```
assertion.repository_owner == "davidho27941"
```

This rejects any incoming OIDC token not coming from `davidho27941`'s
repos before IAM is even consulted.

### Principal sets per SA

Different scopes for different blast radius:

- **`gha-ci`** — PR validation. Must accept any branch / any PR from this
  repo. Principal set:
  ```
  principalSet://iam.googleapis.com/projects/<PROJECT_NUMBER>/locations/global/
    workloadIdentityPools/github-actions/attribute.repository/davidho27941/Weather_data_dbt
  ```

- **`gha-cd`** — deploys to live infra. Must be **restricted to `main`**
  to prevent a feature branch from deploying itself. Principal set
  uses the composite attribute:
  ```
  principalSet://iam.googleapis.com/projects/<PROJECT_NUMBER>/locations/global/
    workloadIdentityPools/github-actions/attribute.repository_ref/
    davidho27941/Weather_data_dbt:refs/heads/main
  ```

The branch-scoping via principal set (instead of IAM Condition on the
binding) is cleaner because the trust is named in the binding member
itself — `terraform plan` diff makes it obvious which branch can
deploy. IAM Conditions are valid but obscure the scope in a separate
expression.

## Migration steps

Steps 1 → 3 add WIF *in parallel* with the existing keys. Step 4
decommissions the keys after WIF is proven. Don't combine 1-2 with 4 —
the parallel period is the rollback window.

### Step 1: Provision WIF in Terraform

New file `terraform/wif.tf`:

```hcl
resource "google_iam_workload_identity_pool" "github_actions" {
  project                   = var.project
  workload_identity_pool_id = "github-actions"
  display_name              = "GitHub Actions"
  description               = "Federated identity pool for GHA workflows from davidho27941/* repos."
}

resource "google_iam_workload_identity_pool_provider" "github" {
  project                            = var.project
  workload_identity_pool_id          = google_iam_workload_identity_pool.github_actions.workload_identity_pool_id
  workload_identity_pool_provider_id = "github"
  display_name                       = "GitHub OIDC"

  attribute_mapping = {
    "google.subject"             = "assertion.sub"
    "attribute.repository"       = "assertion.repository"
    "attribute.repository_owner" = "assertion.repository_owner"
    "attribute.ref"              = "assertion.ref"
    "attribute.workflow"         = "assertion.workflow"
    "attribute.actor"            = "assertion.actor"
    "attribute.repository_ref"   = "assertion.repository + \":\" + assertion.ref"
  }

  attribute_condition = "assertion.repository_owner == \"davidho27941\""

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

# Project number is needed to build principalSet URIs.
data "google_project" "this" {
  project_id = var.project
}

locals {
  wif_pool_name = "projects/${data.google_project.this.number}/locations/global/workloadIdentityPools/${google_iam_workload_identity_pool.github_actions.workload_identity_pool_id}"
}

resource "google_service_account_iam_member" "gha_ci_wif_user" {
  service_account_id = "projects/${var.project}/serviceAccounts/gha-ci@${var.project}.iam.gserviceaccount.com"
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${local.wif_pool_name}/attribute.repository/davidho27941/Weather_data_dbt"
}

resource "google_service_account_iam_member" "gha_cd_wif_user" {
  service_account_id = "projects/${var.project}/serviceAccounts/gha-cd@${var.project}.iam.gserviceaccount.com"
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${local.wif_pool_name}/attribute.repository_ref/davidho27941/Weather_data_dbt:refs/heads/main"
}
```

Then:

```bash
cd terraform
terraform plan -out=tfplan      # expect 4 to add: pool, provider, 2 SA bindings
terraform apply tfplan
terraform output                # capture pool / provider names for the next step
```

The two existing `google_service_account_iam_member` bindings for
`gha_cd_act_as` (in `iam.tf`) are unrelated and should stay untouched —
those are act-as bindings on the runtime SAs (`dbt-runner`,
`bronze-loader`), not the GHA SAs.

### Step 2: Add the `GCP_PROJECT_NUMBER` GHA variable

The workflows need the project *number* (not ID) to build the provider
path. Add it once at repo level so it's accessible to all workflows:

```bash
# Find the number
gcloud projects describe side-project-staging --format='value(projectNumber)'

# Set as a non-secret repo variable (gh CLI, or via GitHub Settings → Variables)
gh variable set GCP_PROJECT_NUMBER --body=<the number>
```

This is a *variable* (`vars.GCP_PROJECT_NUMBER`), not a *secret* — the
project number isn't sensitive.

### Step 3: Switch GHA workflows to WIF

For each of `dbt_ci.yml`, `dbt_cd.yml`, `bq_cd.yml`:

1. Add the `id-token: write` permission at the workflow (or job) level.
2. Replace the auth action's `credentials_json` input with
   `workload_identity_provider` + `service_account`.

```yaml
# Before
permissions:
  contents: read

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: google-github-actions/auth@v2
        with:
          credentials_json: ${{ secrets.GCP_SA_KEY_CD }}

# After
permissions:
  contents: read
  id-token: write          # NEW — required for OIDC token

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: google-github-actions/auth@v2
        with:
          workload_identity_provider: projects/${{ vars.GCP_PROJECT_NUMBER }}/locations/global/workloadIdentityPools/github-actions/providers/github
          service_account: gha-cd@side-project-staging.iam.gserviceaccount.com
```

The `gha-ci` and `gha-cd` SA emails are different — use the right one
per workflow.

Also update [`.github/workflows/README.md`](../.github/workflows/README.md)
to match the new auth pattern.

Push the workflow changes to a branch and run the workflows there to
verify before merging to `main`. Note: `gha-cd` is restricted to `main`,
so CI works from any branch but CD-style verification has to happen on
`main`. Two options:

- Open a PR, watch `dbt_ci.yml` pass via WIF (most of the validation).
- After merge, watch `dbt_cd.yml` and `bq_cd.yml` succeed on `main`. If
  they fail, the SA keys are still in repo secrets — revert the
  workflow change and CD restores.

### Step 4: Decommission SA keys (only after ~7 days of clean WIF runs)

```bash
# 1. Remove the GHA secrets
gh secret delete GCP_SA_KEY_CI
gh secret delete GCP_SA_KEY_CD

# 2. Delete the JSON keys in GCP
gcloud iam service-accounts keys list \
  --iam-account=gha-ci@side-project-staging.iam.gserviceaccount.com \
  --format='value(name)' | xargs -I{} gcloud iam service-accounts keys delete {} \
  --iam-account=gha-ci@side-project-staging.iam.gserviceaccount.com --quiet

# Repeat for gha-cd
```

Wait the full week deliberately. WIF has corner-case failure modes
(token TTL, OIDC issuer outages, provider config drift) that only
surface over time; keeping the fallback during the bake-in period is
cheap insurance.

### Step 5: Docs cleanup

- Remove the "Workload Identity Federation" bullet from README Future
  work in both `README.md` and `multilingual_readme/readme_jp.md`.
- Update the Stack table CI/CD row: "auth via WIF (no long-lived
  credentials)" instead of "auth via service-account JSON keys".
- Add a Migration history bullet for the PR that lands this.

## Rollback plan

Each step is independently rollback-able:

| Step | Rollback |
|---|---|
| 1 (TF apply) | `terraform destroy -target=google_iam_workload_identity_pool.github_actions` (deletes pool + provider + bindings together) |
| 2 (GHA variable) | `gh variable delete GCP_PROJECT_NUMBER` |
| 3 (workflow update) | `git revert` the workflow commit — SA keys still in secrets, CD resumes immediately |
| 4 (key deletion) | **Non-trivial** — must regenerate keys from GCP and re-add secrets. This is why we wait 7 days before doing step 4 |

The "danger zone" is between step 3 (workflows use WIF) and step 4 (keys
deleted). During this window, both paths work; rollback is one revert
away. After step 4, rollback requires creating new keys.

## Verification

After step 1:

```bash
gcloud iam workload-identity-pools describe github-actions --location=global
gcloud iam workload-identity-pools providers describe github \
  --location=global --workload-identity-pool=github-actions
```

After step 3 (run a workflow and watch the logs):

```
[google-github-actions/auth] Created credentials file at "/tmp/..."
[google-github-actions/auth] Successfully authenticated as gha-cd@side-project-staging.iam.gserviceaccount.com
```

Cloud Audit Logs should show the impersonation chain — the
`generateAccessToken` call's `authenticationInfo` includes a
`serviceAccountDelegationInfo` chain that names the WIF principal:

```bash
gcloud logging read '
  protoPayload.methodName="GenerateAccessToken"
  AND protoPayload.serviceName="iamcredentials.googleapis.com"
  AND resource.labels.email_id="gha-cd@side-project-staging.iam.gserviceaccount.com"
' --limit=5 --format='value(timestamp,protoPayload.authenticationInfo.principalEmail,protoPayload.authenticationInfo.serviceAccountDelegationInfo)' --freshness=1h
```

A successful entry includes a `principal_subject` that decodes to the
specific workflow run.

## Out of scope

- **Other SAs** (`dbt-runner`, `bronze-loader`, `scheduler-invoker`) —
  these are runtime SAs used by Cloud Run / Cloud Scheduler, not GHA.
  No SA keys involved; no migration needed.
- **User auth** (`gcloud auth application-default login`) — already
  short-lived OAuth, doesn't need WIF.
- **Cross-project federation** — single-project deployment;
  multi-project WIF design can wait until `side-project-prod` exists.
- **Fork PRs** — `dbt_ci.yml` currently doesn't run on PRs from forks
  (GHA default for `secrets` access). WIF doesn't change this; if fork
  PR validation becomes desirable later, that's a separate design
  question (need to choose between `pull_request_target` and a
  fork-restricted SA).

## Why we deferred (and why that's defensible)

PR #5 explicitly listed WIF as Future work. The decision was: ship IaC
first with the existing auth, validate the pipeline end-to-end, then
upgrade the auth layer once everything else is stable. Reasoning:

- **WIF is a lateral move, not a feature.** It doesn't change what the
  pipeline does; it only changes how CI/CD authenticates. The pipeline
  was higher-priority to validate.
- **Coupling risk.** Doing WIF in the same PR as the IaC import
  (PR #5) would conflate two unrelated kinds of change — if anything
  broke, isolating which subsystem caused it would be harder.
- **No active incident.** SA keys aren't great, but they're not on
  fire. Deferring 1-2 months while we shipped data-quality +
  observability (PR #7) is cheap risk.

The migration recipe in this doc is meant to be executable in a single
focused PR (~half day of work + a 7-day bake-in before key deletion).

## References

- GCP docs: [Workload Identity Federation with GitHub Actions](https://cloud.google.com/iam/docs/workload-identity-federation-with-deployment-pipelines#github-actions)
- Action: [google-github-actions/auth](https://github.com/google-github-actions/auth#setup)
- Related Future work: see [`README.md` § Future work](../README.md#future-work)
- Related decision context: [`docs/portfolio_gap_analysis.md`](portfolio_gap_analysis.md) Tier 1 §3
