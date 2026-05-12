# weather_data_dbt

> **本日本語版は AI による自動翻訳です。** 内容に齟齬がある場合は
> [英語版 README](../README.md) を正とします。

台湾中央氣象署（CWA）の気象観測データを対象としたエンド・ツー・エンドの
データパイプラインです。当初は Airflow + S3 + Snowflake 構成でしたが、
現在は GCP ネイティブな構成（GCS + BigQuery + dbt + Cloud Run）に
完全移行済みです。

> 英語版は [`../README.md`](../README.md) を参照してください。

## アーキテクチャ

```
                          ┌──────────────────┐
                          │ Cloud Scheduler  │  10 分ごとの cron
                          └────────┬─────────┘
                                   │ トリガー
                                   ▼
       ┌──────────┐ HTTPS GET ┌──────────────┐
       │ CWA APIs │◀───────── │ weather-     │
       │          │── JSON ──▶│ crawler      │
       └──────────┘           │ (Cloud Run)  │
                              └──────┬───────┘
                                     │ JSON ファイル書き込み
                                     ▼
                              ┌─────────────┐
                              │ GCS bucket  │
                              │  weather_*  │
                              └──────┬──────┘
                                     │ 一括ロード（初回）
                                     │ + 日次 MERGE（Cloud Run Job, 毎日 02:00）
                                     ▼
                          ┌────────────────────┐
                          │  BigQuery bronze   │
                          │  weather_raw.*     │
                          └─────────┬──────────┘
                                    │ dbt build  (Cloud Run Job, 毎週月曜 02:30)
                                    │ dbt source freshness  (Cloud Run Job, 毎時)
                                    ▼
              ┌────────────────────────────────────────────────┐
              │  BigQuery silver / gold                        │
              │  weather_staging   →   weather_intermediate    │
              │                          ↓                     │
              │                    weather_marts               │
              │   fct_measurements_{10min,hourly,daily,        │
              │                     weekly,monthly}            │
              │   dim_stations                                 │
              └────────────────────────────────────────────────┘
```

2 つの Cloud Monitoring アラートポリシーが email 通知チャンネルへ
発火します。1 つ目は 3 つの Cloud Run Job のいずれかがリトライ後も
最終的に失敗した場合、2 つ目は log-based metric
`dbt_test_failure_count` 経由で dbt の severity=error テストが失敗した
場合に発火します。後者はインフラ系障害と区別された signal を
on-call に提供します。Cloud Monitoring ダッシュボード
`Weather pipeline health` には Job 実行結果、dbt テスト失敗数、
BigQuery slot 使用率、クローラーバケットのストレージティアリングが
集約されています。SLO の目標値と「ページするか様子を見るか」の判断軸は
[`docs/slo.md`](../docs/slo.md) を参照してください。

3 つの時間粒度のロールアップ（10 分 / 時 / 日 / 週 / 月）が下流の ML 学習に
供給され、`dim_stations` はすべての fact テーブルに JOIN されます。
センチネル値（`'X'`、`'T'`、`'-99'`、`'-98'`、`'990'`）を含む測定値
フィールドは bronze 層では STRING として保存され、dbt staging 層で
raw + cleaned の二重カラムとして公開されます。これによりガバナンスと
ML パイプラインがそれぞれ必要なカラムを選択できます。

設計の背景は [`docs/redesign_proposal.md`](../docs/redesign_proposal.md)、
直近の変更内容は [`docs/pr_desc.md`](../docs/pr_desc.md) を参照してください。

## リポジトリ構成

