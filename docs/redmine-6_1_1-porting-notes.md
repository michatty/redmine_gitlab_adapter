# Redmine 6.1.1 対応（Rails 7 系）移植メモ: redmine_gitlab_adapter

## 概要
本リポジトリの `redmine_gitlab_adapter` は、Redmine 3.x〜4.x 向けとして公開されていた GitLab SCM アダプタ系プラグインを、Redmine 6.1.1（Rails 7 系）で動作するように修正したものです。

本ドキュメントは、移植の背景・主要な修正点・検証内容を、後から再現/レビューできる形でまとめたものです。

## 対象・前提
- 対象 Redmine: 6.1.1
- Rails: 7 系（Redmine 6 の前提）
- GitLab: Self-managed を想定（GitLab REST API v4）
- 認証: Personal Access Token（PAT）
- 互換性方針: **Redmine 3.x〜4.x との後方互換は目的にしない**（6.1.1 で動くことを優先）

## 主要な修正点（要約）

### 1) Rails 7 の読み込み方式に合わせたロード/パッチ適用
Redmine 6（Rails 7）では、プラグインの `lib/` を前提にした require や、古いスタイルの include が期待通りに動かないケースがあります。

対応として以下を実施しました。
- `init.rb` で `ActiveSupport::Reloader.to_prepare`（無い場合は `Rails.application.config.to_prepare`）を使い、`RepositoriesHelper` へパッチを確実に include
- `app/models/repository/gitlab.rb` で、アダプタ require を **絶対パス** に変更（LoadError 回避）

関連ファイル:
- `init.rb`
- `lib/gitlab_repositories_helper_patch.rb`
- `app/models/repository/gitlab.rb`

### 2) GitLab クライアントの設定をグローバルからインスタンスへ
旧実装では `Gitlab.endpoint` / `Gitlab.private_token` のような **グローバル設定**に依存していると、複数リポジトリを扱う場面や Rails のリローダと相性が悪いことがあります。

対応として以下を実施しました。
- `Gitlab.client(...)` を使い、アダプタ生成時に `@client` を作成
- 以降の API 呼び出しは `@client.*` に統一

関連ファイル:
- `lib/redmine/scm/adapters/gitlab_adapter.rb`

### 3) `gitlab` gem の更新
Redmine 6.x 環境（Ruby 3.2+）での動作安定性を優先し、依存 gem を更新しました。

- `Gemfile`: `gem "gitlab", "~> 6.1"`

### 4) プロキシ対応（環境変数ベース）
企業ネットワーク等でプロキシが必要な環境を考慮し、HTTP クライアントにプロキシ設定を渡すようにしました。

- `http_proxy` / `https_proxy` / `no_proxy`（大文字も許容）を参照
- `no_proxy` は `example.com` または `.example.com` 形式の簡易マッチを実装

関連ファイル:
- `lib/redmine/scm/adapters/gitlab_adapter.rb`

### 5) default branch 名の扱いの修正
GitLab のデフォルトブランチが `main` のケースを想定し、デフォルトブランチ候補を `main/master` として扱います。

関連ファイル:
- `lib/redmine/scm/adapters/gitlab_adapter.rb`

## 動作確認（実施内容）

### UI での確認
- 管理 → 設定 → リポジトリ で SCM に `Gitlab` が表示される
- プロジェクト → 設定 → リポジトリ で Gitlab リポジトリの作成ができる
- ブランチ選択で `main` / 追加ブランチが選択できる
- タグ一覧が取得できる

### API 経由のスモークテスト
登録済みリポジトリに対して、以下が nil にならずに取得できることを確認しました。
- branches/tags
- revisions
- diff
- cat（ファイル内容取得）
- annotate（blame）

※ スモークテストは Rails runner による簡易スクリプトで実施（運用環境ではログ/権限/ネットワーク条件に合わせて実施してください）。

