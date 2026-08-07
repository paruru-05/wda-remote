# MiniControl Remote

低遅延でiPhoneをブラウザから遠隔操作するWebアプリです。

- **操作**: 自作XCUITestランナー **MiniControl** (WDA置き換え、WebSocket直接制御)
- **画面**: AirPlayミラーリング (UxPlay) + GStreamerキャプチャ (`screen_airplay.sh` + server.py)

動作実績: **iPhone 13 mini / iOS 18.7.3** (AltServer-Linux + zsign で署名)

## 構成

```
wda-remote/
├── start.sh             # 一発起動 (トンネル + ポート転送 + MiniControl起動 + UxPlay + サーバー)
├── stop.sh              # 停止
├── resign.sh            # 7日ごとの再署名 (あなたのターミナルで実行)
├── screen_airplay.sh    # AirPlay レシーバー (UxPlay) の起動
├── server.py            # FastAPIサーバー (MiniControl WSクライアント + UxPlay画面キャプチャ配信)
├── minicontrol_client.py# MiniControl WSクライアント
├── static/index.html    # ブラウザUI
├── minicontrol/         # MiniControl ランナーのソース (XcodeGen + XCTest)
└── .github/workflows/   # macOSビルド (GitHub Actions)
```

## MiniControl ランナーについて

WDA (WebDriverAgent) の代わりに、iPhone上で動く最小のXCUITestランナーです。
座標入力は `XCUIDevice.eventSynthesizer` で直接イベント合成するため、WDAの
AXスナップショットやHTTPオーバーヘッドを排除し、低遅延を目指しています。

- ポート **9100** でRFC6455 WebSocketサーバーを待ち受け
- コマンド (JSON): `ping` / `tap` / `swipe` / `keys` / `button` / `launch` / `terminate`
- 座標は論理ポイント (iPhone 13 mini = 390x844)
- ビルドは **GitHub Actions** (macOS) で行う: `minicontrol/project.yml` から
  `xcodegen generate` → `xcodebuild` → `MiniControl-Runner.zip` を生成

### ランナーのビルド・署名・インストール

1. リポジトリを GitHub に push → Actions の **Build MiniControl** ワークフローが
   `MiniControl-Runner.zip` をアーティファクトとして生成
2. 解凍して `.app` を IPA 化 (`zip` を `.ipa` にリネーム)
3. `./resign.sh あなたのAppleID@example.com` で署名・インストール
   (AltServer が bundle id 末尾にランダムサフィックスを付与する)
4. `./start.sh` が `com.harut.MiniControl.xctrunner.*` を自動検出して起動

## 一発起動

```bash
cd ~/wda-remote
./start.sh
```

ブラウザで **http://localhost:8101** を開きます。

`start.sh` は以下を自動で行います:
1. iPhone の USB 接続確認
2. iOS 17+ トンネル (tunneld) 起動 (root 必要)
3. DeveloperDiskImage マウント
4. ポート転送 (host:9100 -> iPhone:9100)
5. MiniControl ランナーを `dvt xcuitest` で自動起動 (未起動時)
6. AirPlay レシーバー (UxPlay) の起動 (`screen_airplay.sh`)
7. リモート操作サーバー (port 8101) の起動

停止するときは `./stop.sh`。

## 画面表示 (AirPlay ミラーリング)

`start.sh` が UxPlay を起動し、iPhone のミラーリング映像をブラウザへ配信します。

