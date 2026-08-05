# palworld-server

Palworld 1.0 の専用サーバーを AWS 上で運用するためのリポジトリ。

| ディレクトリ | 役割 |
| --- | --- |
| `infra/` | Terraform。VPC / Security Group / EC2 / Elastic IP / スナップショット（DLM）/ IAM |
| `bot/` | Discord bot（Lambda）。EC2 の起動・停止・状態確認と、プレイヤー IP の Security Group 登録 |
| `docs/` | 手動構築手順（Terraform を使わない場合や、障害時の確認用） |

## 構成

- **OS**: Ubuntu 24.04 LTS（SteamCMD が 32bit バイナリのため、i386 パッケージが揃う Ubuntu を採用。Amazon Linux 2023 は i686 パッケージを提供していない）
- **インスタンス**: `m7i-flex.xlarge`（4 vCPU / 16 GiB）。公式推奨の 4 コア / 16 GB に合わせている
- **ストレージ**: gp3 60 GiB（サーバー本体 15 GB + セーブ + アップデート時の一時領域）。**ワールドの唯一のコピーがこのボリュームにある**ため、インスタンスを終了してもボリュームは残る（`DeleteOnTermination=false`）
- **ポート**: 8211/udp と 27015/udp。RCON と REST API は使わないので無効（RCON は非推奨で将来削除される。REST API は必要になったら `RESTAPIEnabled` を有効化する）
- **アクセス制御**: 参加パスワードではなく Security Group の IP 許可で行う。ルールの入口は bot の `/palworld register` だけで、Terraform は ingress を 1 つも宣言しない（同じ許可リストが 2 箇所にあると食い違うため）。管理パスワードは Terraform が生成して SSM に保存する
- **運用は手動**: 定期的に動くものはスナップショットだけ。起動・停止・更新はすべて人が明示的に行う
- **セーブの保全**: DLM が日次でインスタンスのスナップショットを取る（JST 04:00、7 世代）。取得・ローテーション・失効はすべて AWS 側の機構で、こちら側にスクリプトは無い

## infra のデプロイ

```sh
cd infra
cp terraform.tfvars.example terraform.tfvars   # サーバー名などを設定（必須項目はない）
terraform init
terraform apply
```

`server_address` の出力をプレイヤーへの接続先として案内する。bot が必要とする値は Terraform が Lambda の環境変数へ直接渡すので、手で写す設定はない。

インスタンスには Session Manager で接続する（SSH は開けていない）。

```sh
aws ssm start-session --region "$(terraform output -raw aws_region)" \
  --target "$(terraform output -raw instance_id)"
```

`--region` は省略できない。省略すると `~/.aws/config` の既定リージョンに問い合わせ、そこにインスタンスが無いため `TargetNotConnected` になる（SSM は「存在しない」と「接続されていない」を区別しない）。

### インスタンスは作り直さない

このインスタンスのディスクにワールドの唯一のコピーがある。壊れたら作り直すのではなく、作り直せないものとして扱う。置き換えは 3 重に止めてある。

| 守り | 効く範囲 |
| --- | --- |
| `DisableApiTermination` | AWS 全体。コンソール・CLI・API のどこからも terminate できない |
| `lifecycle { prevent_destroy }` | Terraform。destroy と置き換えを要求する plan はエラーで停止する |
| `lifecycle { ignore_changes = [ami, user_data] }` | AMI が更新されても、`user_data` を編集しても plan に差分が出ない |

この結果 `user_data` の変更は現インスタンスに反映されない。**`user_data` は「作り直すならこう作る」という記録**であり、稼働中の変更手段ではない。実機を変えるときは Session Manager で入って手で変える。手順は [docs/setup-ec2.md](docs/setup-ec2.md) にある。

作り直しが本当に必要になったときは、既存ボリュームを切り離してから新インスタンスに付け替える。`prevent_destroy` を外して `apply` するのではない。

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
sudo systemctl status palworld   # 稼働状況
sudo journalctl -u palworld -f   # ログ
```

`running` かつヘルスチェックが `ok/ok` でも、ゲームサーバーの状態は何も意味しない。`/palworld status` も同じ限界を持つ。実際に遊べるかを確かめる手段はクライアントで接続することだけ。

**遊び終わったら停止する。** メモリ使用量が稼働時間に比例して増え続け、連続稼働では 5〜7 日で OOM する。定期再起動を持たないのは、停止するのが前提だから。

管理パスワードの確認。ゲーム内で `/AdminPassword <pw>` を実行すると `/Shutdown` `/Broadcast` `/KickPlayer` `/BanPlayer` `/Save` が使える。

```sh
aws ssm get-parameter --region "$(terraform output -raw aws_region)" \
  --name "$(terraform output -raw server_secrets_parameter)" \
  --with-decryption --query Parameter.Value --output text
