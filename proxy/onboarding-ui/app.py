"""Admin onboarding service: issues LiteLLM keys and the onboarding file that bootstrap.ps1 consumes.

Runs behind Caddy, which enforces basic auth on /admin/onboarding/*, strips that prefix and sets
X-Admin-User. Talks to LiteLLM on the internal network with the master key; the browser only ever
sees a newly issued user key, once, inside the onboarding file.
"""
import base64
import hashlib
import os
import re
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urlsplit

import httpx
from fastapi import Depends, FastAPI, HTTPException, Request
from fastapi.responses import FileResponse
from pydantic import BaseModel

ONBOARDING_FORMAT = "agentic-coding-onboarding/1"
ISSUED_VIA = "onboarding-ui"
EMAIL = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")
# Used when a model in litellm-config.yaml has no model_info limits.
FALLBACK_CONTEXT, FALLBACK_OUTPUT = 8192, 4096
STATIC = Path(__file__).parent / "static"


class Settings(BaseModel):
    master_key: str
    public_proxy_url: str
    litellm_url: str = "http://litellm:4000"
    ca_cert_path: Path = Path("/certs/proxy-root-ca.crt")
    bootstrap_path: Path = Path("/app/bootstrap.ps1")
    opencode_version: str = "2.0.29"
    default_model: str | None = None
    max_parallel_requests: int = 2

    @classmethod
    def from_env(cls) -> "Settings":
        env = os.environ
        return cls(
            master_key=env["LITELLM_MASTER_KEY"],
            public_proxy_url=env["PUBLIC_PROXY_URL"].rstrip("/"),
            litellm_url=env.get("LITELLM_URL", "http://litellm:4000"),
            ca_cert_path=Path(env.get("CA_CERT_PATH", "/certs/proxy-root-ca.crt")),
            bootstrap_path=Path(env.get("BOOTSTRAP_PATH", "/app/bootstrap.ps1")),
            opencode_version=env.get("OPENCODE_VERSION", "2.0.29"),
            default_model=env.get("DEFAULT_MODEL") or None,
            max_parallel_requests=int(env.get("MAX_PARALLEL_REQUESTS", "2")),
        )


class EmailRequest(BaseModel):
    email: str


def ca_fingerprint(pem: str) -> str:
    """SHA-256 of the certificate's DER bytes, as AA:BB:... (the form export-ca.ps1 prints)."""
    match = re.search(r"-----BEGIN CERTIFICATE-----(.+?)-----END CERTIFICATE-----", pem, re.S)
    if not match:
        raise ValueError("not a PEM certificate")
    der = base64.b64decode("".join(match.group(1).split()))
    return ":".join(f"{b:02X}" for b in hashlib.sha256(der).digest())


def normalise_email(email: str) -> str:
    email = email.strip().lower()
    if not EMAIL.match(email):
        raise HTTPException(422, f"'{email}' is not a valid email address")
    return email


def same_origin_json(request: Request) -> None:
    """CSRF guard for the state-changing endpoints. Basic-auth credentials are sent by the browser
    automatically, so a page on another site must not be able to trigger these. Requiring JSON forces
    a CORS preflight (which we never answer), and an Origin header, when present, must match Host."""
    if request.headers.get("content-type", "").split(";")[0].strip() != "application/json":
        raise HTTPException(415, "expected application/json")
    origin = request.headers.get("origin")
    if origin and urlsplit(origin).netloc != request.headers.get("host"):
        raise HTTPException(403, "cross-origin request refused")


