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

3 つの Cloud Run Job（`bronze-daily-load`、`dbt-weekly-build`、
`dbt-hourly-freshness`）のいずれかがリトライ後も最終的に失敗した場合、
単一の Cloud Monitoring アラートポリシー → email 通知チャンネルが
発火します。

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
| [`terraform/`](../terraform/) | **真実の単一情報源（PR #5 以降）。** SA、IAM、AR repo、BQ datasets、3 つの Cloud Run Job、3 つの Scheduler、Cloud Monitoring channel + アラートポリシーを一括で管理する単一の Terraform root。State は `gs://weather-pipeline-tfstate`。 |
| [`.github/workflows/`](../.github/workflows/) | GitHub Actions：CI（PR 検証）+ CD（イメージ push、Cloud Run Job ロールアウト）+ dbt docs 公開 |
| [`docs/`](../docs/) | `redesign_proposal.md`（設計ドキュメント）と `pr_desc.md`（最新 PR 説明） |
| `dags/`、ルートの `Dockerfile` | **レガシー** v1 Airflow + Snowflake 用。現在は配線されておらず、後続のクリーンアップ PR で削除予定。 |

## 技術スタック

| レイヤー | ツール / バージョン |
|---|---|
| クローラー | Cloud Run 上の FastAPI、Python 3.12 |
| オブジェクトストレージ | GCS（`gs://${GCS_BUCKET}/`、`dt=YYYY-MM-DD` で hive パーティション） |
| データウェアハウス | BigQuery（`asia-east1`、`side-project-staging` / 将来的に `side-project-prod`） |
| 変換 | `dbt-core` 1.11.x · `dbt-bigquery` 1.11.x · `dbt_utils` 1.3.x |
| オーケストレーション | 3 つの Cloud Run Job + Cloud Scheduler トリガー：`bronze-daily-load`（`0 2 * * *`）、`dbt-weekly-build`（`30 2 * * 1`）、`dbt-hourly-freshness`（`0 * * * *`） |
| アラート | 上記 3 ジョブの `run.googleapis.com/job/completed_execution_count{result=failed}` を監視する Cloud Monitoring email アラートポリシー |
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
  [`dags/`](../dags/) と Airflow ベースのルート `Dockerfile` 配下。
  [`images/jp/`](../images/jp/) のダイアグラムはこの構成を反映しています。
- **v2（現行）**：GCP ネイティブ。
  - PR #2 — BigQuery に bronze 層（`weather_raw.*`）を導入。一括ロード + 日次 MERGE。
  - PR #3 — BigQuery 向け dbt 書き換え、3 つの Cloud Run Job（bronze daily / dbt weekly / dbt freshness hourly）+ Cloud Scheduler トリガー、GHA CI/CD。
  - PR #4 — Cloud Run Job 実行失敗を検知する Cloud Monitoring email アラート。
  - PR #5 — PR #3 + PR #4 の全成果物を Terraform 化（[`terraform/`](../terraform/) の単一 root、state は `gs://weather-pipeline-tfstate`）。真実の単一情報源がシェルスクリプトから `terraform apply` に切り替わる。

## 今後の作業

- **Workload Identity Federation** で GitHub Actions の SA キー
  シークレット 2 本を置き換える（キー輪替の手間を排除）。
- **GCS lifecycle policy** をクローラーのバケットに追加 —
  crawler の JSON は無制限に蓄積する；Nearline → Coldline → 削除のティアリングを設定。
- **Webhook 通知チャンネル**（Discord / Slack / Pub-Sub）+ **freshness wrapper** で source ごとの詳細を構造化送信。Email チャンネルは粒度の細かい freshness ペイロードを表示できない。
- **dbt テストカバレッジの拡充** + PR CI に **sqlfluff** lint を追加。
- **Cloud Monitoring ダッシュボード**：パイプライン健全性可視化（Job 実行時間、BQ slot 消費、GCS オブジェクトの古さなど）。
- **Renovate / Dependabot** で dbt-core / dbt-bigquery / SDK / ベースイメージの自動更新。
- **BQ データ品質モニタリング**（dbt artifacts に
  [`elementary-data`](https://github.com/elementary-data/elementary)
  を被せるなど）。
- **prod 環境** — `terraform/envs/{staging,prod}/` に分割、`side-project-prod` を立ち上げ。
- **Terraform apply の GHA 化** + PR review ゲート（現状は `apply` がワークステーション操作）。
- **レガシーな Airflow / Snowflake 関連成果物の削除**（`dags/`、ルート
  `Dockerfile`、古いイメージ参照など）。
