#!/usr/bin/env bash
# MiniControl Remote Control 一発起動スクリプト
#
#   1. iPhone が USB で接続されているか確認
#   2. iOS 17+ トンネル (tunneld) を起動
#   3. ポート転送を開始 (host:9100 -> iPhone:9100, MiniControl WebSocket)
#   4. DeveloperDiskImage をマウント
#   5. MiniControl ランナーが動いていなければ dvt xcuitest で自動起動
#   6. リモート操作サーバー (port 8101) を起動
#   7. AirPlay レシーバー (UxPlay) を起動し、iPhone のミラーリング画面を受信
#   8. ブラウザで http://localhost:8101 を開く
#
#   ミラーリングは iPhone のコントロールセンターから手動で 1 回開始する。

set -u

UDID="00008110-00027D020CE0401E"
MINICONTROL_PREFIX="com.harut.MiniControl.xctrunner"
MINICONTROL_URL="ws://127.0.0.1:9100"
MINICONTROL_AIRPLAY_NAME="MiniControl"
APP_URL="http://127.0.0.1:8101"
APP_PORT="8101"
LOG_DIR="/tmp/wda-remote"
PYM="/home/harut/.pyenv/versions/menv/bin/pymobiledevice3"

DIR="$(cd "$(dirname "$0")" && pwd)"

# 常に pyenv の menv を使う
export PATH="/home/harut/.pyenv/versions/menv/bin:$PATH"

mkdir -p "$LOG_DIR"