| パス | 役割 |
|---|---|
| [`weather-crawler/`](../weather-crawler/) | CWA API を取得し JSON を GCS に書き込む FastAPI サービス（Cloud Run） |
| [`infra/bq/`](../infra/bq/) | Bronze 層：スキーマファイル、一括ロードスクリプト、`bronze-daily-load` Cloud Run Job（Dockerfile + deploy + scheduler スクリプト） |
| [`weather_data_dbt/`](../weather_data_dbt/) | dbt プロジェクト（BigQuery プロファイル、dev / stg / prod / ci ターゲット） |
| [`infra/dbt/`](../infra/dbt/) | 2 つの Cloud Run Job（`dbt-weekly-build`、`dbt-hourly-freshness`）用の Dockerfile + スクリプト + Cloud Scheduler トリガー |
| [`infra/monitoring/`](../infra/monitoring/) | Cloud Monitoring email アラートポリシーのシェルスクリプトベースのオンボーディング（現在は Terraform でも管理 — 下記参照） |
| [`terraform/`](../terraform/) | **真実の単一情報源（PR #5 以降）。** SA、IAM、AR repo、BQ datasets、クローラー GCS bucket（lifecycle 含む）、3 つの Cloud Run Job、3 つの Scheduler、Cloud Monitoring channel + 複数アラートポリシー + パイプラインヘルスダッシュボード、dbt テスト失敗用の log-based metric を一括で管理する単一の Terraform root。State は `gs://weather-pipeline-tfstate`。 |
| [`.github/workflows/`](../.github/workflows/) | GitHub Actions：CI（PR 検証）+ CD（イメージ push、Cloud Run Job ロールアウト）+ dbt docs 公開 |
| [`docs/`](../docs/) | `redesign_proposal.md`（設計ドキュメント）、[`decisions/`](../docs/decisions/)（自明でない設計判断のメモ）、`slo.md`（SLO と対応方針）、`pr_desc.md`（最新 PR 説明） |
| [`dags/`](../dags/) | Airflow DAG。`*_v_1_*` は Snowflake 時代の歴史的 v1；`*_v_2_0_0` は v2 アーキテクチャ（crawler / bronze daily MERGE / weekly dbt build / hourly source freshness）の Airflow ネイティブ移植版で、v2 設計が orchestrator ベースのスタックにも移植できることを示すために残してある（本番には配線されていない）。 |
| [`dev/`](../dev/) | uv 管理の Airflow ローカル sandbox。`*_v_2_0_0` DAG の編集を手元で素早く検証するため。`.github/workflows/dag_check.yml` が同じ bootstrap + check スクリプトを CI でも実行するので、ローカルと CI は同じパスを通る。 |
| ルートの `Dockerfile` | **レガシー** v1 Airflow image。後続のクリーンアップ PR で削除予定。 |

## 技術スタック

| レイヤー | ツール / バージョン |
|---|---|
| クローラー | Cloud Run 上の FastAPI、Python 3.12 |
| オブジェクトストレージ | GCS（`gs://${GCS_BUCKET}/`、`dt=YYYY-MM-DD` で hive パーティション）；多段ライフサイクル：Standard → Nearline（30 日）→ Coldline（90 日）→ Archive（365 日）、削除は行わない |
| データウェアハウス | BigQuery（`asia-east1`、`side-project-staging` / 将来的に `side-project-prod`） |
| 変換 | `dbt-core` 1.11.x · `dbt-bigquery` 1.11.x · `dbt_utils` 1.3.x |
| オーケストレーション | 3 つの Cloud Run Job + Cloud Scheduler トリガー：`bronze-daily-load`（`0 2 * * *`）、`dbt-weekly-build`（`30 2 * * 1`）、`dbt-hourly-freshness`（`0 * * * *`） |
| アラート | Cloud Monitoring email アラートポリシー 2 本：(1) Cloud Run Job のリトライ枯渇失敗、(2) log-based metric `dbt_test_failure_count` 経由の dbt severity=error テスト失敗。同じ TF root にパイプラインヘルスダッシュボードも管理。 |
| データ品質 | 全モデルに dbt テスト：`not_null` / `unique` / `accepted_values` / `accepted_range`（台風耐性のある閾値）/ `unique_combination_of_columns` / `relationships`（severity=warn）；加えて singular test 2 本（sentinel translation invariant：severity=error、行数アノマリー z-score：severity=warn） |
| CI/CD | GitHub Actions（サービスアカウント JSON キー認証；WIF への移行手順をドキュメント化済み） |
| IaC | Terraform `~> 6.0` の google provider、[`terraform/`](../terraform/) 単一 root、State は GCS bucket `weather-pipeline-tfstate` |

## 環境

データセット単位で隔離された 3 つの dbt ターゲット：

| ターゲット | 用途 | データセット |
|---|---|---|
| `dev` | ローカル開発（`gcloud auth application-default login`） | `weather_dev_{staging,intermediate,marts}` |
| `ci` | GitHub Actions による PR 検証 | `weather_ci_{staging,intermediate,marts}`（毎回再構築、bronze の直近 7 日分のサブサンプル） |
| `stg` | 週次 Cloud Run Job、毎週月曜 02:30 Asia/Taipei（現在の真実の単一情報源） | `weather_{staging,intermediate,marts}` |
| `prod` | `side-project-prod` 立ち上げ後に予約済み | （同じデータセット名、別プロジェクト） |

ルーティングはカスタム
[`generate_schema_name`](../weather_data_dbt/macros/generate_schema_name.sql)
マクロで実装されています。

## クイックスタート（ローカル開発）

```bash
# 1. 認証
gcloud auth application-default login
gcloud config set project side-project-staging

# 2. dbt 環境（uv venv 推奨）
uv venv && source .venv/bin/activate
uv pip install 'dbt-core>=1.11,<1.12' 'dbt-bigquery>=1.11,<1.12'

# 3. プロファイル + 依存関係
cd weather_data_dbt
cp profiles/profiles.example.yml profiles/profiles.yml
dbt deps --profiles-dir profiles

# 4. ビルド
dbt build --target dev --profiles-dir profiles
```

