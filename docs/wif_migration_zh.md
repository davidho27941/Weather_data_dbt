# Workload Identity Federation 遷移計畫

> **本中文版為 AI 翻譯。** 如有差異請以
> [英文版](wif_migration.md) 為準。

## 狀態

**草案 — 尚未執行。** 本文件記錄設計、具體遷移步驟、驗證方式與
rollback 策略，目的是讓這項工作可以在優先順位排到時、用一個專注的
session 一次做完。

最後審閱日期：2026-05-11。

## 為什麼這件事重要

目前兩個 GitHub Actions 用的 service account（`gha-ci`、`gha-cd`）
透過存在 GHA repo secrets 的長效 JSON 金鑰認證（`GCP_SA_KEY_CI`、
`GCP_SA_KEY_CD`）。具體三個問題：

1. **沒有自動輪替。** 金鑰外洩後，在被人察覺並手動輪替前都會持續
   有效。實務上等於「在有人發現之前」。
2. **無條件式存取控制。** 外洩的金鑰可以從任何 IP、任何 workflow、
   任何 repo 使用。GCP IAM 沒辦法區分「這是我們 `main` branch 的
   CD 跑」跟「這是攻擊者拿到金鑰」。
3. **Audit trail 流失 workflow context。** 每筆 Cloud Audit log 的
   principal 都只是 SA；要還原「實際是哪個 GHA workflow run 觸發
   這個操作」必須靠 timestamp 比對。Incident 處理時很痛苦。

Workload Identity Federation (WIF) 把靜態金鑰換成「每次 workflow
run 由 GitHub 簽發的短效 OIDC token」，再用這 token 換等效短效的
GCP access token。性質：

- 任何地方都沒有長效憑證 — 沒東西可以輪替、沒東西可以外洩
- 透過 attribute mapping 實現條件式存取（依 repo / branch /
  workflow / actor）
- Audit log 的 impersonation chain 帶有 workflow run identity

## 現況

| 元件 | 目前認證方式 | 改用 WIF 之後 |
|---|---|---|
| `dbt_ci.yml`（PR 驗證） | `secrets.GCP_SA_KEY_CI` → `gha-ci@…` | OIDC token → WIF provider → `gha-ci@…` |
| `dbt_cd.yml`（image push + Job rollout） | `secrets.GCP_SA_KEY_CD` → `gha-cd@…` | OIDC token → WIF provider → `gha-cd@…` |
| `bq_cd.yml`（bronze image + Job rollout） | `secrets.GCP_SA_KEY_CD` → `gha-cd@…` | OIDC token → WIF provider → `gha-cd@…` |
| `build_dbt_docs.yml`（docs 發佈） | 不需認證（只用 GitHub Pages） | 不變 |

影響到的 GHA secrets 共兩個：`GCP_SA_KEY_CI`、`GCP_SA_KEY_CD`。
對應的兩把 JSON 金鑰在 GCP 上掛在各自 SA 的 keys 底下。

## 設計

### 認證流程 before / after

```
BEFORE（SA key）：
   GHA workflow ─secret─► JSON key  ──► GCP IAM（key-based auth）
                                          │
                                          ▼
                                       gha-cd SA   ── 執行 gcloud 指令

AFTER（WIF）：
   GHA workflow ──OIDC JWT──► WIF pool / provider ──映射至──► principalSet
                                                                  │
                                  ┌───────────────────────────────┘
                                  │ IAM binding 賦予 workloadIdentityUser
                                  ▼
                               gha-cd SA（透過 STS token impersonate，~1h TTL）
                                  │
                                  ▼
                              執行 gcloud 指令
```

OIDC JWT 由 `token.actions.githubusercontent.com` 簽發。每次
workflow run 都會拿到一個新的 JWT，內含 `repository`、
`repository_owner`、`ref`、`workflow`、`actor`、`job_workflow_ref`
等 claims。

### Attribute mapping

JWT claims → GCP attributes。下面的對應涵蓋標準欄位，加上一個
複合的 `attribute.repository_ref` 用於 branch-scoped trust：

| GCP attribute | 來源 claim |
|---|---|
| `google.subject` | `assertion.sub` |
| `attribute.repository` | `assertion.repository` |
| `attribute.repository_owner` | `assertion.repository_owner` |
| `attribute.ref` | `assertion.ref` |
| `attribute.workflow` | `assertion.workflow` |
| `attribute.actor` | `assertion.actor` |
| `attribute.repository_ref` | `assertion.repository + ":" + assertion.ref` |

### Provider-level attribute condition

GCP 自 2023 年安全政策變更後，創建 GitHub OIDC provider 時若沒設
`attribute_condition` 會直接被拒絕。因為若不設，**任何** GitHub.com
上的 public workflow 都可以嘗試 impersonate 我們的 SA，這時只剩 IAM
bindings 是唯一的防線。

在 provider 層級限制信任範圍：

```
assertion.repository_owner == "davidho27941"
```

