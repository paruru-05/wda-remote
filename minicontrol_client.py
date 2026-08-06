import asyncio
import contextlib
import json
import logging

import websockets

log = logging.getLogger(__name__)


class MiniControlError(Exception):
    pass


class MiniControlClient:
    """Asyncio WebSocket client for the MiniControl XCUITest runner.

    The runner listens on the device at TCP port 9100; the host port is
    forwarded via `pymobiledevice3 usbmux forward 9100 9100`.
    Commands are JSON: {"command": "...", ...} and are answered in order.
    """

    def __init__(self, url: str = "ws://127.0.0.1:9100", timeout: float = 15.0):
        self.url = url
        self.timeout = timeout
        self.online = False
        self.locked = False
        self._ws = None
        self._lock = asyncio.Lock()
        self._task = None
        self._stopping = False

    # ----- lifecycle -----

    async def start(self):
        self._stopping = False
        self._task = asyncio.create_task(self._run())

    async def stop(self):
        self._stopping = True
        if self._task:
            self._task.cancel()
            with contextlib.suppress(asyncio.CancelledError, Exception):
                await self._task
        if self._ws:
            with contextlib.suppress(Exception):
                await self._ws.close()

    async def _run(self):
        while not self._stopping:
            try:
                self._ws = await asyncio.wait_for(
                    websockets.connect(self.url, open_timeout=self.timeout), self.timeout
                )
                self.online = True
                log.info("MiniControl connected: %s", self.url)
                with contextlib.suppress(Exception):
                    await self._refresh_state()
                await self._ws.wait_closed()
            except asyncio.CancelledError:
                break
            except Exception as e:
                log.warning("MiniControl disconnected: %s", e)
            finally:
                self.online = False
                self._ws = None
            await asyncio.sleep(2)

    async def _refresh_state(self):
        try:
            self.locked = bool((await self.ping()).get("locked", False))
        except Exception:
            pass

    # ----- commands -----

    async def _command(self, payload: dict) -> dict:
        ws = self._ws
        if ws is None:
            raise MiniControlError("MiniControl runner not connected")
        async with self._lock:
            await asyncio.wait_for(ws.send(json.dumps(payload, ensure_ascii=False)), self.timeout)
            raw = await asyncio.wait_for(ws.recv(), self.timeout)
        if isinstance(raw, bytes):
            raw = raw.decode("utf-8", "replace")
        try:
            resp = json.loads(raw)
        except Exception as e:
            raise MiniControlError(f"invalid response: {e}") from e
        if not isinstance(resp, dict) or resp.get("status") != "ok":
            raise MiniControlError(resp.get("message") if isinstance(resp, dict) else "runner error")
        return resp.get("result") or {}

    async def ping(self) -> dict:
        resp = await self._command({"command": "ping"})
        self.locked = bool(resp.get("locked", False))
        return resp

    async def tap(self, x: float, y: float):
        await self._command({"command": "tap", "x": x, "y": y})

    async def swipe(self, fx: float, fy: float, tx: float, ty: float, duration: float = 0.2):
        await self._command(
            {"command": "swipe", "fx": fx, "fy": fy, "tx": tx, "ty": ty, "duration": duration}
        )

    async def keys(self, text: str):
        await self._command({"command": "keys", "text": text})

    async def button(self, name: str):
        await self._command({"command": "button", "button": name})

    async def launch(self, bundle_id: str):
        await self._command({"command": "launch", "bundle_id": bundle_id})

    async def terminate(self, bundle_id: str):
        await self._command({"command": "terminate", "bundle_id": bundle_id})
