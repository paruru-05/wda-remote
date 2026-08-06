import asyncio
import base64
import contextlib
import io
import logging

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
# video window is letterboxed to the same aspect ratio.
WINDOW_SIZE = {"width": 390, "height": 844}

# Latest captured frame (raw PNG/JPEG bytes) written by the UxPlay capture
# thread (screen_airplay). Served to browsers via /ws/screen.
latest_frame = None
frame_mime = "image/jpeg"


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
    await runner.start()


@app.on_event("shutdown")
async def _shutdown():
    await runner.stop()


if __name__ == "__main__":
    main()
