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
                                     │ + 日次 MERGE（Scheduled Query）
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
| [`infra/bq/`](../infra/bq/) | Bronze 層：スキーマファイル + 一括ロードと日次 MERGE のシェルスクリプト |
| [`weather_data_dbt/`](../weather_data_dbt/) | dbt プロジェクト（BigQuery プロファイル、dev / stg / prod / ci ターゲット） |
| [`infra/dbt/`](../infra/dbt/) | 2 つの Cloud Run Job（`dbt-weekly-build`、`dbt-hourly-freshness`）用の Dockerfile + スクリプト |
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
| オーケストレーション | Cloud Run Jobs + Cloud Scheduler（bronze MERGE は BQ Scheduled Query） |
| CI/CD | GitHub Actions（サービスアカウント JSON キー認証；WIF への移行手順をドキュメント化済み） |

## 環境

データセット単位で隔離された 3 つの dbt ターゲット：

| ターゲット | 用途 | データセット |
|---|---|---|
| `dev` | ローカル開発（`gcloud auth application-default login`） | `weather_dev_{staging,intermediate,marts}` |
| `ci` | GitHub Actions による PR 検証 | `weather_ci_{staging,intermediate,marts}`（毎回再構築、bronze の直近 7 日分のサブサンプル） |
| `stg` | 日次 Cloud Run Job（現在の真実の単一情報源） | `weather_{staging,intermediate,marts}` |
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
- **v2（現行）**：GCP ネイティブ。Bronze は PR #2 で導入、BigQuery 向け
  dbt 書き換え + Cloud Run Jobs + GHA CI/CD は PR #3 で導入。

## 今後の作業

[`docs/pr_desc.md`](../docs/pr_desc.md) の「What is NOT in this PR」で
追跡されています：

- SA / IAM / Artifact Registry / Cloud Run Jobs / Scheduler の Terraform 化
- Cloud Scheduler トリガー（現状は [`infra/dbt/README.md`](../infra/dbt/README.md)
  に gcloud コマンドとして記載）
- `infra/bq/daily_load.sql` 用の BQ Scheduled Query の設定
- 障害アラート（freshness wrapper + Cloud Monitoring + Discord/Slack webhook）
- GitHub Actions の Workload Identity Federation 移行
- レガシーな Airflow / Snowflake 関連成果物の削除
