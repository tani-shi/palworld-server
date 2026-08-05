# palworld-server

Palworld 1.0 の専用サーバーを AWS 上で運用するためのリポジトリ。

| ディレクトリ | 役割 |
| --- | --- |
| `infra/` | Terraform。VPC / Security Group / EC2 / Elastic IP / スナップショット（DLM）/ IAM |
| `bot/` | Discord bot（Lambda）。EC2 の起動・停止・状態確認と、プレイヤー IP の Security Group 登録 |
| `docs/` | 手動構築手順（Terraform を使わない場合や、障害時の確認用） |

運用操作は `make help` に一覧がある。リージョン・インスタンス ID・SG ID などは Terraform の state から引くので、手で渡す値はない。

## 構成

- **OS**: Ubuntu 24.04 LTS（SteamCMD が 32bit バイナリのため、i386 パッケージが揃う Ubuntu を採用。Amazon Linux 2023 は i686 パッケージを提供していない）
- **インスタンス**: `m7i-flex.xlarge`（4 vCPU / 16 GiB）。公式推奨の 4 コア / 16 GB に合わせている
- **ストレージ**: gp3 60 GiB（サーバー本体 15 GB + セーブ + アップデート時の一時領域）。**ワールドの唯一のコピーがこのボリュームにある**ため、インスタンスを終了してもボリュームは残る（`DeleteOnTermination=false`）
- **ポート**: 8211/udp と 27015/udp。RCON と REST API は使わないので無効（RCON は非推奨で将来削除される。REST API は必要になったら `RESTAPIEnabled` を有効化する）
- **アクセス制御**: 参加パスワードではなく Security Group の IP 許可で行う。ルールの入口は bot の `/palworld register` だけで、Terraform は ingress を 1 つも宣言しない（同じ許可リストが 2 箇所にあると食い違うため）
- **運用は手動**: 定期的に動くものはスナップショットだけ。起動・停止・更新はすべて人が明示的に行う
- **セーブの保全**: DLM が日次でインスタンスのスナップショットを取る（JST 04:00、7 世代）。取得・ローテーション・失効はすべて AWS 側の機構で、こちら側にスクリプトは無い

## infra のデプロイ

`infra/terraform.tfvars.example` を `terraform.tfvars` に写してサーバー名などを設定する（必須項目はない）。あとは `make init` と `make apply`。

`server_address` の出力をプレイヤーへの接続先として案内する。bot が必要とする値は Terraform が Lambda の環境変数へ直接渡すので、手で写す設定はない。

インスタンスには SSH ではなく Session Manager で入る（`make session`）。

### インスタンスは作り直さない

このインスタンスのディスクにワールドの唯一のコピーがある。壊れたら作り直すのではなく、作り直せないものとして扱う。置き換えは 3 重に止めてある。

| 守り | 効く範囲 |
| --- | --- |
| `DisableApiTermination` | AWS 全体。コンソール・CLI・API のどこからも terminate できない |
| `lifecycle { prevent_destroy }` | Terraform。destroy と置き換えを要求する plan はエラーで停止する |
| `lifecycle { ignore_changes = [ami, user_data] }` | AMI が更新されても、`user_data` を編集しても plan に差分が出ない |

この結果 `user_data` の変更は現インスタンスに反映されない。**`user_data` は「作り直すならこう作る」という記録**であり、稼働中の変更手段ではない。実機を変えるときは `make session` で入って手で変える。手順は [docs/setup-ec2.md](docs/setup-ec2.md) にある。

作り直しが本当に必要になったときは、既存ボリュームを切り離してから新インスタンスに付け替える。`prevent_destroy` を外して `apply` するのではない。

## bot のデプロイ

bot は Discord のスラッシュコマンドを Lambda で受ける。常駐プロセスはなく、AWS の認証情報も実行ロールに任せるので手元に置く鍵はない。