say() { echo "[start] $*"; }
# MiniControl は 9100 で WebSocket リスンする。usbmux forward はホスト側ポートを
# 常に開くため、TCP接続可否では判定できない。実際に WS ping を投げて応答を確認する。
is_runner_up() {
    timeout 4 python3 -c "
import asyncio, websockets, json
async def m():
    async with websockets.connect('ws://127.0.0.1:9100', open_timeout=2) as ws:
        await ws.send(json.dumps({'command': 'ping'}))
        r = await ws.recv()
        if 'locked' in r:
            print(r)
asyncio.run(m())
" >/dev/null 2>&1
}
is_server_up() { curl -s -m 3 "$APP_URL/api/status" >/dev/null 2>&1; }
is_tunnel_up() { curl -s -m 2 http://127.0.0.1:49151/ >/dev/null 2>&1; }

# インストール済みの MiniControl ランナー BundleID を探す (AltServer が .xctrunner.<SUFFIX> を付与)
find_runner_bundle_id() {
    "$PYM" apps list 2>/dev/null | grep -oE '"'"$MINICONTROL_PREFIX"'(\.[A-Za-z0-9]+)+"' \
        | tr -d '"' | sort -u | head -n 1
}

# ---------- 1. デバイス確認 ----------
if ! pymobiledevice3 usbmux list 2>/dev/null | grep -q "$UDID"; then
    echo "ERROR: iPhone が見つかりません。USB ケーブルを確認して再実行してください。"
    exit 1
fi
say "iPhone 接続確認 OK ($UDID)"

# ---------- 1.5 iOS 17+ 用トンネル (tunneld, root が必要) ----------
# XCUITest など developer 系コマンドはiOS17+ でトンネル必須
if is_tunnel_up; then
    say "トンネル (tunneld) は既に稼働中"
else
    say "iOS 17+ トンネル (tunneld) を起動..."
    if sudo -n -b "$PYM" remote tunneld --no-wifi --usb > "$LOG_DIR/tunneld.log" 2>&1; then
        ok=0
        for _ in $(seq 1 15); do
            if is_tunnel_up; then ok=1; break; fi
            sleep 1
        done
        if [ "$ok" != "1" ]; then
            echo "ERROR: tunneld が起動しませんでした。ログ: $LOG_DIR/tunneld.log"
            exit 1
        fi
        say "トンネル (tunneld) 起動完了"
    else
        echo "ERROR: tunneld を起動できませんでした (root 権限が必要です)。ログ: $LOG_DIR/tunneld.log"
        exit 1
    fi
fi

# ---------- 2. ポート転送 ----------
if pgrep -f "pymobiledevice3 usbmux forward 9100" >/dev/null; then
    say "ポート転送は既に稼働中"
else
    say "ポート転送を開始 (9100 -> iPhone 9100)"
    nohup pymobiledevice3 usbmux forward 9100 9100 > "$LOG_DIR/forward.log" 2>&1 &
    sleep 2
    if ! pgrep -f "pymobiledevice3 usbmux forward 9100" >/dev/null; then
        echo "ERROR: ポート転送の起動に失敗しました。ログ: $LOG_DIR/forward.log"
        exit 1
    fi
fi

# ---------- 3. DeveloperDiskImage マウント ----------
# iOS 17+ では testmanagerd などのサービスが dev disk マウント後に利用可能になる
say "DeveloperDiskImage をマウント..."
if ! pymobiledevice3 mounter auto-mount --tunnel "$UDID" > "$LOG_DIR/mounter.log" 2>&1; then
    echo "ERROR: DeveloperDiskImage マウントに失敗。ログ: $LOG_DIR/mounter.log"
    exit 1
fi

# ---------- 4. MiniControl ランナー ----------
RUNNER_BUNDLE_ID="$(find_runner_bundle_id)"
if [ -z "$RUNNER_BUNDLE_ID" ]; then
    echo "ERROR: MiniControl ランナーがインストールされていません ($MINICONTROL_PREFIX.*)"
    echo "       GitHub Actions のアーティファクト (MiniControl-Runner.zip) を"
    echo "       AltServer (./resign.sh) で署名・インストールしてください。"
    exit 1
fi
say "ランナー検出: $RUNNER_BUNDLE_ID"

if is_runner_up; then
    say "MiniControl ランナーは既に稼働中"
else
    say "MiniControl ランナーを起動中 (xcuitest)... 最大60秒待機します"
    nohup pymobiledevice3 developer dvt xcuitest \
        --tunnel "$UDID" \
        --output-log "$LOG_DIR/minicontrol.log" "$RUNNER_BUNDLE_ID" \
        > "$LOG_DIR/minicontrol_console.log" 2>&1 &
    ok=0
    for _ in $(seq 1 30); do
        if is_runner_up; then ok=1; break; fi
        sleep 2
    done
    if [ "$ok" != "1" ]; then
        echo "ERROR: MiniControl が起動しませんでした。ログを確認: $LOG_DIR/minicontrol_console.log"
        exit 1
    fi
    say "MiniControl 起動完了"
fi

# ---------- 4.5 AirPlay レシーバー (UxPlay) ----------
# 画面表示用。iPhone のコントロールセンターから手動でミラーリングを開始する。
if pgrep -x uxplay >/dev/null 2>&1; then
    say "UxPlay は既に稼働中"
else
    say "AirPlay レシーバー (UxPlay) を起動..."
    if ! "$DIR/screen_airplay.sh"; then
        echo "ERROR: UxPlay の起動に失敗しました"
        exit 1
    fi
fi

# ---------- 5. アプリサーバー ----------
if is_server_up; then
    say "サーバーは既に稼働中"
else
    say "サーバーを起動 (port $APP_PORT)"
    nohup python3 "$DIR/server.py" > "$LOG_DIR/server.log" 2>&1 &
    sleep 2
    if ! is_server_up; then
        echo "ERROR: サーバー起動に失敗しました。ログ: $LOG_DIR/server.log"
        exit 1
    fi
fi

# ---------- 6. 完了 ----------
echo ""
echo "=============================================="
echo "  MiniControl Remote 起動完了"
echo "  ブラウザで開く: $APP_URL"
echo "  停止: $(dirname "$0")/stop.sh"
echo "  画面: iPhone のコントロールセンター → 画面収録・ミラーリング → '$MINICONTROL_AIRPLAY_NAME'"
echo "=============================================="
