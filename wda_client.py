import base64
import logging

import httpx

log = logging.getLogger(__name__)


class WdaError(Exception):
    pass


class WdaClient:
    def __init__(self, base_url: str = "http://localhost:8100", timeout: float = 30.0):
        self.base_url = base_url.rstrip("/")
        self.timeout = timeout
        self.session_id = None
        self._client = httpx.Client(timeout=timeout)

    def _url(self, path: str) -> str:
        return f"{self.base_url}{path}"

    def _request(self, method: str, path: str, **kwargs):
        try:
            resp = self._client.request(method, self._url(path), **kwargs)
        except httpx.HTTPError as e:
            raise WdaError(f"WDA connection failed: {e}") from e
        if resp.status_code >= 400:
            detail = resp.text[:500]
            raise WdaError(f"WDA error {resp.status_code} on {method} {path}: {detail}")
        return resp

    def _session_request(self, method: str, path: str, **kwargs):
        if not self.session_id:
            raise WdaError("No active WDA session. Call create_session() first.")
        p = f"/session/{self.session_id}{path}"
        return self._request(method, p, **kwargs)

    # ----- session management -----

    def status(self) -> dict:
        resp = self._request("GET", "/status")
        return resp.json()

    def create_session(self, bundle_id: str | None = None) -> str:
        caps = {
            "alwaysMatch": {
                "platformName": "iOS",
                "automationName": "XCUITest",
            }
        }
        if bundle_id:
            caps["alwaysMatch"]["bundleId"] = bundle_id
        body = {"capabilities": caps}
        resp = self._request("POST", "/session", json=body)
        data = resp.json()
        value = data.get("value") or {}
        sid = value.get("sessionId") or data.get("sessionId")
        if not sid:
            raise WdaError(f"Could not create session: {data}")
        self.session_id = sid
        log.info("Session created: %s", sid)
        return sid

    def delete_session(self):
        if not self.session_id:
            return
        try:
            self._request("DELETE", f"/session/{self.session_id}")
        except WdaError:
            pass
        self.session_id = None

    # ----- screen info & screenshot -----

    def window_size(self) -> dict:
        resp = self._session_request("GET", "/window/size")
        return resp.json().get("value", {})

    def screenshot_base64(self) -> str:
        resp = self._session_request("GET", "/screenshot")
        return resp.json().get("value", "")

    def screenshot_png(self) -> bytes:
        b64 = self.screenshot_base64()
        return base64.b64decode(b64)

    def source(self) -> str:
        resp = self._session_request("GET", "/source")
        return resp.json().get("value", "")

    def active_app(self) -> dict:
        resp = self._session_request("GET", "/wda/activeAppInfo")
        return resp.json().get("value", {})

    # ----- interactions -----

    def tap(self, x: float, y: float):
        self._session_request("POST", "/wda/tap", json={"x": x, "y": y})

    def tap_duration(self, x: float, y: float, duration: float):
        self._session_request(
            "POST", "/wda/touchAndHold",
            json={"x": x, "y": y, "duration": duration},
        )

    def swipe(self, from_x, from_y, to_x, to_y, duration: float = 0.2):
        body = {
            "actions": [
                {
                    "type": "pointer",
                    "id": "finger1",
                    "parameters": {"pointerType": "touch"},
                    "actions": [
                        {"type": "pointerMove", "duration": 0, "origin": "viewport", "x": round(from_x), "y": round(from_y)},
                        {"type": "pointerDown", "button": 0},
                        {"type": "pause", "duration": 50},
                        {"type": "pointerMove", "duration": int(duration * 1000), "origin": "viewport", "x": round(to_x), "y": round(to_y)},
                        {"type": "pointerUp", "button": 0},
                    ],
                }
            ]
        }
        self._session_request("POST", "/actions", json=body)

    def type_text(self, text: str):
        for chunk in self._chunks(text):
            self._session_request("POST", "/wda/keys", json={"value": list(chunk)})

    def press_key(self, key: str):
        self._session_request("POST", "/wda/keys", json={"value": [key]})

    def _chunks(self, text: str, size: int = 200):
        return [text[i : i + size] for i in range(0, len(text), size)]

    def clear_text(self):
        self.press_key("\\ue003")

    def home(self):
        self._request("POST", "/wda/homescreen")

    def lock(self):
        self._request("POST", "/wda/lock")

    def unlock(self):
        self._request("POST", "/wda/unlock")

    # ----- apps -----

    def launch_app(self, bundle_id: str):
        self._session_request("POST", "/wda/apps/launch", json={"bundleId": bundle_id})

    def terminate_app(self, bundle_id: str):
        self._session_request("POST", "/wda/apps/terminate", json={"bundleId": bundle_id})

    def app_state(self, bundle_id: str) -> int:
        resp = self._session_request("POST", "/wda/apps/state", json={"bundleId": bundle_id})
        return resp.json().get("value", 0)

    # ----- element interaction -----

    def find_element(self, using: str, value: str):
        resp = self._session_request(
            "POST", "/element",
            json={"using": using, "value": value},
        )
        val = resp.json().get("value")
        if not val or not val.get("ELEMENT"):
            return None
        return val["ELEMENT"]

    def element_tap(self, element_id: str):
        self._session_request("POST", f"/element/{element_id}/click")

    def close(self):
        try:
            self.delete_session()
        finally:
            self._client.close()

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()
