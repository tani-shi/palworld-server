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
| REST API | 有効。8212/tcp をループバックでのみ受ける。Security Group に tcp の穴は無い。`make api-*` と bot が SSM 経由で叩く |

ルールの入口は `/palworld register` だけで、Terraform は ingress を宣言しない。

**インスタンスは作り直さない。** ディスクにワールドの唯一のコピーがある。終了保護・`prevent_destroy`・`ignore_changes` で置き換えを止めてあるため、`user_data` の変更は現インスタンスに反映されない。実機を変えるときは `make session` で入って手で変える。作り直す場合は既存ボリュームを新インスタンスに付け替える。

## セットアップ

1. Discord Developer Portal でアプリケーションを作る
2. `infra/terraform.tfvars.example` を `terraform.tfvars` に写し、**Public Key** を `discord_public_key` に設定する。これだけが必須項目
3. `make init` → `make bot-deploy`

`/palworld ask` は Claude Platform on AWS の `claude-sonnet-5` を使う。**Amazon Bedrock とは別のサービス**で、web 検索が使えるのはこちらだけ。

1. AWS Console の Claude Platform on AWS ページからサインアップする。この AWS アカウントに紐づく Anthropic 組織が新規に作られ、Marketplace のサブスクライブが自動で処理される
2. `ap-northeast-1` にワークスペースを作り、`wrkspc_` で始まる ID を `terraform.tfvars` の `anthropic_workspace_id` に書く

課金は Claude Consumption Unit で AWS の請求に載る。モデルを変えるときは `claude_model` 変数。

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
| `/palworld ask <質問>` | サーバーの状態、ワールドの中身、ゲームの攻略を自然言語で訊く |

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

## REST API

サーバーの状態は REST API からも読める。ループバックでしか受けていないので、`make` も bot も SSM 経由で実機の `curl` を叩き、出力を S3 から読み戻す（SSM の応答は 24,000 文字で切られ、`game-data` はプレイヤー 1 人で 34KB を超える）。

| コマンド | 中身 |
| --- | --- |
| `make api-info` | バージョン・サーバー名・ワールド ID |
| `make api-metrics` | FPS・接続数・uptime・拠点数・ゲーム内日数 |
| `make api-players` | 接続中のプレイヤー |
| `make api-settings` | 実効設定（117 キー） |
| `make api-game-data` | ワールド内の全アクター |
| `make api-announce MSG="..."` | ゲーム内に告知 |

`api-game-data` には `-EnableGameDataAPI` 起動スイッチが要る（公式ドキュメントの `-enable-gamedata-api` はこのビルドでは通らない）。`make gamedata-on` で有効にし、`make gamedata-off` で戻す。**どちらもゲームサーバーを再起動する。**

`/palworld ask` はこの 6 本と web 検索・web 取得を Claude に道具として渡し、必要なものを選ばせて答える。`game-data` は 1 回の問い合わせにつき 1 度だけ取得してメモリ上で集計するので、何を訊いても実機への負荷は変わらない。会話は続かず、毎回独立した 1 問 1 答。

サーバーの状態だけでなく、ゲーム自体の攻略にも答える。**参照先は <https://paldb.cc/ja> のみに限定してある。** 日本語の攻略サイトは更新が止まった広告過多のものが大半で、検索を開放すると質が落ちるため。paldb.cc が扱わない話題には「見つからなかった」と答える。

**`ask` はゲーム内に告知を送れる。** LLM が `announce` を呼んだ場合、Discord の回答に送信内容が併記される。web ページの内容がコンテキストに入るため、原理的にはページ側から告知を焚きつけられる。被害はゲーム内チャットに文字が出ることに留まり、送信内容は必ず Discord に併記されるため受容している。

Pal の個体データ、ギルドのメンバー構成、拠点の中身、オフラインプレイヤーは REST API では取れない。セーブファイルの解析が要る。

### システムプロンプト

`bot/prompts/ask.md` が正で、実行時は SSM Parameter Store から読む。

```sh
make prompt          # いま動いているプロンプトを表示
make prompt-deploy   # bot/prompts/ask.md を反映
```

**`prompt-deploy` だけで即座に切り替わる。** `make bot-deploy` も `make apply` も要らない。Terraform はパラメータを作るだけで値の変更を追わないので、`apply` で巻き戻ることもない。

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