## デプロイ/インストール時の注意
- プラグイン配置は `REDMINE_ROOT/plugins/redmine_gitlab_adapter/`（二重ディレクトリに注意）
- 依存 gem の取得が必要なため、インターネット接続がある環境では `bundle install` のみで基本OK
  - `bundle update` は依存全体が動くリスクがあるため、原則として不要（必要なら `bundle update gitlab` 等の限定更新を検討）
- 反映後は `bundle exec rake redmine:plugins:migrate RAILS_ENV=production` を実行し、アプリサーバを再起動

## 社内向け運用ルール（記述テンプレートと例）

この章は「社内の運用要件に合わせて、誰が読んでも同じ手順・同じ判断になる」ことを目的に、運用ルールの書き方をテンプレート化したものです。

### 適用先環境（記述例）
- OS: Ubuntu Server 22.04.5 LTS
- Redmine: 6.1.1
- 起動方式: systemd（`redmine.service` から Puma を起動）
- GitLab URL（例・マスク済み）: `http://host1.foo.co.jp/gitlab/`
- プロキシ: 必須（`/etc/profile.d/proxy.sh` と `/etc/apt/apt.conf` の適用が社内ルール）

### プロキシ運用（重要ポイント）

#### 1) systemd サービスにプロキシ環境変数を渡す
`/etc/profile.d/proxy.sh` は主にログインシェル向けであり、**systemd サービスには自動では反映されません**。
本プラグインの GitLab API 通信（`http_proxy` / `https_proxy` / `no_proxy` 参照）を確実にプロキシ配下で動かすため、`redmine.service` に環境変数を渡す運用を明記してください。

本環境では **EnvironmentFile 方式を採用**します（`/etc/default/redmine` にまとめて定義し、systemd から読み込む）。

記述例（採用方式）:

1) EnvironmentFile を読み込む drop-in を作成

- `/etc/systemd/system/redmine.service.d/env.conf`

```ini
[Service]
EnvironmentFile=/etc/default/redmine
```

2) `/etc/default/redmine` に proxy 変数を定義（例・マスク済み）

```bash
HTTP_PROXY=http://proxy.foo.co.jp:8080
HTTPS_PROXY=https://proxy.foo.co.jp:8080
http_proxy=http://proxy.foo.co.jp:8080
https_proxy=https://proxy.foo.co.jp:8080
NO_PROXY=127.0.0.1,localhost,.foo.co.jp
no_proxy=127.0.0.1,localhost,.foo.co.jp
```

推奨パーミッション（秘匿値を含むため）:

```bash
sudo chown root:root /etc/default/redmine
sudo chmod 600 /etc/default/redmine
```

補足:
- `EnvironmentFile` は systemd（root）が読み取り、プロセス環境へ展開するため、実行ユーザー（例: `www-data`）がファイル自体を読めなくても動作します。

反映手順（例）:

```bash
sudo systemctl daemon-reload
sudo systemctl restart redmine
sudo systemctl status redmine
```

### systemd（Puma 起動）運用の記述例

適用先の Redmine が systemd（`redmine.service`）で Puma 起動される場合、社内向け手順書では「どのユーザーで」「どの環境変数を」「どこから読み込むか」を明示すると事故が減ります。

#### 例: `redmine.service`（抜粋・マスク済み）

以下のようなユニット構成で運用されるケースを想定します（`systemctl cat redmine` 相当）。

```ini
[Service]
User=www-data
Group=www-data
WorkingDirectory=/var/lib/redmine

Environment=RAILS_ENV=production
Environment=RAILS_RELATIVE_URL_ROOT=/redmine
Environment=RBENV_ROOT=/var/www/.rbenv
Environment=PATH=/var/www/.rbenv/bin:/var/www/.rbenv/shims:/usr/local/bin:/usr/bin:/bin
Environment=SECRET_KEY_BASE=*****

ExecStart=/bin/bash -lc 'bundle exec puma -C config/puma.rb'
Restart=always
```

#### 推奨: 秘密情報やプロキシは EnvironmentFile に分離（採用方式）

