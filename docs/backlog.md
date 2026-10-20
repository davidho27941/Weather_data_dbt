# 任務清單（Backlog）

建立日期：2026-10-20。盤點來源：`feat/cwa-cumulative-semantics-fix` 分支的未提交改動、
GCP 正式環境狀態（Cloud Scheduler / Cloud Run Jobs / bronze 表）、2026-10-15 爬蟲修復
（weather-crawler PR #18）的後續，以及 `docs/portfolio_gap_analysis.md` 的優先建議。

狀態標記：`[ ]` 未開始、`[~]` 進行中、`[x]` 完成。完成後請更新本檔並寫上日期。

---

## P0 — 資料正在流失或有安全疑慮，本週內處理

### 1. 保住 dbt 分支上未提交的工作
- [x] 2026-10-20：模型/ADR/README 與 runbook、cost_performance、wif_migration（en/zh）、backlog 已分三個 commit 推上 origin（`6e079cd`、`1122786`、`2d6c8e8`）。原規劃 commit 清單：
      （`stg_observations.sql`、`stg_rain_fall_stations.sql`、`_models.yml`、ADR-004、README、
      `docs/runbook.md`、`docs/cost_performance.md`、`docs/wif_migration*.md`、`docs/portfolio_gap_analysis.md`、
      `weather_data_dbt/setup_sa.sh`）
- [x] `portfolio_gap_analysis.md` 決定不入庫（2026-10-20）；已加入本機 `.git/info/exclude`，檔案保留在工作目錄
- [x] `weather_data_dbt/setup_sa.sh` 決定不入庫（2026-10-20）；已加入本機 `.git/info/exclude`
- [ ] 處理 `stash@{0}`（掛在 `feat/refactor-sql` 上，2026-05 留下）：內容僅為 `.gitignore` 加 `docs/` 一行，已過時，建議 `git stash drop`
- 完成條件：`git status` 乾淨，分支已推上 origin。

### 2. 更換 CWA API token — **完成**（2026-10-20）
- 2026-10-20 進度：使用者已新增 secret 第 2 版並停用第 1 版（04:28 UTC）。因 Cloud Run 仍指向已停用的第 1 版，
  立即以 `gcloud run services update --update-secrets CWA_AUTH_TOKEN=codis-api-token:2` 切換（revision 00015）。
  weather-crawler PR #20 把 CI 部署指令的 `:1` 改為 `:2`；該分支 push 時因 main 的 deploy 閘門尚未恢復（PR #19 未合併）
  而被 CI 直接部署為 revision 00016（同樣使用第 2 版，無害，但再次印證任務 3 的必要）。04:43 UTC tick 已在 00016 上以新 token 成功抓取。
- 原因：舊 token 以明文出現在 Cloud Logging 的 `Starting to fetch data from …?Authorization=…` 行，
  2026-06-01 至 2026-10-15 每 10 分鐘一筆；30 天保留期內仍可查到。
- [x] 到 CWA 開放資料平台重新產生 API 授權碼（2026-10-20，使用者）
- [x] `gcloud secrets versions add codis-api-token`（第 2 版，2026-10-20，使用者）
- [x] 把 weather-crawler CI 的 `--set-secrets` 改成 `:2`：PR #20 已於 2026-10-20 06:16 UTC 合併，CI 部署 revision 00018 成功（Ready、第 2 版 secret）。
- [x] 舊授權碼已失效：CWA 平台重新產生授權碼時即同步作廢舊碼，無需另行操作（2026-10-20，使用者確認）
- 完成條件：Cloud Run 使用新版本 secret，舊 token 已失效，GCS 持續每天 144 個檔案。
- 狀態：**完成**（2026-10-20）。附註：PR #19 先合併時觸發的部署因 main 仍指向第 1 版而失敗（revision 00017 未接流量，服務未中斷），PR #20 合併後恢復。

### 3. 收緊 weather-crawler 的 CI 部署條件 — **完成**（2026-10-20）
- 原因：2026-05-26 把 deploy job 的 `if: github.event.pull_request.merged == true` 註解掉後，
  任何分支 push 都會直接部署到正式環境（10-15 的修復即因此在合併前就上線）。
- [x] 2026-10-20：weather-crawler PR #19 已合併，deploy 條件為 `workflow_dispatch || pull_request.merged`；分支 CI 驗證 deploy 顯示 skipped。
- 完成條件：feature branch push 只跑 pytest，不跑 deploy。

---

## P1 — 讓正式 pipeline 重新運轉

