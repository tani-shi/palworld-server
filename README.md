# palworld-server

Palworld 1.0 の専用サーバーを AWS 上で運用するためのリポジトリ。

| ディレクトリ | 役割 |
| --- | --- |
| `infra/` | Terraform。VPC / Security Group / EC2 / Elastic IP / セーブデータ用 S3 / IAM |
| `bot/` | Discord bot（Lambda）。EC2 の起動・停止・状態確認と、プレイヤー IP の Security Group 登録 |
| `docs/` | 手動構築手順（Terraform を使わない場合や、障害時の確認用） |

## 構成

- **OS**: Ubuntu 24.04 LTS（SteamCMD が 32bit バイナリのため、i386 パッケージが揃う Ubuntu を採用。Amazon Linux 2023 は i686 パッケージを提供していない）
- **インスタンス**: `m7i-flex.xlarge`（4 vCPU / 16 GiB）。公式推奨の 4 コア / 16 GB に合わせている
- **ストレージ**: gp3 60 GiB（サーバー本体 15 GB + セーブ + アップデート時の一時領域）。ルートボリュームはインスタンスと一緒に破棄する。置き換え後のインスタンスは古いボリュームを読まないので残しても孤児になるだけで、セーブの継続性は S3 からの復元で確保する
- **ポート**: 8211/udp のみ。RCON と REST API は使わないので無効（RCON は非推奨で将来削除される。REST API は必要になったら `RESTAPIEnabled` を有効化する）
- **アクセス制御**: 参加パスワードではなく Security Group の IP 許可で行う（`player_cidrs` と bot の `/palworld register`）。管理パスワードは未指定なら Terraform が生成して SSM に保存する
- **運用**: 毎日 05:00（サーバー時刻）に systemd timer がセーブを S3 へバックアップしてからサーバーを再起動する（稼働時間に比例してメモリ使用量が増え続けるため）
- **セーブの継続性**: インスタンス作り直し時に、`user_data` が S3 の最新アーカイブを展開してから起動する。巻き戻りは最後のバックアップまで（最大 1 日）。アーカイブが無ければ新規ワールドになる

## infra のデプロイ

```sh
cd infra
cp terraform.tfvars.example terraform.tfvars   # サーバー名などを設定（必須項目はない）
terraform init
terraform apply
```

`server_address` の出力をプレイヤーへの接続先として案内する。bot が必要とする値は Terraform が Lambda の環境変数へ直接渡すので、手で写す設定はない。

インスタンスには Session Manager で接続する（`ssh_cidrs` は既定で空）。

```sh
aws ssm start-session --region "$(terraform output -raw aws_region)" \
  --target "$(terraform output -raw instance_id)"
```

`--region` は省略できない。省略すると `~/.aws/config` の既定リージョンに問い合わせ、そこにインスタンスが無いため `TargetNotConnected` になる（SSM は「存在しない」と「接続されていない」を区別しない）。

`user_data` はインスタンスの初回起動時にのみ実行される。テンプレートを変更した場合は、インスタンスを作り直すか、対象の変更を手動で適用する。

## bot のデプロイ

bot は Discord のスラッシュコマンドを Lambda で受ける。常駐プロセスはなく、AWS の認証情報も実行ロールに任せるので手元に置く鍵はない。

Discord Developer Portal でアプリケーションを作り、**Public Key** を `infra/terraform.tfvars` の `discord_public_key` に設定してから次を実行する。

```sh
bot/scripts/build.sh   # Lambda 用の zip 素材を作る
cd infra && terraform apply
```

`discord_public_key` が未設定の間は bot のリソースが作られないので、Discord アプリを用意する前にゲームサーバーだけを apply できる。

apply 後、出力された `bot_webhook_url` を Discord Developer Portal の **Interactions Endpoint URL** に設定する。保存時に Discord が検証リクエストを送るので、ここで疎通が確認できる。

最後にスラッシュコマンドを登録する。この操作にだけ Bot Token が必要で、AWS 上には保存しない。

```sh
cd bot
cp .env.example .env   # DISCORD_APPLICATION_ID と DISCORD_BOT_TOKEN を設定
uv run --env-file .env scripts/deploy_commands.py
```

`bot/src/palworld_bot/` を変更したときは `build.sh` → `terraform apply` を再実行する。コマンドの定義（名前・引数・説明）を変えたときだけ `deploy_commands.py` も実行する。

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

## サーバーの運用

インスタンス上での操作:

```sh
sudo systemctl status palworld            # 稼働状況
sudo journalctl -u palworld -f            # ログ
sudo /usr/local/bin/palworld-maintenance  # 手動でバックアップ + 再起動
```

管理パスワードの確認。ゲーム内で `/AdminPassword <pw>` を実行すると `/Shutdown` `/Broadcast` `/KickPlayer` `/BanPlayer` `/Save` が使える。

```sh
aws ssm get-parameter --region "$(terraform output -raw aws_region)" \
  --name "$(terraform output -raw server_secrets_parameter)" \
  --with-decryption --query Parameter.Value --output text
```

- 設定ファイル: `/home/palworld/PalServer/Pal/Saved/Config/LinuxServer/PalWorldSettings.ini`
- セーブデータ: `/home/palworld/PalServer/Pal/Saved/SaveGames/0/<world-id>/`
- バックアップ: `s3://palworld-saves-<account-id>/saves/<version>/`（30 日で失効）
- ゲーム本体の更新は `palworld.service` の `ExecStartPre` が起動ごとに `app_update` を実行するため、bot で stop → start すれば取り込まれる
