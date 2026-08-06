#!/usr/bin/env bash
# MiniControl Remote Control 停止スクリプト
#
#   アプリサーバー・ポート転送・ランナー(xcuitest)・トンネル(tunneld)を停止します。

LOG_DIR="/tmp/wda-remote"

echo "[stop] サーバーを停止..."
fuser -k 8101/tcp 2>/dev/null

echo "[stop] MiniControl (xcuitest) を停止..."
pkill -f "[d]vt xcuitest" 2>/dev/null

echo "[stop] ポート転送を停止..."
pkill -f "[u]sbmux forward 9100 9100" 2>/dev/null

echo "[stop] トンネル (tunneld) を停止..."
sudo pkill -f "[r]emote tunneld" 2>/dev/null

sleep 1
echo "[stop] 完了"
