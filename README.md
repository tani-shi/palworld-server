# palworld-server

Palworld 1.0 の専用サーバーを AWS 上で運用するリポジトリ。

| ディレクトリ | 中身 |
| --- | --- |
| `infra/` | Terraform。VPC / Security Group / EC2 / Elastic IP / スナップショット（DLM）/ IAM |
| `bot/` | Discord bot（Lambda） |

操作は `make help` に一覧がある。

## 構成

| 項目 | 値 |
| --- | --- |
| OS | Ubuntu 24.04 LTS（SteamCMD が 32bit のため i386 パッケージが必要） |
| インスタンス | `m7i-flex.xlarge`（4 vCPU / 16 GiB） |
| ストレージ | gp3 60 GiB、`DeleteOnTermination=false` |
| ポート | 8211/udp（ゲーム）、27015/udp（Steam クエリ）。どちらも許可済み IP のみ |
| アクセス制御 | Security Group の IP 許可のみ。参加パスワードは使わない |
| RCON | 無効 |
| REST API | 有効。8212/tcp をループバックでのみ受ける。Security Group に tcp の穴は無い |

ルールの入口は `/palworld register` だけで、Terraform は ingress を宣言しない。

**インスタンスは作り直さない。** ディスクにワールドの唯一のコピーがある。終了保護・`prevent_destroy`・`ignore_changes` で置き換えを止めてあるため、`user_data` の変更は現インスタンスに反映されない。実機を変えるときは `make session` で入って手で変える。作り直す場合は既存ボリュームを新インスタンスに付け替える。

## セットアップ

1. Discord Developer Portal でアプリケーションを作る
2. `infra/terraform.tfvars.example` を `terraform.tfvars` に写し、**Public Key** を `discord_public_key` に設定する。これだけが必須項目
3. `make init` → `make bot-deploy`
4. 出力された `bot_webhook_url` を **Interactions Endpoint URL** に設定する。保存時に Discord が検証リクエストを送るので、ここで疎通が分かる
5. `bot/.env.example` を `.env` に写して `DISCORD_APPLICATION_ID` と `DISCORD_BOT_TOKEN` を設定し、`make bot-deploy-commands`

`server_address` をプレイヤーへの接続先として案内する。bot が使う値は Terraform が Lambda の環境変数へ渡す。

bot のコードを変えたら `make bot-deploy`。コマンドの定義を変えたときだけ `make bot-deploy-commands` も実行する。

## 運用

起動・停止・IP 許可は Discord のスラッシュコマンドで行う。誰でも実行できる。

| コマンド | 動作 |
| --- | --- |
| `/palworld start` | 起動 |
| `/palworld stop` | 停止 |
| `/palworld status` | 状態と接続先アドレス |
| `/palworld register <ip>` | その IP からの接続を許可 |
| `/palworld unregister <ip>` | 許可を取り消す |
| `/palworld allowlist` | 許可済みの IP を一覧 |

`register` に渡せるのはグローバル IPv4 の単一アドレス（`/32`）のみ。自分のアドレスは <https://checkip.amazonaws.com> で調べる。

Discord や Lambda が落ちているときは `make start` / `make stop` / `make allow IP=...`。

- **プレイヤーが 60 分いないとインスタンスが自分を停止する。** 5 分ごとに REST API へ接続数を訊く `palworld-idle-stop.timer` が実機で動いている。ワールドは通常の停止と同じように保存される
- 停止し忘れても止まるが、メモリは稼働時間に比例して増え 5〜7 日で OOM するので、遊び終わったら `stop` するのが早い。定期再起動は無い
- 実機で 1 時間以上作業するときは `systemctl stop palworld-idle-stop.timer`。次の起動で自動的に戻る
- `status` が `running` でもゲームサーバーが遊べるとは限らない。確認手段はクライアントで接続することだけ
- ゲーム本体の更新は起動時に走る。クライアントにパッチが来たら `stop` → `start`。バージョンが合わないと接続できない
- 管理パスワードは `make password`。ゲーム内で `/AdminPassword <pw>` を実行すると `/Shutdown` `/Broadcast` `/KickPlayer` `/BanPlayer` `/Save` が使える
- 実機に入るのは `make session`（SSH は開けていない）
- 設定: `/home/palworld/PalServer/Pal/Saved/Config/LinuxServer/PalWorldSettings.ini`。**書き換えは `systemctl stop palworld` してから。** サーバーは終了時にこのファイルを自分の設定で上書きするので、稼働中の編集は次の停止で消える
- セーブ: `/home/palworld/PalServer/Pal/Saved/SaveGames/0/<world-id>/`

## 復元

DLM が日次でスナップショットを取る（JST 04:00、7 世代）。それより前には戻れないので、大きな変更の前は `make snapshot-create DESC="..."`。

```sh
make snapshots                        # 戻す先を決める
make restore-attach SNAP=snap-xxxx    # クローンを作って読み取り専用でマウント
make restore-list                     # 中のワールドを見る
make restore-world WORLD=54A0...      # ひとつを現行の SaveGames へ移す
make restore-clean                    # クローンを外して削除
```

`restore-world` は現行のワールドを `<world-id>.replaced-<timestamp>` に退避してから置く。

`restore-attach` はインスタンスの起動が前提。停止中は拒否される。

更新が原因で壊れた場合は `make autoupdate-off` で `app_update` を止めてから起動し、`make autoupdate-on` で戻す。戻せるのはワールドだけで、ゲーム本体の版は戻せない。
