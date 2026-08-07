import asyncio
import base64
import contextlib
import io
import logging
import os
import subprocess
import sys
import threading
import time

from fastapi import FastAPI, HTTPException, WebSocket, WebSocketDisconnect
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel
from PIL import Image

from minicontrol_client import MiniControlClient, MiniControlError

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
log = logging.getLogger("mini-server")

app = FastAPI(title="MiniControl Remote")

runner = MiniControlClient()

# Screen size of the device in logical points (iPhone 13 mini = 390x844).
# The browser maps its pointer coordinates against this box; the UxPlay
# video window is letterboxed to the same aspect ratio. Once a captured
# frame arrives, this follows the actual capture size so taps stay aligned.
WINDOW_SIZE = {"width": 390, "height": 844}

# Latest captured frame (raw PNG/JPEG bytes) written by the UxPlay capture
# thread (screen_airplay). Served to browsers via /ws/screen.
latest_frame = None
frame_mime = "image/jpeg"
capture_size = None  # (width, height) of the most recent frame
_screen_stop = threading.Event()


# ---------- UxPlay window capture (GStreamer ximagesrc) ----------

def _screen_env():
    env = dict(os.environ)
    env.setdefault("DISPLAY", ":0")
    return env


def _find_uxplay_xid():
    """Return the X window id of the UxPlay video window, or None."""
    try:
        out = subprocess.run(
            ["xdotool", "search", "--name", "uxplay"],
            capture_output=True, text=True, timeout=5, env=_screen_env(),
        ).stdout
    except Exception:
        return None
    xids = [line for line in out.split() if line.strip()]
    if not xids:
        return None
    try:
        return int(xids[0], 16) if xids[0].lower().startswith("0x") else int(xids[0])
    except ValueError:
        return None


def _start_capture_thread():
    """Best-effort: starts the GStreamer capture thread using the system gi."""
    try:
        if "gi" not in sys.modules:
            try:
                import gi  # noqa: F401
            except ModuleNotFoundError:
                # menv lacks PyGObject; reuse the distro copy (same ABI).
                sys.path.append("/usr/lib/python3/dist-packages")
                import gi
            gi.require_version("Gst", "1.0")
        from gi.repository import Gst  # noqa: F401
    except Exception as e:
        log.warning("screen capture disabled: %s", e)
        return
    t = threading.Thread(target=_capture_loop, name="uxplay-capture", daemon=True)
    t.start()
    log.info("screen capture thread started")


def _capture_loop():
    global latest_frame, frame_mime, capture_size
    try:
        import gi

        gi.require_version("Gst", "1.0")
        from gi.repository import Gst
    except Exception as e:
        log.warning("capture thread aborted: %s", e)
        return
    Gst.init(None)

    last_good = 0.0
    while not _screen_stop.is_set():
        xid = _find_uxplay_xid()
        if xid is None:
            last_good = 0.0
            time.sleep(1)
            continue

        pipeline = Gst.parse_launch(
            f"ximagesrc xid={xid} use-damage=false ! videoconvert ! "
            "jpegenc quality=82 ! appsink name=sink max-buffers=1 drop=true"
        )
        appsink = pipeline.get_by_name("sink")
        pipeline.set_state(Gst.State.PLAYING)
        log.info("capturing UxPlay window 0x%x", xid)
        t_play = time.time()
        try:
            while not _screen_stop.is_set():
                if _find_uxplay_xid() != xid:
                    log.info("UxPlay window 0x%x gone; re-discovering", xid)
                    break
                sample = appsink.emit("try-pull-sample", 200 * 1_000_000)
                if sample is None:
                    if time.time() - max(t_play, last_good) > 5.0:
                        log.warning("capture stalled on 0x%x; rebuilding", xid)
                        break
                    continue
                buffer = sample.get_buffer()
                ok, info = buffer.map(Gst.MapFlags.READ)
                if ok:
                    data = bytes(info.data)
                    buffer.unmap(info)
                    if data:
                        latest_frame = data
                        frame_mime = "image/jpeg"
                        last_good = time.time()
                        caps = sample.get_caps()
                        s = caps.get_structure(0)
                        capture_size = (s.get_int("width")[1], s.get_int("height")[1])
                else:
                    buffer.unmap(info)
        except Exception as e:
            log.warning("capture error: %s", e)
        finally:
            pipeline.set_state(Gst.State.NULL)
        time.sleep(1)


# ---------- models ----------

