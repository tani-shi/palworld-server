# EC2 での Palworld 1.0 サーバー構築手順（手動）

`infra/` の Terraform は以下を `user_data` として自動実行する。手動構築や障害時の切り分けにはこの手順を辿る。

## 前提

- Palworld 1.0 正式版リリース: 2026年7月9〜10日
- Dedicated Server の Steam App ID: **2394010**（anonymous ログイン可、ダウンロード約 12〜15 GB）
- 公式推奨スペック: 4 コア / 16 GB RAM / SSD / 64bit Linux

### 必要メモリの目安（稼働日数で増加する）

| プレイヤー数 | 新規ワールド | 1 週間後 |
| --- | --- | --- |
| 1–4 | 5 GB | 8 GB |
| 5–8 | 7 GB | 11 GB |
| 9–16 | 10 GB | 14 GB |
| 17–24 | 13 GB | 18 GB |

### ポート

| ポート | プロトコル | 用途 | 公開範囲 |
| --- | --- | --- | --- |
| 8211 | UDP | ゲーム接続（必須） | プレイヤーの IP のみ |
| 27015 | UDP | コミュニティサーバーブラウザへの掲載 | 掲載する場合のみ全公開 |
| 8212 | TCP | 管理 REST API | 有効化しない（使う場合も公開しない。漏洩で admin 全権を奪われる） |

## 1. SteamCMD と依存パッケージ

SteamCMD は 32bit バイナリなので i386 アーキテクチャを有効にする。AWS CLI は Ubuntu 24.04 の
リポジトリに存在しないため、公式インストーラを使う。

```sh
sudo dpkg --add-architecture i386
sudo apt-get update
sudo apt-get install -y software-properties-common
sudo add-apt-repository -y multiverse
sudo apt-get update

echo steam steam/question select "I AGREE" | sudo debconf-set-selections
echo steam steam/license note '' | sudo debconf-set-selections
sudo apt-get install -y steamcmd lib32gcc-s1 xdg-user-dirs jq unzip python3

curl -fsSL https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip -o /tmp/awscliv2.zip
unzip -q /tmp/awscliv2.zip -d /tmp
sudo /tmp/aws/install
```

## 2. サーバー本体のインストール

root で動かさないよう専用ユーザーを作る。起動直後は `app_update` が `Missing configuration` で
失敗することがあり、同じコマンドが後の試行では通る。失敗したら数十秒待って再実行する。

```sh
sudo useradd -m -s /bin/bash palworld
sudo -u palworld /usr/games/steamcmd \
  +force_install_dir /home/palworld/PalServer \
  +login anonymous \
  +app_update 2394010 validate \
  +quit
```

## 3. 設定

`DefaultPalWorldSettings.ini` を雛形として配置し、必要なキーだけ書き換える。設定は
`OptionSettings=(Key=Value,...)` という 1 行に詰め込まれている。

```sh
sudo -u palworld mkdir -p /home/palworld/PalServer/Pal/Saved/Config/LinuxServer
sudo -u palworld cp /home/palworld/PalServer/DefaultPalWorldSettings.ini \
  /home/palworld/PalServer/Pal/Saved/Config/LinuxServer/PalWorldSettings.ini
```

書き換える主なキー: `ServerName` / `ServerDescription` / `AdminPassword` / `ServerPassword` /
`ServerPlayerMaxNum` / `PublicPort` / `DeathPenalty`

`RCONEnabled` と `RESTAPIEnabled` は有効にしない。運用はゲーム内の admin コマンドと
systemd で足りる。RCON は非推奨で、将来のアップデートで削除される。

## 4. systemd サービス

```ini
[Unit]
Description=Palworld dedicated server
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=palworld
Group=palworld
WorkingDirectory=/home/palworld/PalServer
ExecStart=/home/palworld/PalServer/PalServer.sh -port=8211 -players=16 -useperfthreads -NoAsyncLoadingThread -UseMultithreadForDS
KillSignal=SIGINT
TimeoutStopSec=120
Restart=on-failure
RestartSec=10
LimitNOFILE=100000

[Install]
WantedBy=multi-user.target
```

- `-useperfthreads -NoAsyncLoadingThread -UseMultithreadForDS` はサーバー tick に直結する。付けない場合と比べて体感が大きく変わる
- 停止は `SIGINT`。`SIGTERM` ではセーブが中断される

## 5. 定期メンテナンス

メモリ使用量が稼働時間に比例して増え続け、放置すると 5〜7 日で OOM する。日次でバックアップ →
再起動を行う。

```sh
systemctl stop palworld
tar czf /tmp/save.tar.gz -C /home/palworld/PalServer/Pal/Saved SaveGames
aws s3 cp /tmp/save.tar.gz "s3://<bucket>/saves/1.0/$(date -u +%Y%m%dT%H%M%SZ).tar.gz"
systemctl start palworld
```

## 6. アップデート

```sh
sudo systemctl stop palworld
sudo -u palworld /usr/games/steamcmd +force_install_dir /home/palworld/PalServer \
  +login anonymous +app_update 2394010 validate +quit
sudo systemctl start palworld
```

アップデートで `PalWorldSettings.ini` に新しいキーが増えることがあるため、事前に設定ファイルを
バックアップしておく。

## 参考

- [Palworld 公式: Deploy dedicated server](https://docs.palworldgame.com/getting-started/deploy-dedicated-server/)
- [Palworld dedicated server setup: a 2026 guide that doesn't lie about RAM](https://www.renzom.com/blog/palworld-dedicated-server-setup)
- [Palworld 1.0: Dedicated Server Setup, Settings & Requirements](https://hosthavoc.com/blog/palworld-dedicated-server-setup)