1. Discord Developer Portal でアプリケーションを作り、**Public Key** を `infra/terraform.tfvars` の `discord_public_key` に設定する。未設定の間は bot のリソースが作られないので、Discord アプリを用意する前にゲームサーバーだけを apply できる
2. `make bot` でビルドとデプロイを行う
3. 出力された `bot_webhook_url` を Discord Developer Portal の **Interactions Endpoint URL** に設定する。保存時に Discord が検証リクエストを送るので、ここで疎通が確認できる
4. `bot/.env.example` を `.env` に写して `DISCORD_APPLICATION_ID` と `DISCORD_BOT_TOKEN` を設定し、`make bot-commands` でスラッシュコマンドを登録する。Bot Token が必要なのはこの操作だけで、AWS 上には保存しない

コマンドの定義（名前・引数・説明）を変えたときだけ `make bot-commands` を再実行する。

### コマンド

| コマンド | 動作 |
| --- | --- |
| `/palworld start` | EC2 を起動 |
| `/palworld stop` | EC2 を停止 |
| `/palworld status` | 状態・ヘルスチェック・接続先アドレスを表示 |
| `/palworld register <ip>` | その IP から 8211/udp への接続を Security Group に許可 |
| `/palworld unregister <ip>` | 許可を取り消す |
| `/palworld allowlist` | 許可済みの IP を一覧表示 |

権限による制限はなく、ギルドのメンバーは全員が実行できる。`register` に渡せるのはグローバルな IPv4 の単一アドレス（`/32`）だけで、範囲指定・プライベートアドレス・IPv6 は拒否される。自分のアドレスは <https://checkip.amazonaws.com> などで調べる。

Discord が使えないときは `make start` / `make stop` / `make allow IP=...` が同じことをする。

## サーバーの運用

`running` かつヘルスチェックが `ok/ok` でも、ゲームサーバーの状態は何も意味しない。`/palworld status` と `make status` も同じ限界を持つ。実際に遊べるかを確かめる手段はクライアントで接続することだけ。

**遊び終わったら停止する。** メモリ使用量が稼働時間に比例して増え続け、連続稼働では 5〜7 日で OOM する。定期再起動を持たないのは、停止するのが前提だから。

管理パスワードは `make password` で読む。ゲーム内で `/AdminPassword <pw>` を実行すると `/Shutdown` `/Broadcast` `/KickPlayer` `/BanPlayer` `/Save` が使える。

- 設定ファイル: `/home/palworld/PalServer/Pal/Saved/Config/LinuxServer/PalWorldSettings.ini`
- セーブデータ: `/home/palworld/PalServer/Pal/Saved/SaveGames/0/<world-id>/`
- ゲーム本体の更新は `palworld.service` の `ExecStartPre` が起動ごとに `app_update` を実行するため、stop → start すれば取り込まれる。クライアントにパッチが来た直後はこれが必要になる

## セーブの復元

現ボリュームを壊さない形で行う。スナップショットから別のボリュームを作り、中身を確認してから、必要なワールドだけを移す。

```sh
make snapshots                        # どのスナップショットから戻すか決める
make restore-attach SNAP=snap-xxxx    # クローンを作って読み取り専用でマウントする
make restore-list                     # 中にあるワールドを見る
make restore-world WORLD=54A0...      # ひとつだけ現行の SaveGames へ移す
make restore-clean                    # クローンを外して削除する
```

`restore-world` は上書きせず、現行のワールドを `<world-id>.replaced-<timestamp>` に退避してから置く。戻したい場合はこのディレクトリを戻せばよい。

`restore-attach` はインスタンスが停止していると実行を拒否する。クローンはルートボリュームのコピーなのでファイルシステム UUID が同一で、停止中にアタッチすると次の起動でクローンを root として掴む可能性がある。

### 更新せずに起動する

`ExecStartPre` はセーブに触らない（`app_update ... validate` は depot の既知ファイルだけを検証・修復し、`Pal/Saved` は残る）ので、上のセーブ復元と競合しない。

ゲーム本体の更新が原因で壊れた場合は、起動するたびに同じ版へ上げ直されるため切り分けられない。`make no-update` で `app_update` を止め、`make no-update-off` で戻す。

ただしこれで戻せるのはワールドだけで、**ゲーム本体の版は戻せない**。Palworld の dedicated server は anonymous depot で最新ビルドしか配っておらず、`app_update` に版を指定する手段がない。スナップショットの有無とは無関係の制約。