1. iPhone の **コントロールセンター** を開く
2. **画面収録・ミラーリング** (2つ重なった四角のアイコン) をタップ
3. **MiniControl** を選択 → ミラーリング開始
4. ブラウザ (**http://localhost:8101**) に iPhone の画面が表示される

### 仕組み

```
iPhone (AirPlay ミラー) → UxPlay (X11ウィンドウ 390x844)
  → GStreamer (ximagesrc → jpegenc) → server.py (latest_frame)
  → /ws/screen → ブラウザ (ライブ画面)
```

- 映像の遅延は Wi-Fi 経由の AirPlay 分のみ (WDA のスクショループとは別経路)
- キャプチャはウィンドウの実サイズ (390x844) を1:1で配信。座標ズレなし
- ミラー開始は iPhone から手動で 1 回。UxPlay を再起動してもサーバーが自動で再キャプチャ
- 画面が映らない場合は `pgrep -x uxplay` / `/tmp/minicontrol_uxplay.log` を確認

## 使い方

1. ブラウザで **http://localhost:8101** を開く
2. 上部の **「接続確認」** → ランナー接続バッジがオンになる
3. 操作:

| 操作 | 方法 | 補足 |
|---|---|---|
| タップ | 画面のクリック | 15px以下の移動はタップ扱い |
| スクロール / スワイプ | 画面をドラッグ | |
| ホーム / ロック / 解除 | サイドバーのボタン | |
| テキスト入力 | テキスト欄に入力 → 「入力」 | 英数字のみ確実 (日本語IME変換は不可) |
| クリア | 「クリア」ボタン | 削除キー (`\ue003`) を送信 |
| アプリ起動 / 終了 | アプリBundleID入力 → 起動/終了 | 例: `com.apple.mobilesafari` |
| スクショ | 「スクショ取得」 | 最新キャプチャフレームを表示 |

## 必要なもの (セットアップ済み)

| 項目 | 内容 |
|---|---|
| 署名 | AltServer-Linux (`/opt/altserver/AltServer`) + zsign (`/opt/altserver/zsign`) |
| anisette | ポート6969 (AltServer認証用。`resign.sh` が自動起動) |
| 署名データ | `~/wda-remote/AltServerData/` (必ず固定) |
| iOS 17+ トンネル | tunneld (ポート49151, rootで起動。`start.sh` が自動起動) |
| MiniControl BundleID | `com.harut.MiniControl.xctrunner.<サフィックス>` (AltServerが付与、自動検出) |
| UDID | `00008110-00027D020CE0401E` |
| Python | `/home/harut/.pyenv/versions/menv/bin/python3` |

## 再署名 (7日ごとに必要)

無料 Apple ID のため証明書は **7日で失効** します。起動に失敗するようになったら再署名してください。

```bash
cd ~/wda-remote
./resign.sh あなたのAppleID@example.com
```

- **あなた自身のターミナル** で実行してください (パスワード入力が必要です)
- `Enter two factor code` と出たら、iPhoneに届いた6桁コードを入力
- **必ず `~/wda-remote` で実行してください** (`resign.sh` は自動でcdします)
- 完了後、iPhoneの `設定 > 一般 > VPNとデバイス管理` で証明書が信頼済みか確認
- `./start.sh` で再起動

## トラブルシューティング

| 症状 | 対処 |
|---|---|
| `start.sh` が「MiniControl ランナーがインストールされていません」 | GitHub Actions のアーティファクトを署名・インストールしてから再実行 |
| `dvt xcuitest` が「Failed to start service」 | iOS 17+ はトンネル+dev diskマウント必須 (ログ: `/tmp/wda-remote/tunneld.log`, `mounter.log`)。dev disk未マウントだと `No such service: com.apple.dt.testmanagerd.remote` |
| ランナーが起動しない | `/tmp/wda-remote/minicontrol_console.log` を確認。署名の失効(7日)なら `./resign.sh` |
| アプリがクラッシュする | 署名失効の可能性。再署名して iPhone で開発者を信頼。`~/wda-remote/AltServerData` は消さない |
| ライブ画面が出ない | iPhone のコントロールセンター → 画面収録・ミラーリング → **MiniControl** を選択。`pgrep -x uxplay` と `/tmp/minicontrol_uxplay.log` を確認 |
| 画面が真っ黒・切れる | AirPlay は Wi-Fi 経路。Wi-Fi 混雑/距離を確認。UxPlay が落ちたら `./start.sh` 再実行 |
| タップ位置がズレる | キャプチャサイズ (`/api/captureinfo`) が 390x844 以外の場合はサーバーログを確認。ウィンドウがリサイズされると再キャプチャされる |
| タップ・スワイプが効かない | `./stop.sh` → `./start.sh` でランナーを再起動 |

## API

| エンドポイント | 説明 |
|---|---|
| `GET /api/status` | ランナー接続状態・ロック状態 |
| `POST /api/session` | ダミー (状態なし。windowSize を返す) |
| `DELETE /api/session` | ダミー |
| `GET /api/screenshot` | 最新キャプチャフレーム (base64) |
| `GET /api/screeninfo` | 画面サイズ (390x844) |
| `GET /api/captureinfo` | 実際のキャプチャサイズ `{size, frame}` |
| `POST /api/tap` | タップ `{x, y}` |
| `POST /api/swipe` | 座標ドラッグ `{from_x, from_y, to_x, to_y, duration}` |
| `POST /api/type` | テキスト入力 `{text}` |
| `POST /api/key` | キー送信 `{key}` (例 `\ue003`=削除) |
| `POST /api/home` | ホームボタン |
| `POST /api/lock` / `unlock` | ロック / 解除 |
| `POST /api/app/launch` | アプリ起動 `{bundle_id}` |
| `POST /api/app/terminate` | アプリ終了 `{bundle_id}` |
| `WS /ws/screen` | ライブ画面配信 (UxPlayキャプチャ経由) |
