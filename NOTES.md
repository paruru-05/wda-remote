# 保留中のプラン: 画面高速化 + WDA操作遅延低減 (2026-08-07)

ステータス: **保留** (次のアイデアを待って再検討)

## 背景・目的
寿司打(タイピングゲーム)のiPhoneリモートプレイを快適にするため、2つのボトルネックを解消する。

## 現状のボトルネック
- **画面**: `server.py:238` のWDA `/screenshot` ループ。iOS17+はtestmanagerd経由で実測1.5〜3fpsが上限(0.1秒sleepは無意味、キャプチャ自体が律速)。寿司打の動く寿司を追うには厳しい。
- **操作**: タップは1リクエスト=数百msがWDA側の宿命。さらに画面キャプチャ中はWDAサーバが1コマンドずつ直列処理 → スクショの裏でタップが待たされる。寿司打の打鍵は1打鍵1リクエストだと致命的に遅い。

## 調査で確認済みの事実
- uXPlay 1.73.2 インストール済み (`/usr/bin/uxplay`)、GStreamer 1.28 (ximagesrc / jpegenc OK)
- PyGObject Gst 利用可 (gi.require_version('Gst','1.0') で import 可能)
- X11 稼働中 (DISPLAY=:0)、Window Manager = Openbox → ウィンドウ位置/サイズ/装飾の制御可
- xdotool / xwininfo / wmctrl 利用可
- pymobiledevice3 には画面ストリーミング手段なし (screenshotはPNGのみ、WDAもHTTPラッパー)
- BLE HID はユーザーが不採用 (2016-08-07)

## プランA: 画面更新 → AirPlayミラーリングで30fps化
- uXPlay + GStreamer で配信。`ximagesrc(xid) → videoconvert → jpegenc → appsink` を `server.py` 内のバックグラウンドスレッドで実行(PyGObject、追加IPC不要)
- 起動: 別スクリプト `screen_airplay.sh`(新規)で uXPlay を `-s` 指定で起動(アスペクト比をiPhoneのポイント比率に合わせ座標ズレゼロ化)。ミラーリング開始はiPhoneのコントロールセンターから手動1回
- フォールバック: uXPlayフレームが1.5秒以上来ない場合は現行のWDAスクショに自動切替
- ブラウザ座標系はWDAの `window/size`(ポイント)のまま不変

## プランB: WDA操作遅延の低減
1. スクショと操作の競合排除: タップ/スワイプ/キー直後 ~400msはWSループのスクショを休止(共有 `last_input_ts`)
2. 打鍵のバッチ化(寿司打の鍵): ブラウザに `keydown` ハンドラ追加。入力をバッファし120msデバウンスで一括POST `/api/type`(1単語=1リクエスト)。特殊キー(Enter/Backspace/矢印)もマッピング
3. 送信文字列は既存 `type_text` のチャンク(200文字=1リクエスト)を流用

## 変更ファイル案
| ファイル | 変更 |
|---|---|
| `server.py` | GStreamerキャプチャスレッド+最新フレームバッファ、WSループのフォールバック/休止ロジック、`last_input_ts` 更新 |
| `static/index.html` | キー入力キャプチャ+デバウンス一括送信、特殊キー変換 |
| `screen_airplay.sh`(新規) | uXPlay起動+ウィンドウ整形(位置/サイズ/装飾) |
| `README.md` | AirPlay導入手順(手動ミラー開始1回)を追記 |

## リスク・確認点
- uXPlayのX11表示アクセス権(DISPLAY=:0 は利用可、XAUTHORITYの要否を確認)
- AirPlayミラーはWi-Fi経由(WDAのUSBトンネルと並行可、帯域は別)
- uXPlayウィンドウの装飾オフセット → xidキャプチャ(クライアント領域のみ)で回避
- 実機でのタイプテストでデバウンス挙動を検証