dbt ドキュメントは `main` への push のたびに GitHub Pages へ自動公開されます：
[Web Page](https://davidho27941.github.io/Weather_data_dbt/#!/overview)。

## マイグレーション履歴

- **v1（廃止）**：Airflow 2.9 + AWS S3 + Snowflake。ソースは
  [`dags/`](../dags/) の `*_v_1_*` ファイル群と Airflow ベースのルート
  `Dockerfile` 配下。
  [`images/jp/`](../images/jp/) のダイアグラムはこの構成を反映しています。
- **v2（現行）**：GCP ネイティブ。
  - PR #2 — BigQuery に bronze 層（`weather_raw.*`）を導入。一括ロード + 日次 MERGE。
  - PR #3 — BigQuery 向け dbt 書き換え、3 つの Cloud Run Job（bronze daily / dbt weekly / dbt freshness hourly）+ Cloud Scheduler トリガー、GHA CI/CD。
  - PR #4 — Cloud Run Job 実行失敗を検知する Cloud Monitoring email アラート。
  - PR #5 — PR #3 + PR #4 の全成果物を Terraform 化（[`terraform/`](../terraform/) の単一 root、state は `gs://weather-pipeline-tfstate`）。真実の単一情報源がシェルスクリプトから `terraform apply` に切り替わる。
  - PR #6 — クローラー GCS bucket を Terraform に import し、多段ライフサイクル（Standard → Nearline 30 日 → Coldline 90 日 → Archive 365 日、削除なし）を追加。Bucket には `prevent_destroy = true` を設定し、削除は 2 コミット必須の操作にする。
  - PR #7 — データ品質 + Observability の強化。dbt テスト拡充（relationships、全数値測定カラムの accepted_range、sentinel translation invariant、z-score による行数アノマリー）、dbt severity=error 失敗用の log-based metric + アラートポリシー、単一の `Weather pipeline health` Cloud Monitoring ダッシュボード、SLO 明示用の [`docs/slo.md`](../docs/slo.md)。
  - PR #8 — [`docs/decisions/`](../docs/decisions/) に自明でない 3 つの設計判断のメモを追加：STRING-typed bronze sentinels（001）、dual-column raw + cleaned staging（002）、marts レイヤーの dbt contract 強制提案（003、`Status: Proposed`）。Contract の実装は別 PR に切り出し、設計レビューとカラム単位の型レビューを独立で行えるようにする。
  - PR #9 — `build_dbt_docs.yml` workflow を `--target stg` に切り替え、GitHub Pages 上の dbt docs カタログが prod の行数を反映するようにする（以前は CI の 7 日 subsample を継承していた）。Terraform で `gha-ci` に `weather_{staging,intermediate,marts}` 上の `dataViewer` IAM binding を追加。
  - PR #10 — v2 アーキテクチャの Airflow ネイティブ移植版を [`dags/*_v_2_0_0`](../dags/) に追加。4 つの DAG が v2 cadence を再現（10 分毎 crawler / 日次 MERGE / 週次 dbt build / 時次 source freshness）。dbt 部分は `cosmos`、BigQuery + GCS は providers を使用。v2 設計が orchestrator ベースのスタックにも移植可能であることを示すための実装；本番への配線は行わない（本番は Cloud Run Job のまま）。

## 今後の作業

- **Workload Identity Federation** で GitHub Actions の SA キー
  シークレット 2 本を置き換える（キー輪替の手間を排除）。
- **marts レイヤーでの dbt model contract 強制** —
  設計は [decision 003](../docs/decisions/003-enforce-dbt-contracts-on-marts.md)、
  実装は後続 PR にて。
- **Webhook 通知チャンネル**（Discord / Slack / Pub-Sub）+ **freshness wrapper** で source ごとの詳細を構造化送信。Email チャンネルは粒度の細かい freshness ペイロードを表示できない。
- PR CI に **sqlfluff** lint を追加。
- **コスト / パフォーマンス ダッシュボード** — モデル別 BQ slot 消費、partition スキャンバイト数、scheduled query コストのドリルダウン。
- **Renovate / Dependabot** で dbt-core / dbt-bigquery / SDK / ベースイメージの自動更新。
- **BQ データ品質モニタリング**（dbt artifacts に
  [`elementary-data`](https://github.com/elementary-data/elementary)
  を被せるなど） — 現状の singular anomaly test を将来的に置き換える想定。
- **prod 環境** — `terraform/envs/{staging,prod}/` に分割、`side-project-prod` を立ち上げ。
- **Terraform apply の GHA 化** + PR review ゲート（現状は `apply` がワークステーション操作）。
- **レガシーな Snowflake 関連成果物の削除**（ルートの v1 `Dockerfile`、
  古いイメージ参照など）。`dags/` は v2 移植版を含むため残置。