def create_app(settings: Settings, transport: httpx.AsyncBaseTransport | None = None) -> FastAPI:
    app = FastAPI(title="Agentic coding onboarding", docs_url=None, redoc_url=None, openapi_url=None)
    litellm = httpx.AsyncClient(
        base_url=settings.litellm_url,
        headers={"Authorization": f"Bearer {settings.master_key}"},
        timeout=30,
        transport=transport,
    )

    async def call(method: str, path: str, **kwargs) -> dict:
        try:
            response = await litellm.request(method, path, **kwargs)
        except httpx.HTTPError as exc:
            raise HTTPException(502, f"LiteLLM unreachable: {exc}") from exc
        if response.status_code >= 400:
            try:
                body = response.json()
                message = (body.get("error") or {}).get("message") or body.get("detail") or response.text
            except ValueError:
                message = response.text
            status = 409 if "already exists" in str(message) else 502
            raise HTTPException(status, f"LiteLLM {path}: {message}")
        return response.json()

    def read_ca() -> dict:
        try:
            pem = settings.ca_cert_path.read_text()
            return {"fingerprint": ca_fingerprint(pem), "error": None}
        except (OSError, ValueError) as exc:
            return {"fingerprint": None, "error": f"{settings.ca_cert_path}: {exc}. Run proxy/scripts/export-ca.ps1 on the proxy host."}

    async def list_models() -> list[dict]:
        models, seen = [], set()
        for entry in (await call("GET", "/model/info")).get("data", []):
            name = entry.get("model_name")
            if not name or name in seen:
                continue
            seen.add(name)
            info = entry.get("model_info") or {}
            models.append({
                "id": name,
                "name": f"{name} (via LiteLLM proxy)",
                "context": int(info.get("max_input_tokens") or FALLBACK_CONTEXT),
                "output": int(info.get("max_tokens") or FALLBACK_OUTPUT),
            })
        return models

    async def prepare() -> tuple[dict, list[dict], str]:
        """Everything the onboarding file needs besides the key, checked before any key changes."""
        ca = read_ca()
        if ca["error"]:
            raise HTTPException(503, ca["error"])
        models = await list_models()
        if not models:
            raise HTTPException(503, "LiteLLM serves no models")
        default = settings.default_model or models[0]["id"]
        if default not in {m["id"] for m in models}:
            raise HTTPException(503, f"DEFAULT_MODEL '{default}' is not served by LiteLLM")
        return ca, models, default

    async def issue(email: str, admin: str, prepared: tuple[dict, list[dict], str]) -> dict:
        ca, models, default = prepared
        key = await call("POST", "/key/generate", json={
            "user_id": email,
            "key_alias": email,
            "max_parallel_requests": settings.max_parallel_requests,
            "metadata": {"issued_via": ISSUED_VIA, "issued_by": admin},
        })
        return {
            "format": ONBOARDING_FORMAT,
            "email": email,
            "issued_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "proxy_url": settings.public_proxy_url,
            "ca_fingerprint_sha256": ca["fingerprint"],
            "api_key": key["key"],
            "opencode_version": settings.opencode_version,
            "default_model": default,
            "models": models,
        }

    def admin_user(request: Request) -> str:
        return request.headers.get("x-admin-user") or "unknown"

    @app.get("/", include_in_schema=False)
    async def index():
        return FileResponse(STATIC / "index.html", headers={"Cache-Control": "no-store"})

    # The developer script, sent along with the onboarding file. Served here (behind admin auth) rather
    # than publicly, so it reaches developers through the same private channel as their key.
    @app.get("/bootstrap.ps1", include_in_schema=False)
    async def bootstrap():
        if not settings.bootstrap_path.is_file():
            raise HTTPException(404, f"{settings.bootstrap_path} not found; check the bootstrap.ps1 volume in docker-compose.yaml")
        return FileResponse(settings.bootstrap_path, media_type="text/plain", filename="bootstrap.ps1",
                            headers={"Cache-Control": "no-store"})

    @app.get("/api/status")
    async def status():
        ca = read_ca()
        try:
            models, models_error = await list_models(), None
        except HTTPException as exc:
            models, models_error = [], exc.detail
        return {
            "public_proxy_url": settings.public_proxy_url,
            "opencode_version": settings.opencode_version,
            "bootstrap_available": settings.bootstrap_path.is_file(),
            "default_model": settings.default_model or (models[0]["id"] if models else None),
            "ca_fingerprint_sha256": ca["fingerprint"],
            "ca_error": ca["error"],
            "models": models,
            "models_error": models_error,
        }

    @app.get("/api/keys")
    async def keys():
        rows, page = [], 1
        while True:
            body = await call("GET", "/key/list", params={"return_full_object": "true", "size": 100, "page": page})
            for k in body.get("keys", []):
                if not isinstance(k, dict):
                    continue
                meta = k.get("metadata") or {}
                rows.append({
                    "alias": k.get("key_alias"),
                    "user_id": k.get("user_id"),
                    "created_at": k.get("created_at"),
                    "last_active": k.get("last_active"),
                    "spend": k.get("spend") or 0,
                    "max_parallel_requests": k.get("max_parallel_requests"),
                    "blocked": bool(k.get("blocked")),
                    "issued_via": meta.get("issued_via"),
                    "issued_by": meta.get("issued_by"),
                })
            if page >= (body.get("total_pages") or 1):
                break
            page += 1
        return {"keys": rows}

    @app.post("/api/keys", dependencies=[Depends(same_origin_json)])
    async def create_key(req: EmailRequest, admin: str = Depends(admin_user)):
        email = normalise_email(req.email)
        return await issue(email, admin, await prepare())

    @app.post("/api/keys/revoke", dependencies=[Depends(same_origin_json)])
    async def revoke_key(req: EmailRequest):
        email = normalise_email(req.email)
        await call("POST", "/key/delete", json={"key_aliases": [email]})
        return {"revoked": email}

    @app.post("/api/keys/reissue", dependencies=[Depends(same_origin_json)])
    async def reissue_key(req: EmailRequest, admin: str = Depends(admin_user)):
        email = normalise_email(req.email)
        prepared = await prepare()  # fail before revoking if a new file can't be built
        await call("POST", "/key/delete", json={"key_aliases": [email]})
        return await issue(email, admin, prepared)

    @app.get("/healthz", include_in_schema=False)
    async def healthz():
        return {"ok": True}

    return app


def app_from_env() -> FastAPI:
    return create_app(Settings.from_env())