社内向けには、以下のように「本体ユニットは最小」「環境差分は drop-in や EnvironmentFile」に分ける書き方が扱いやすいです。

- 理由:
  - `SECRET_KEY_BASE` のような秘匿値をユニットファイルに直書きすると、閲覧範囲や変更履歴の管理が難しくなります
  - プロキシ値は環境ごとの差分になりやすく、ユニット直編集だと手戻りが増えます

記述例（採用方式: EnvironmentFile）:

- `/etc/systemd/system/redmine.service.d/env.conf`

```ini
[Service]
EnvironmentFile=/etc/default/redmine
```

- `/etc/default/redmine`（例・マスク済み）

```bash
SECRET_KEY_BASE=*****

HTTP_PROXY=http://proxy.foo.co.jp:8080
HTTPS_PROXY=https://proxy.foo.co.jp:8080
http_proxy=http://proxy.foo.co.jp:8080
https_proxy=https://proxy.foo.co.jp:8080
NO_PROXY=127.0.0.1,localhost,.foo.co.jp
no_proxy=127.0.0.1,localhost,.foo.co.jp
```

推奨パーミッション（秘匿値を含むため）:

```bash
sudo chown root:root /etc/default/redmine
sudo chmod 600 /etc/default/redmine
```

反映手順:

```bash
sudo systemctl daemon-reload
sudo systemctl restart redmine
```

参考（採用しない方式）:
- `Environment="HTTP_PROXY=..."` をユニットや drop-in に直書きする方式も可能ですが、本環境では値の一元管理のため EnvironmentFile 方式に統一します。

#### 重要: `/etc/profile.d/proxy.sh` だけでは不足し得る

`/etc/profile.d/proxy.sh` はログインシェルで読み込まれる想定のため、systemd サービスの環境変数としては別途設定が必要です。
社内ルールで `/etc/profile.d/proxy.sh` の配布が義務であっても、Redmine（systemd）には上記のような drop-in / EnvironmentFile を併記する運用が安全です。

#### 2) `no_proxy` の考え方
- `no_proxy`（例: `127.0.0.1,localhost,.foo.co.jp`）により、社内ドメイン宛てがプロキシを経由しない構成もあり得ます。
- 本プラグインは `no_proxy` を参照してプロキシを無効化します。GitLab が社内ドメインで直接疎通できる構成の場合、`no_proxy` を適切に設定しておくと、意図しないプロキシ経由を避けられます。

### GitLab の URL / root_url の社内ルール（記述例）

GitLab を相対 URL（例: `/gitlab`）配下で運用している場合、`root_url` を含めて明示する運用を推奨します。

例:
- `root_url`: `http://host1.foo.co.jp/gitlab`
- `url`（プロジェクトURL）: `http://host1.foo.co.jp/gitlab/<namespace>/<project>.git`

本プラグインは `root_url + '/api/v4'` を API エンドポイントとして使用します（この例だと `http://host1.foo.co.jp/gitlab/api/v4`）。

### PAT（Personal Access Token）運用ルール（記述例）

PAT は実質的にパスワードと同等の秘匿情報です。Redmine 側の「API Token（パスワード欄）」に登録する前提で、取り扱いルールを明文化してください。

記述例:
- 発行者: GitLab 側の管理者（例: `root` または運用用サービスユーザー）
- スコープ: 原則最小（ただし初回の動作確認は `api` で行い、問題なければ段階的に絞る）
- 有効期限: 無期限を避け、例: 90 日ごとの更新
- 保管: チケット/メール本文へ直貼り禁止。パスワード管理ツール等で管理
- ローテーション: 更新時は Redmine 側の設定変更とセットで実施（作業手順に含める）
- 失効/漏洩時対応: GitLab で即 revoke → Redmine 側の token 更新 → 動作確認 → 事後報告

### 変更作業ルール（記述例）