class TapRequest(BaseModel):
    x: float
    y: float
    duration: float | None = None


class SwipeRequest(BaseModel):
    from_x: float
    from_y: float
    to_x: float
    to_y: float
    duration: float = 0.2


class TypeRequest(BaseModel):
    text: str


class KeyRequest(BaseModel):
    key: str


class AppRequest(BaseModel):
    bundle_id: str


# ---------- helpers ----------

def _err(e: Exception):
    log.error("runner error: %s", e)
    raise HTTPException(status_code=502, detail=str(e))


# ---------- status / session ----------

@app.get("/api/status")
async def status():
    online = False
    locked = False
    if runner.online:
        try:
            info = await runner.ping()
            online = True
            locked = bool(info.get("locked", False))
        except MiniControlError:
            pass
    return {"runner_online": online, "locked": locked}


@app.post("/api/session")
async def create_session():
    # MiniControl is stateless; kept for UI compatibility.
    return {"sessionId": "minicontrol", "windowSize": WINDOW_SIZE}


@app.delete("/api/session")
async def delete_session():
    return {"ok": True}


# ---------- screen ----------

@app.get("/api/screenshot")
async def screenshot():
    if latest_frame is None:
        raise HTTPException(status_code=503, detail="No video frame captured yet")
    return {"image": base64.b64encode(latest_frame).decode(), "mime": frame_mime}


@app.get("/api/screeninfo")
async def screeninfo():
    return {"windowSize": WINDOW_SIZE, "app": None}

@app.get("/api/captureinfo")
async def captureinfo():
    if capture_size:
        return {"size": list(capture_size), "frame": frame_mime}
    return {"size": None, "frame": None}

# ---------- interactions ----------

@app.post("/api/tap")
async def tap(body: TapRequest):
    try:
        await runner.tap(body.x, body.y)
        return {"ok": True}
    except MiniControlError as e:
        _err(e)


@app.post("/api/swipe")
async def swipe(body: SwipeRequest):
    try:
        await runner.swipe(body.from_x, body.from_y, body.to_x, body.to_y, body.duration)
        return {"ok": True}
    except MiniControlError as e:
        _err(e)


@app.post("/api/type")
async def type_text(body: TypeRequest):
    try:
        await runner.keys(body.text)
        return {"ok": True}
    except MiniControlError as e:
        _err(e)


@app.post("/api/key")
async def key(body: KeyRequest):
    try:
        await runner.keys(body.key)
        return {"ok": True}
    except MiniControlError as e:
        _err(e)


@app.post("/api/home")
async def home():
    try:
        await runner.button("home")
        return {"ok": True}
    except MiniControlError as e:
        _err(e)


@app.post("/api/lock")
async def lock():
    try:
        await runner.button("lock")
        return {"ok": True}
    except MiniControlError as e:
        _err(e)


@app.post("/api/unlock")
async def unlock():
    try:
        await runner.button("unlock")
        return {"ok": True}
    except MiniControlError as e:
        _err(e)


@app.post("/api/app/launch")
async def launch_app(body: AppRequest):
    try:
        await runner.launch(body.bundle_id)
        return {"ok": True}
    except MiniControlError as e:
        _err(e)


@app.post("/api/app/terminate")
async def terminate_app(body: AppRequest):
    try:
        await runner.terminate(body.bundle_id)
        return {"ok": True}
    except MiniControlError as e:
        _err(e)


# ---------- websocket live screen ----------

@app.websocket("/ws/screen")
async def ws_screen(websocket: WebSocket):
    await websocket.accept()
    log.info("WS client connected")
    sent = None
    try:
        while True:
            if latest_frame is not None:
                image = base64.b64encode(latest_frame).decode()
                sent = image
                await websocket.send_json({"type": "frame", "image": image, "mime": frame_mime})
            elif sent != "offline":
                sent = "offline"
                await websocket.send_json({"type": "offline"})
            await asyncio.sleep(0.1)
    except WebSocketDisconnect:
        log.info("WS client disconnected")
    except asyncio.CancelledError:
        pass


# ---------- static ----------

app.mount("/", StaticFiles(directory="static", html=True), name="static")


def main():
    import uvicorn

    uvicorn.run(app, host="0.0.0.0", port=8101)


@app.on_event("startup")
async def _startup():
    _start_capture_thread()
    await runner.start()


@app.on_event("shutdown")
async def _shutdown():
    _screen_stop.set()
    await runner.stop()


if __name__ == "__main__":
    main()
