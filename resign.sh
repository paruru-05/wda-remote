#!/usr/bin/env bash
# WDA 再署名スクリプト (無料 Apple ID は 7 日ごとに必要)
#
#   このスクリプトはあなたのターミナルで対話的に実行してください。
#   パスワードは画面に表示されません (このスクリプトの外へは送信されません)。
#
#   usage: ./resign.sh あなたのAppleIDメール
#   例:   ./resign.sh myname@icloud.com

set -u

# 常にこのプロジェクトディレクトリから実行する
# (AltServer は ./AltServerData をカレントディレクトリ基準で見るため、
#  実行場所が変わると別の証明書が作られてしまう)
cd "$(dirname "$0")"

export PATH="/home/harut/.pyenv/versions/menv/bin:$PATH"

UDID="00008110-00027D020CE0401E"
IPA="/home/harut/wda-remote/wda-build/WebDriverAgentRunner-Runner-fixed2.ipa"
ANISETTE_URL="http://127.0.0.1:6969"

APPLE_ID="${1:-}"
if [ -z "$APPLE_ID" ]; then
    echo "usage: $0 <あなたのAppleIDメールアドレス>"
    exit 1
fi

if [ ! -f "$IPA" ]; then
    echo "ERROR: IPA が見つかりません: $IPA"
    echo "       wda-build/ 内の最新の IPA (WebDriverAgentRunner-Runner-fixed2.ipa 等) を確認してください"
    exit 1
fi

# ---------- anisette サーバー ----------
if curl -s -m 2 "$ANISETTE_URL" >/dev/null 2>&1; then
    echo "[resign] anisette サーバー稼働中 OK"
else
    echo "[resign] anisette セッションを確認..."
    python3 -m anisette new default 2>/dev/null || true
    echo "[resign] anisette サーバーを起動..."
    nohup python3 -m anisette serve default --port 6969 > /tmp/anisette.log 2>&1 &
    sleep 3
    if ! curl -s -m 2 "$ANISETTE_URL" >/dev/null 2>&1; then
        echo "ERROR: anisette サーバーが起動しません。ログ: /tmp/anisette.log"
        exit 1
    fi
fi

# ---------- パスワード入力 ----------
echo "[resign] Apple ID 認証を開始します"
read -s -r -p "Apple ID パスワード: " PASSWORD
echo ""

if [ -z "$PASSWORD" ]; then
    echo "ERROR: パスワードが入力されていません"
    exit 1
fi

# ---------- AltServer 署名 + インストール ----------
echo "[resign] AltServer で署名・インストール中..."
echo "        'Enter two factor code' と表示されたら、iPhone に届いた6桁コードを入力してください"
echo ""
ALTSERVER_ANISETTE_SERVER="$ANISETTE_URL" \
ALTSIGN_ZSIGN="/opt/altserver/zsign" \
/opt/altserver/AltServer -u "$UDID" -a "$APPLE_ID" -p "$PASSWORD" -d -d "$IPA"

PASSWORD=""

echo ""
echo "[resign] 終了。インストール後は iPhone の設定→一般→VPNとデバイス管理で"
echo "        開発者証明書が信頼済みか確認し、./start.sh で再起動してください。"
