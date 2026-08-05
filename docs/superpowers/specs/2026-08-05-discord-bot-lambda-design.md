# Discord bot を Lambda + Discord Interactions 構成へ作り直す

## 背景

現在の bot は `discord.py` の `on_message` でメッセージ本文を前方一致させる実装で、ローカル実行が前提になっている。3つの問題がある。

1. **常時可用でない。** bot の主目的は「停止しているサーバーを起動する」ことなので、実行環境が落ちていると起動手段そのものが失われる。ローカル PC 実行では PC を開いている人しかサーバーを起こせず、Palworld インスタンスへの同居はインスタンス停止中に bot も死ぬため成立しない。
2. **アクセス制御の穴が実装にある。** 参加パスワードを使わず Security Group の IP 許可を唯一のゲートにしたため、`register` の弱さがそのまま穴になる。入力を検証していないので `0.0.0.0/0` を渡せば全世界に開き、実行者の制限もなく、失敗しても成功と応答する。
3. **ドキュメントと実装が食い違っている。** README は `/palworld start` と書いているが、実装は Discord のスラッシュコマンドではない。

Lambda + Discord Interactions に作り直し、この3つをまとめて解消する。

## 決定事項

| 論点 | 決定 |
| --- | --- |
| 実行環境 | Lambda（Function URL で Discord の Webhook を受ける） |
| 応答方式 | 常に deferred（`type: 5`）で ACK し、処理後に follow-up |
| エンドポイント | Lambda Function URL、認証は `NONE`。正当性は Ed25519 署名検証で担保 |
| コマンド登録 | `deploy_commands.py` を人が実行する（Discord 側リソースに Terraform プロバイダがない） |
| 実行権限 | コマンド別に分けない。ギルドのメンバーは全員が全コマンドを実行できる |
| 登録済み IP の寿命 | 手動 `unregister` と一覧表示。自動失効は入れない |
| 対象インスタンス | 1台固定。インスタンス ID を環境変数で受け取り、タグ検索はしない |

## アーキテクチャ

```
Discord ──POST──> Lambda Function URL ──> webhook 関数
                                            │ ① Ed25519 署名検証
                                            │ ② worker を非同期 invoke
                                            └─> ③ deferred ACK (type 5) を即返す
                                                       │
                              worker 関数 <─────────────┘
                                │ ④ コマンド実行（EC2 / SG API）
                                └─> ⑤ Discord へ follow-up で結果を送信
```

Discord は 3 秒以内の ACK を要求する。EC2 の API 呼び出しは数百 ms なので処理してから `type: 4` で返す 1 関数構成も成立するが、コールドスタートを含めて超過したとき **操作は実行済みなのに Discord にはエラーが表示される** 失敗モードになる。deferred なら構造的に起きない。

deferred は HTTP レスポンスを返した時点で invocation が終わるため、関数を2つに分ける必要がある。zip は1つで、Terraform 側で handler の指す入口を変えた Lambda を2本作る。実行時の分岐ロジックは持たない。

follow-up の宛先に必要な `application_id` は interaction のペイロードに含まれるので、環境変数にしない。

ランタイムは Python 3.13 / arm64、メモリは 256MB。webhook のタイムアウトは 10 秒、worker は 30 秒。

Discord への follow-up は標準ライブラリの `urllib.request` で送る。`requests` を追加すると Lambda の zip に載る依存が増えるだけで、リクエストは1種類しかない。ただし Discord の前段にいる Cloudflare が `urllib` の既定 User-Agent を error 1010 で拒否するため、`User-Agent` を明示的に付ける必要がある。

## モジュール構成

```
bot/
├── pyproject.toml
├── src/palworld_bot/
│   ├── webhook.py       # Lambda#1 の入口。署名検証と deferred 応答だけを持つ
│   ├── worker.py        # Lambda#2 の入口。コマンドを実行し follow-up を送る
│   ├── interactions.py  # Discord Interactions プロトコル（署名検証・応答生成・follow-up 送信）
│   ├── commands.py      # サブコマンドのディスパッチと入力検証
│   ├── server.py        # EC2 インスタンスの起動・停止・状態取得
│   └── access.py        # Security Group の IP 許可の追加・削除・一覧
├── scripts/
│   ├── build.sh         # Lambda 用の依存を含むビルドディレクトリを作る
    └── deploy_commands.py  # スラッシュコマンド定義を Discord に登録
```

既存の `bot/aws.py` は EC2 のライフサイクル操作と Security Group 操作が同居しているため、扱うエンティティで `server.py` と `access.py` に割り直す。`bot/main.py` は役割が消えるので削除する。

`interactions.py` という名前は、PyPI の `discord.py` と紛らわしくならないよう避けた結果。

## コマンド仕様

`/palworld` 1つにサブコマンドを持たせる。

| サブコマンド | 引数 | 動作 |
| --- | --- | --- |
| `start` | なし | インスタンスを起動。既に `running` なら現状を返して何もしない |
| `stop` | なし | 停止。既に `stopped` なら現状を返して何もしない |
| `status` | なし | 状態と接続先アドレス（`running` のときのみアドレスを含む） |
| `register` | `ip`（必須） | その IP から 8211/udp への到達を許可 |
| `unregister` | `ip`（必須） | 許可を削除 |
| `allowlist` | なし | 許可済み IP の一覧 |

`pending` / `stopping` の途中は操作を受け付けず、現在の状態を返す。

Discord から自分のグローバル IP は取得できないため、`register` の引数は省略できない。