```

- 設定ファイル: `/home/palworld/PalServer/Pal/Saved/Config/LinuxServer/PalWorldSettings.ini`
- セーブデータ: `/home/palworld/PalServer/Pal/Saved/SaveGames/0/<world-id>/`
- ゲーム本体の更新は `palworld.service` の `ExecStartPre` が起動ごとに `app_update` を実行するため、bot で stop → start すれば取り込まれる。クライアントにパッチが来た直後はこれが必要になる

## セーブの復元

スナップショットの一覧:

```sh
aws ec2 describe-snapshots --region "$(terraform output -raw aws_region)" \
  --owner-ids self --filters 'Name=tag:Name,Values=palworld*' \
  --query 'reverse(sort_by(Snapshots,&StartTime))[].[SnapshotId,StartTime,Description]' --output table
```

復元は現ボリュームを壊さない形で行う。スナップショットから別のボリュームを作り、確認してから差し替える。

```sh
R=$(terraform output -raw aws_region)
I=$(terraform output -raw instance_id)
AZ=$(aws ec2 describe-instances --region "$R" --instance-ids "$I" \
  --query 'Reservations[0].Instances[0].Placement.AvailabilityZone' --output text)

# 1. スナップショットからボリュームを作る
VOL=$(aws ec2 create-volume --region "$R" --availability-zone "$AZ" \
  --snapshot-id <snap-id> --volume-type gp3 --query VolumeId --output text)

# 2. 稼働中のインスタンスに 2 本目として付ける（サーバーは停止しておく）
aws ec2 attach-volume --region "$R" --instance-id "$I" --volume-id "$VOL" --device /dev/sdf
```

Nitro 世代なので `/dev/sdf` を指定しても実体は `/dev/nvme1n1` になる。中身を読み取り専用で確認する:

```sh
sudo mkdir -p /mnt/restore
sudo mount -o ro,nouuid /dev/nvme1n1p1 /mnt/restore
ls /mnt/restore/home/palworld/PalServer/Pal/Saved/SaveGames/0/*/Level.sav
```

必要なワールドだけを現行の `SaveGames` にコピーする。全体を差し替えるより影響範囲が小さい。

```sh
sudo systemctl stop palworld
sudo cp -a /mnt/restore/home/palworld/PalServer/Pal/Saved/SaveGames/0/<world-id> \
  /home/palworld/PalServer/Pal/Saved/SaveGames/0/
sudo chown -R palworld:palworld /home/palworld/PalServer/Pal/Saved
sudo systemctl start palworld
```

`chown` を忘れると、サーバーは起動してポートも開きハンドシェイクにも応答するが、ワールドを作れずログも書かずクラッシュもしない。症状がすべてネットワーク側を指すように見えるので、疑う順番を間違えやすい。

確認が終わったら片付ける。

```sh
sudo umount /mnt/restore
aws ec2 detach-volume --region "$R" --volume-id "$VOL"
aws ec2 delete-volume --region "$R" --volume-id "$VOL"
```

### 更新せずに起動する

`ExecStartPre` はセーブに触らない（`app_update ... validate` は depot の既知ファイルだけを検証・修復し、`Pal/Saved` は残る）ので、上のセーブ復元と競合しない。

ただしゲーム本体の更新が原因で壊れた場合、起動するたびに同じ版へ上げ直されるため、そのままでは切り分けられない。更新を止めて起動するには drop-in で `ExecStartPre` を空にする。空の宣言はリスト全体をクリアする。

```sh
sudo systemctl edit --drop-in=no-update palworld
```

```ini
[Service]
ExecStartPre=
```

```sh
sudo systemctl start palworld
```

切り分けが終わったら drop-in を消して戻す。

```sh
sudo rm /etc/systemd/system/palworld.service.d/no-update.conf
sudo systemctl daemon-reload
```

なお、これで戻せるのはワールドだけで**ゲーム本体の版は戻せない**。Palworld の dedicated server は anonymous depot で最新ビルドしか配っておらず、`app_update` に版を指定する手段がない。スナップショットの有無とは無関係の制約。