不是 `davidho27941` 帳號下 repo 的 OIDC token 會在 IAM 還沒被諮詢
前就被拒絕。

### 每個 SA 的 principalSet

依各 SA 的 blast radius 決定範圍：

- **`gha-ci`** — PR 驗證。必須允許本 repo 的任何 branch / 任何 PR。
  Principal set：
  ```
  principalSet://iam.googleapis.com/projects/<PROJECT_NUMBER>/locations/global/
    workloadIdentityPools/github-actions/attribute.repository/davidho27941/Weather_data_dbt
  ```

- **`gha-cd`** — 部署到 live infra。必須 **限制只能從 `main` 觸發**
  以免 feature branch 自己 deploy 自己。Principal set 用複合 attribute：
  ```
  principalSet://iam.googleapis.com/projects/<PROJECT_NUMBER>/locations/global/
    workloadIdentityPools/github-actions/attribute.repository_ref/
    davidho27941/Weather_data_dbt:refs/heads/main
  ```

採用 principal set 做 branch scoping（而不是在 binding 上加 IAM
Condition）是因為這樣信任範圍直接寫在 binding member 字串裡，
`terraform plan` diff 一看就知道哪個 branch 能 deploy。IAM Conditions
也行但會把範圍藏在另一個 expression 裡。

## 遷移步驟

Step 1 → 3 是「**並行**新增 WIF」、不動既有金鑰。Step 4 在 WIF 驗證
穩定後才拔除金鑰。**千萬不要**把 Step 1-2 跟 Step 4 合在一起做 —
並行期就是 rollback window。

### Step 1：用 Terraform 建立 WIF

新增 `terraform/wif.tf`：

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

# principalSet URI 需要 project number。
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

接著：

```bash
cd terraform
terraform plan -out=tfplan      # 預期 4 to add：pool、provider、2 個 SA binding
terraform apply tfplan
terraform output                # 抓出 pool / provider 名稱供下一步使用
```

`iam.tf` 裡既有的兩個 `google_service_account_iam_member.gha_cd_act_as`
binding 與本遷移無關、不要動 — 那是 runtime SA（`dbt-runner`、
`bronze-loader`）上的 act-as binding，不是 GHA SA。

### Step 2：在 GHA 加上 `GCP_PROJECT_NUMBER` variable

Workflow 需要 project **number**（不是 ID）來組成 provider 路徑。
在 repo 層級設一次讓所有 workflow 都能用：

```bash
# 查 project number
gcloud projects describe side-project-staging --format='value(projectNumber)'

# 設為 non-secret repo variable（用 gh CLI、或從 GitHub Settings → Variables）
gh variable set GCP_PROJECT_NUMBER --body=<剛剛的數字>
```

這是 **variable**（`vars.GCP_PROJECT_NUMBER`），不是 **secret** —
project number 不敏感。

### Step 3：把 GHA workflow 改用 WIF

`dbt_ci.yml`、`dbt_cd.yml`、`bq_cd.yml` 都做同樣的兩個改動：

1. 在 workflow（或 job）層級加上 `id-token: write` permission。
2. 把 auth action 的 `credentials_json` input 換成
   `workload_identity_provider` + `service_account`。

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
  id-token: write          # NEW — OIDC token 必須的 permission

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: google-github-actions/auth@v2
        with:
          workload_identity_provider: projects/${{ vars.GCP_PROJECT_NUMBER }}/locations/global/workloadIdentityPools/github-actions/providers/github
          service_account: gha-cd@side-project-staging.iam.gserviceaccount.com
```

`gha-ci` 跟 `gha-cd` 兩個 SA email 不一樣，依 workflow 用對的那個。

同時更新
[`.github/workflows/README.md`](../.github/workflows/README.md)
反映新的認證方式。

把 workflow 改動推到一個 branch 上跑驗證，再 merge `main`。要注意：
`gha-cd` 只允許 `main` impersonate，所以 CI 在任何 branch 都會通，
但 CD 風格的驗證只能在 `main` 上做。兩個做法：

- 開 PR，看 `dbt_ci.yml` 透過 WIF 跑成功（涵蓋大部分驗證）。
- Merge 後看 `dbt_cd.yml` 跟 `bq_cd.yml` 在 `main` 上跑成功。若失敗，
  SA 金鑰還在 repo secrets 裡 — revert 一下 workflow commit 就回到
  原本的金鑰流程，CD 即恢復。

### Step 4：拔除 SA 金鑰（**唯有** WIF 連續跑 7 天無事才動）

```bash
# 1. 移除 GHA secrets
gh secret delete GCP_SA_KEY_CI
gh secret delete GCP_SA_KEY_CD

# 2. 刪掉 GCP 上的 JSON 金鑰
gcloud iam service-accounts keys list \
  --iam-account=gha-ci@side-project-staging.iam.gserviceaccount.com \
  --format='value(name)' | xargs -I{} gcloud iam service-accounts keys delete {} \
  --iam-account=gha-ci@side-project-staging.iam.gserviceaccount.com --quiet