記述例（最低限）:
- 変更単位: 「プラグイン ZIP 1本 + 手順書 1本」を1セットとして管理する
- 事前確認: 適用前に `bundle exec rake redmine:plugins RAILS_ENV=production` が通ること
- 適用手順:
  1. Redmine 停止（`sudo systemctl stop redmine`）
  2. プラグイン差し替え（旧版を退避してから展開）
  3. `bundle install`（必要なら `--without development test`）
  4. `bundle exec rake redmine:plugins:migrate RAILS_ENV=production`
  5. Redmine 起動（`sudo systemctl start redmine`）
  6. 管理画面の確認（リポジトリ設定に `Gitlab` が出ること、対象プロジェクトで参照できること）
- ロールバック手順:
  1. Redmine 停止
  2. 退避した旧版プラグインへ戻す
  3. `bundle install`
  4. Redmine 起動

### 障害時の一次切り分け（記述例）

- ログ: `REDMINE_ROOT/log/production.log` を最優先で確認
- よくある原因:
  - `LoadError`: プラグイン配置の二重ディレクトリ、または権限不足
  - `Bundler::GemNotFound`: `bundle install` 未実施、または bundle 実行ユーザー/パス不一致
  - プロキシ起因の疎通失敗: systemd 環境変数が未設定（`/etc/profile.d/proxy.sh` だけでは不足）

### 定期点検（記述例）
- PAT の期限監視と更新（例: 月次）
- GitLab 側の API レート/権限変更の影響確認（GitLab アップデート後）

## 既知の制約 / 今後の改善案
- 大規模リポジトリでの差分/履歴取得は GitLab API の応答サイズやページングで時間がかかる可能性があります（パフォーマンス改善余地）
- スコープ最小の PAT（read-only）で運用する場合、必要 API の権限を再確認する必要があります（まずは `api` で動作確認するのが簡便）

## パフォーマンス（運用メモ）

### なぜ Redmine 経由だと遅くなりやすいか
本プラグインは GitLab の REST API を使って「ツリー表示」「履歴」「diff」「blame」等を取得します。GitLab の WebUI は内部的に最適化（キャッシュ・バッチ処理等）されているため、同じ操作でも体感が速いことがあります。

Redmine 側の表示が遅い場合、主な要因は「ディレクトリ表示時に API を大量に呼んでしまう（ファイル数に比例して遅くなる）」です。

### 運用上の推奨

- `report_last_commit` を大規模リポジトリで常時 ON にしない
  - ON にすると、ファイル一覧の各エントリごとに最終コミット取得が必要になり、遅くなりやすいです。

### ファイルサイズ取得（デフォルトOFF）

ファイル一覧の「サイズ」を出すためにファイルごとの追加 API 呼び出しを行うと、リポジトリ規模によっては表示が大きく遅くなります。
そのため、本 fork ではファイルサイズ取得を **デフォルトで無効化**し、必要な環境のみ環境変数で有効化できるようにしています。

- 有効化する場合:

```bash
export REDMINE_GITLAB_ADAPTER_FETCH_FILE_SIZE=true
```

systemd 運用（EnvironmentFile 方式）の場合は `/etc/default/redmine` に追加します。

### 大量ファイルのディレクトリ表示（tree API の並列ページ取得）

ディレクトリ直下に多数のファイルがある場合、GitLab API の `tree` はページングされます（`per_page` 上限の影響）。
プロキシ配下などで 1 リクエストあたりのレイテンシが大きいと、ページを直列に取得するだけで表示が遅くなります。

本 fork では、`tree` の複数ページ取得を **並列化**して待ち時間を短縮します（デフォルト有効）。

- 並列化の有効/無効:

```bash
export REDMINE_GITLAB_ADAPTER_PARALLEL_TREE_PAGES=true
```

- 並列スレッド数（デフォルト: 4、上限: 8）:

```bash
export REDMINE_GITLAB_ADAPTER_PARALLEL_TREE_THREADS=4
```

注意:
- GitLab 側に同時リクエストが増えるため、環境によっては負荷やレート制限の影響を受ける可能性があります。問題が出る場合は `...PARALLEL_TREE_PAGES=false` またはスレッド数を下げてください。