### 4. 驗證並合併 dbt 分支（即 README 中預留的 PR #11）
- 背景：分支修正 CWA `Precipitation` / `SunShine` 為日累積值的語意、加入台北 00:00 強制歸零、
  LAG 改為不用 `IGNORE NULLS`、新增 15 分鐘間隔守衛。未提交的 SQL 改動尚未經任何 dbt 驗證。
- [ ] 建立本機 dbt 環境（目前 PATH 上沒有 dbt，也沒有 `.venv`）
- [ ] `dbt build --select stg_observations+ --target stg` 確認 `accepted_range` 測試通過
- [ ] 抽查站 `467571` 在 2026-04-26 → 04-27 台北邊界的 `*_10min_window` 值符合 ADR-004 描述
- [ ] 開 PR、CI 通過後合併
- 完成條件：PR 合併進 main，GitHub Pages 的 dbt docs 反映新欄位描述。

### 5. 恢復三個 PAUSED 的 Cloud Scheduler 排程
- 現況：`bronze-daily-load`、`dbt-weekly-build`、`dbt-hourly-freshness` 自 2026-05-26 起 PAUSED；
  bronze 表最新 `measure_at` 為 2026-05-26 13:50（約 2,543 萬筆）。GCS 自 2026-10-15 起已恢復進料。
- [ ] 先手動跑一次 `bronze-daily-load`，依 `docs/runbook.md` §2 把載入視窗放寬到涵蓋 2026-10-15 之後
- [ ] 確認 bronze 有 10 月資料後，手動跑 `dbt-weekly-build`
- [ ] 三個排程 `gcloud scheduler jobs resume`
- 完成條件：三個排程 ENABLED，各自最近一次執行成功，`dbt source freshness` 不再 ERROR。
- 相依：建議在任務 4 合併後再做，否則 weekly build 會再次因 `accepted_range` 失敗。

### 6. 處理 2026-06-01 03:03 UTC 至 2026-10-15 15:53 UTC 的資料缺口
- [ ] 在 ADR 或 `docs/runbook.md` 記錄這段缺口的成因（CWA 啟用嚴格 URI 檢查、爬蟲雙斜線 URL）與範圍
- [ ] 評估是否從 CWA CODiS 下載歷史 CSV 回補；若不回補，在 marts 的 `_models.yml` 與資料卡明示缺口
- [ ] 確認 freshness / rollup 測試對缺口期間的行為（例如 daily fact 不應產生全 NULL 的假日列）
- 完成條件：缺口有文件、下游消費者不會誤讀。

---

## P2 — 爬蟲健壯性

### 7. retry decorator 只對可重試錯誤重試
- 現況：`weather_crawler/decorators.py` 對所有非 200 重試 5 次，遇到 400/401 白等約 15 秒。
- [ ] 只對 5xx 與連線錯誤重試，4xx 直接失敗並記錄
- [ ] 補單元測試

### 8. GCS 上傳偶發逾時
- 現況：2026-10-15 15:53 那次抓取成功但背景上傳逾時 120 秒（`storage.googleapis.com` 連線逾時），
  原因是 FastAPI BackgroundTasks 在回應後執行，Cloud Run 預設回應後即節流 CPU。
- [ ] 二選一：deploy 加 `--no-cpu-throttling`，或把上傳改為回應前同步完成
- [ ] 加上傳失敗的告警（目前只有 log）

---

## P3 — 求職導向（依 `docs/portfolio_gap_analysis.md` 的「三件事」）

### 9. Workload Identity Federation 遷移
- 現況：`docs/wif_migration.md` 為 Draft，2026-05-11 後未更新；GHA 仍用 SA JSON key。
- [ ] 依文件 Step 1–5 執行，或至少把設計寫成正式 ADR-005
- 完成條件：GHA 以 WIF 認證，SA key 刪除；或 ADR-005 合併。

### 10. Cloud Monitoring dashboard 與 `docs/slo.md`
- [ ] 一個 dashboard 涵蓋：爬蟲成功率、GCS 每日檔案數、bronze 延遲、dbt test 失敗數
- [ ] 一頁 SLO 文件定義 freshness 與正確性目標
- 備註：這次事故若有「GCS 每日檔案數 < 140」的告警，缺口不會拖四個半月。

### 11. ADR 補齊到 006
- 現有：001 STRING sentinels、002 dual-column staging、003 contracts（Proposed）、004 cumulative semantics。
- [ ] ADR-005：WIF（可與任務 9 合併）
- [ ] ADR-006：候選題目為「為何用 Cloud Run Job 而非 Composer/Dataflow」或「bronze 層保留 CWA 原值的治理邊界」

---

## 不做（引自 portfolio_gap_analysis.md 的反優先清單）
- 增加更多 dbt models / fact tables
- 更複雜的 GHA 編排
- 前端或視覺化層
- 改用 Composer 或 Dataflow