# gha-cd 重複一次
```

刻意等滿一週。WIF 有些 corner case（token TTL、OIDC issuer 偶發
outage、provider config drift）只有在時間夠長後才浮現；保留 fallback
是便宜的保險。

### Step 5：文件清理

- 從兩份 README 的 Future work 移除 Workload Identity Federation 條目
  （`README.md` 跟 `multilingual_readme/readme_jp.md`）。
- 更新 Stack table CI/CD 那行：「auth via WIF（no long-lived credentials）」
  取代「auth via service-account JSON keys」。
- 在 Migration history 加上對應 PR 的條目。

## Rollback 計畫

每個步驟都能獨立 rollback：

| 步驟 | Rollback 方式 |
|---|---|
| 1（TF apply） | `terraform destroy -target=google_iam_workload_identity_pool.github_actions`（一起拔 pool + provider + bindings） |
| 2（GHA variable） | `gh variable delete GCP_PROJECT_NUMBER` |
| 3（workflow 改動） | 對該 commit `git revert` — 金鑰還在 secrets，CD 立刻恢復 |
| 4（金鑰刪除） | **不容易** — 必須在 GCP 上重新產生金鑰、重設 secrets。所以 Step 4 才要等 7 天才做 |

「危險區段」是 Step 3（workflow 開始用 WIF）到 Step 4（金鑰刪除）
之間。這段期間兩條路都通、revert 一下就能 rollback。Step 4 之後
rollback 要重新生 key。

## 驗證方式

Step 1 之後：

```bash
gcloud iam workload-identity-pools describe github-actions --location=global
gcloud iam workload-identity-pools providers describe github \
  --location=global --workload-identity-pool=github-actions
```

Step 3 之後（跑一次 workflow、看 log）：

```
[google-github-actions/auth] Created credentials file at "/tmp/..."
[google-github-actions/auth] Successfully authenticated as gha-cd@side-project-staging.iam.gserviceaccount.com
```

Cloud Audit Log 會看到 impersonation chain — `generateAccessToken`
的 `authenticationInfo` 裡有 `serviceAccountDelegationInfo` chain，
裡頭會記錄 WIF principal：

```bash
gcloud logging read '
  protoPayload.methodName="GenerateAccessToken"
  AND protoPayload.serviceName="iamcredentials.googleapis.com"
  AND resource.labels.email_id="gha-cd@side-project-staging.iam.gserviceaccount.com"
' --limit=5 --format='value(timestamp,protoPayload.authenticationInfo.principalEmail,protoPayload.authenticationInfo.serviceAccountDelegationInfo)' --freshness=1h
```

成功的 entry 裡會有 `principal_subject`，decode 後對應到某個具體
workflow run。

## 不在範圍內的東西

- **其他 SA**（`dbt-runner`、`bronze-loader`、`scheduler-invoker`）—
  這些是 Cloud Run / Cloud Scheduler 用的 runtime SA，不是 GHA 用的，
  沒 SA key 牽涉、不需要遷移。
- **個人使用者認證**（`gcloud auth application-default login`）—
  本來就是短效 OAuth，不需要 WIF。
- **跨 project federation** — 目前只有一個 project；多 project WIF
  設計等 `side-project-prod` 起來再說。
- **Fork PR** — `dbt_ci.yml` 目前不在 fork 的 PR 上跑（GHA 對
  `secrets` access 的預設限制）。WIF 不改變這點；若之後想開放
  fork PR 驗證，那是獨立的設計議題（要在 `pull_request_target`
  跟一個 fork-restricted SA 之間做選擇）。

## 為什麼之前 defer（以及這個決定的合理性）

PR #5 明文把 WIF 列為 Future work。當時的決策：先 ship IaC、把
pipeline 端對端驗證、整個架構穩了再來升級認證層。理由：

- **WIF 是 lateral move、不是 feature。** 它不改變 pipeline 在做
  什麼、只改變 CI/CD 怎麼認證。Pipeline 本體比較緊急、要先驗證。
- **耦合風險。** 把 WIF 跟 IaC import（PR #5）放在同一個 PR 等於
  把兩種無關的改動混在一起 — 若有任何東西壞了，要 isolate 是哪
  個 subsystem 引起的會更麻煩。
- **沒有 active incident。** SA key 不理想、但沒在燒。在 ship
  data-quality + observability（PR #7）的期間延後 1-2 個月是
  便宜的風險。

本文件描述的遷移流程目標是「一個專注的 PR 半天做完 + 7 天 bake-in
之後才刪 key」。

## 參考資料

- GCP 官方文件：[Workload Identity Federation with GitHub Actions](https://cloud.google.com/iam/docs/workload-identity-federation-with-deployment-pipelines#github-actions)
- Action 文件：[google-github-actions/auth](https://github.com/google-github-actions/auth#setup)
- 相關 Future work：見 [`README.md` § Future work](../README.md#future-work)
- 相關決策脈絡：[`docs/portfolio_gap_analysis.md`](portfolio_gap_analysis.md) Tier 1 §3
