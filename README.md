# palworld-server

Palworld 1.0 の専用サーバーを AWS 上で運用するためのリポジトリ。

| ディレクトリ | 役割 |
| --- | --- |
| `infra/` | Terraform。VPC / Security Group / EC2 / Elastic IP / セーブデータ用 S3 / IAM |
| `bot/` | Discord bot。EC2 の起動・停止・状態確認と、プレイヤー IP の Security Group 登録 |
| `docs/` | 手動構築手順（Terraform を使わない場合や、障害時の確認用） |

## 構成

- **OS**: Ubuntu 24.04 LTS（SteamCMD が 32bit バイナリのため、i386 パッケージが揃う Ubuntu を採用。Amazon Linux 2023 は i686 パッケージを提供していない）
- **インスタンス**: `m7i-flex.xlarge`（4 vCPU / 16 GiB）。公式推奨の 4 コア / 16 GB に合わせている
- **ストレージ**: gp3 60 GiB（サーバー本体 15 GB + セーブ + アップデート時の一時領域）。`delete_on_termination = false`
- **ポート**: 8211/udp のみ。RCON と REST API は使わないので無効（RCON は非推奨で将来削除される。REST API は必要になったら `RESTAPIEnabled` を有効化する）
- **アクセス制御**: 参加パスワードではなく Security Group の IP 許可で行う（`player_cidrs` と bot の `/palworld register`）。管理パスワードは未指定なら Terraform が生成して SSM に保存する
- **運用**: 毎日 05:00（サーバー時刻）に systemd timer がセーブを S3 へバックアップしてからサーバーを再起動する（稼働時間に比例してメモリ使用量が増え続けるため）

## infra のデプロイ

```sh
cd infra
cp terraform.tfvars.example terraform.tfvars   # サーバー名などを設定（必須項目はない）
terraform init
terraform apply
```

出力される値を bot の `.env` に設定する。

| 出力 | bot の環境変数 |
| --- | --- |
| `security_group_id` | `AWS_SECURITY_GROUP_ID` |
| `server_version`（変数） | `DEFAULT_VERSION` |
| `server_address` | プレイヤーへ案内する接続先 |

インスタンスには Session Manager で接続する（`ssh_cidrs` は既定で空）。

```sh
aws ssm start-session --target "$(terraform output -raw instance_id)"
```

`user_data` はインスタンスの初回起動時にのみ実行される。テンプレートを変更した場合は、インスタンスを作り直すか、対象の変更を手動で適用する。

## bot の起動

```sh
cd bot
cp .env.example .env   # TOKEN などを設定
uv sync
uv run main.py
```

### コマンド

| コマンド | 動作 |
| --- | --- |
| `/palworld start [version]` | EC2 を起動 |
| `/palworld stop [version]` | EC2 を停止 |
| `/palworld status [version]` | 状態と接続先アドレスを表示 |
| `/palworld register <ip>` | その IP から 8211/udp への接続を Security Group に許可 |

`version` を省略すると `DEFAULT_VERSION` が使われ、`palworld-server-<version>` という Name タグのインスタンスを操作する。

## サーバーの運用

インスタンス上での操作:

```sh
sudo systemctl status palworld            # 稼働状況
sudo journalctl -u palworld -f            # ログ
sudo /usr/local/bin/palworld-maintenance  # 手動でバックアップ + 再起動
```

管理パスワードの確認。ゲーム内で `/AdminPassword <pw>` を実行すると `/Shutdown` `/Broadcast` `/KickPlayer` `/BanPlayer` `/Save` が使える。

```sh
aws ssm get-parameter --name "$(terraform output -raw server_secrets_parameter)" \
  --with-decryption --query Parameter.Value --output text
```

- 設定ファイル: `/home/palworld/PalServer/Pal/Saved/Config/LinuxServer/PalWorldSettings.ini`
- セーブデータ: `/home/palworld/PalServer/Pal/Saved/SaveGames/0/<world-id>/`
- バックアップ: `s3://palworld-saves-<account-id>/saves/<version>/`（30 日で失効）
- ゲーム本体の更新は `palworld.service` の `ExecStartPre` が起動ごとに `app_update` を実行するため、bot で stop → start すれば取り込まれる