`allowlist` は Security Group のルールのうち 8211/udp のものだけを抽出して返す。既に許可済みの IP を `register` した場合と、許可されていない IP を `unregister` した場合は、いずれも変更を加えずその旨を返す。

### 入力検証

`register` / `unregister` は `ipaddress` モジュールで解析し、次を満たさないものは理由を添えて拒否する。

- IPv4 であること
- プレフィックス長が `/32` であること（`0.0.0.0/0` はこの条件で構造的に弾かれる）
- グローバルアドレスであること（private / loopback / link-local / reserved / multicast を拒否）

`192.0.2.10` のようにプレフィックスなしで渡された場合は `/32` として扱う。

## IAM とシークレット

`.env` の AWS アクセスキーは廃止し、Lambda の実行ロールに置き換える。

両関数に CloudWatch Logs への書き込み（`AWSLambdaBasicExecutionRole` 相当）を与える。それ以外は、webhook 関数は worker への `lambda:InvokeFunction` のみ。worker 関数は次だけを持つ。

| アクション | リソース |
| --- | --- |
| `ec2:StartInstances` / `ec2:StopInstances` | 対象インスタンスの ARN |
| `ec2:AuthorizeSecurityGroupIngress` / `ec2:RevokeSecurityGroupIngress` | 対象 Security Group の ARN |
| `ec2:DescribeInstances` / `ec2:DescribeInstanceStatus` / `ec2:DescribeSecurityGroups` | `*`（これらはリソース指定が効かない） |

環境変数はいずれも秘密情報ではなく、関数ごとに必要なものだけを渡す。

| 関数 | 環境変数 |
| --- | --- |
| webhook | `DISCORD_PUBLIC_KEY`（公開鍵なので秘密ではない）、`WORKER_FUNCTION_NAME` |
| worker | `INSTANCE_ID`、`SECURITY_GROUP_ID`、`GAME_PORT` |

`GAME_PORT` は Terraform の `var.game_port` を単一の出典にするために渡す。

Discord の Bot Token は実行時に使わない（follow-up は interaction token で認証する）。`deploy_commands.py` を実行する人の手元にだけ置く。`bot/.env.example` は同スクリプト用の `DISCORD_APPLICATION_ID` と `DISCORD_BOT_TOKEN` のみを残す。

## Terraform への追加

`infra/bot.tf` を新設し、Lambda 2本・Function URL・IAM ロール・環境変数を定義する。出力に Function URL を追加する。

bot 関連のリソースは `terraform.tfvars` の `discord_public_key` が未設定なら作らない。Discord アプリを登録する前にゲームサーバーだけを apply できるようにするため、および bot を作らない apply でビルド成果物を要求しないためである。

`var.server_version` は S3 のバックアップ接頭辞・SSM パラメータのパス・インスタンスの Name タグで使い続けるので残す。bot がインスタンス ID を直接受け取るようになるため、bot 側のタグ検索と `DEFAULT_VERSION` だけがなくなる。

## ビルドとデプロイ

Ed25519 の署名検証には PyNaCl が必要で、これはバイナリ依存である（標準ライブラリでは検証できず、暗号は自前実装しない）。macOS から Lambda 向けにクロス解決できることを確認済み。

```sh
uv pip install --python-platform aarch64-manylinux2014 --python-version 3.13 --target build/ pynacl
```

`_cffi_backend.cpython-313-aarch64-linux-gnu.so` を含めて 4.1MB。Lambda の zip 上限 50MB に対して余裕がある。

このビルドは Terraform の外に置く。`archive_file` は plan 時に評価されるため、`null_resource` + `local-exec` でビルドさせると、まだ存在しないディレクトリを zip しようとする順序問題を踏む。

デプロイ手順は3段になる。

1. `bot/scripts/build.sh` を実行し、`terraform apply`（Lambda が立ち、Function URL が出力される）
2. Discord Developer Portal の Interactions Endpoint URL にその URL を設定する。保存時に Discord が `PING` を投げるので、`PONG` を返せることが検証になる
3. `deploy_commands.py` を1回実行してスラッシュコマンドを登録する

## エラー処理

- 署名検証失敗 → `401` を本文なしで返す
- `type: 1`（PING）→ `type: 1`（PONG）。エンドポイント登録時の検証に必要
- worker の例外 → follow-up でユーザーに短い説明を返し、詳細は CloudWatch Logs に残す
- boto3 の `ClientError` → エラーコードとメッセージを整形して返す
- follow-up 自体の送信失敗 → ログのみ。ユーザー側には「考え中」の表示が残る。構造的に回復できないためリトライは入れない

## テスト

自動テストは作らない。コマンドの仕様が固まっており、ロジックを継続的に変更する予定がないため。動作確認は `terraform validate` と `plan`、ビルドスクリプトの実行、および署名付きの合成ペイロードでハンドラを直接叩くことで行う。

## 廃止するもの

- `bot/main.py`（`on_message` ベースの実装）
- `bot/aws.py`（`server.py` と `access.py` に分割）
- `bot/.env.example` の AWS アクセスキーと `DEFAULT_VERSION`
- `discord.py` への依存（Interactions は Webhook で受けるため Gateway 接続をしない）
- README のコマンド表と bot 起動手順（書き換え）

## 対象外

- 無人時の自動停止。プレイヤー数の取得に REST API の有効化が必要で、独立した変更になる
- 起動完了の通知。`start` の応答は「起動を開始した」までで、遊べる状態になるまでの追跡はしない
- 登録済み IP の自動失効
