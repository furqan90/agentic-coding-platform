import base64
import hashlib
import json

import httpx
import pytest
from fastapi.testclient import TestClient

from app import ONBOARDING_FORMAT, Settings, ca_fingerprint, create_app

DER = bytes(range(256)) * 3  # ca_fingerprint hashes the DER bytes; it doesn't parse them
PEM = "-----BEGIN CERTIFICATE-----\n" + base64.encodebytes(DER).decode() + "-----END CERTIFICATE-----\n"
FINGERPRINT = ":".join(f"{b:02X}" for b in hashlib.sha256(DER).digest())


class FakeLiteLLM:
    """In-memory stand-in for the LiteLLM admin endpoints the service uses."""

    def __init__(self, models=None):
        self.keys = {}
        self.calls = []
        self.models = models if models is not None else [
            {"model_name": "qwen3-coder:30b-32k", "model_info": {"max_input_tokens": 32768, "max_tokens": 4096}},
            {"model_name": "qwen3-coder:30b-32k", "model_info": {}},  # second deployment, same name
        ]

    def handler(self, request: httpx.Request) -> httpx.Response:
        assert request.headers["authorization"] == "Bearer sk-master"
        body = json.loads(request.content) if request.content else None
        self.calls.append((request.method, request.url.path, body))
        if request.url.path == "/model/info":
            return httpx.Response(200, json={"data": self.models})
        if request.url.path == "/key/generate":
            alias = body["key_alias"]
            if alias in self.keys:
                return httpx.Response(400, json={"error": {"message": f"Key with alias '{alias}' already exists."}})
            self.keys[alias] = {"key_alias": alias, "user_id": body["user_id"], "metadata": body["metadata"],
                                "max_parallel_requests": body["max_parallel_requests"], "spend": 0.5,
                                "created_at": "2026-11-11T10:00:00Z"}
            return httpx.Response(200, json={"key": f"sk-new-{len(self.calls)}", "key_alias": alias})
        if request.url.path == "/key/delete":
            for alias in body["key_aliases"]:
                self.keys.pop(alias, None)
            return httpx.Response(200, json={"deleted_keys": body["key_aliases"]})
        if request.url.path == "/key/list":
            page = int(request.url.params["page"])
            items = sorted(self.keys.values(), key=lambda k: k["key_alias"])
            return httpx.Response(200, json={"keys": items[(page - 1):page], "total_pages": max(len(items), 1)})
        return httpx.Response(404, json={"detail": "not found"})

    def generated(self):
        return [body for method, path, body in self.calls if path == "/key/generate"]

    def deleted(self):
        return [body for method, path, body in self.calls if path == "/key/delete"]


@pytest.fixture
def ca_file(tmp_path):
    path = tmp_path / "proxy-root-ca.crt"
    path.write_text(PEM)
    return path


def make_client(ca_path, fake=None, **overrides):
    fake = fake or FakeLiteLLM()
    settings = Settings(master_key="sk-master", public_proxy_url="https://172.19.50.206", ca_cert_path=ca_path, **overrides)
    client = TestClient(create_app(settings, httpx.MockTransport(fake.handler)), base_url="https://172.19.50.206")
    return client, fake


JSON = {"Content-Type": "application/json"}


def test_fingerprint_matches_export_ca_format():
    assert ca_fingerprint(PEM) == FINGERPRINT
    assert len(FINGERPRINT.split(":")) == 32


def test_issue_returns_onboarding_file(ca_file):
    client, fake = make_client(ca_file)
    r = client.post("/api/keys", json={"email": " Alice@Corp.Example "}, headers={"X-Admin-User": "admin"})
    assert r.status_code == 200, r.text
    f = r.json()
    assert f["format"] == ONBOARDING_FORMAT
    assert f["email"] == "alice@corp.example"
    assert f["proxy_url"] == "https://172.19.50.206"
    assert f["ca_fingerprint_sha256"] == FINGERPRINT
    assert f["api_key"].startswith("sk-new-")
    assert f["default_model"] == "qwen3-coder:30b-32k"
    assert f["models"] == [{"id": "qwen3-coder:30b-32k", "name": "qwen3-coder:30b-32k (via LiteLLM proxy)", "context": 32768, "output": 4096}]
    assert fake.generated() == [{"user_id": "alice@corp.example", "key_alias": "alice@corp.example", "max_parallel_requests": 2,
                                 "metadata": {"issued_via": "onboarding-ui", "issued_by": "admin"}}]


def test_duplicate_email_is_a_conflict(ca_file):
    client, _ = make_client(ca_file)
    assert client.post("/api/keys", json={"email": "bob@corp.example"}).status_code == 200
    r = client.post("/api/keys", json={"email": "BOB@corp.example"})
    assert r.status_code == 409
    assert "already exists" in r.json()["detail"]


def test_invalid_email_rejected(ca_file):
    client, fake = make_client(ca_file)
    assert client.post("/api/keys", json={"email": "not-an-email"}).status_code == 422
    assert fake.generated() == []


@pytest.mark.parametrize("path", ["/api/keys", "/api/keys/revoke", "/api/keys/reissue"])
def test_csrf_guard(ca_file, path):
    client, fake = make_client(ca_file)
    form = client.post(path, content="email=x@corp.example", headers={"Content-Type": "application/x-www-form-urlencoded"})
    assert form.status_code == 415
    foreign = client.post(path, json={"email": "x@corp.example"}, headers={"Origin": "https://evil.example"})
    assert foreign.status_code == 403
    assert fake.generated() == [] and fake.deleted() == []


def test_same_origin_post_allowed(ca_file):
    client, _ = make_client(ca_file)
    r = client.post("/api/keys", json={"email": "carol@corp.example"}, headers={"Origin": "https://172.19.50.206"})
    assert r.status_code == 200


def test_missing_ca_blocks_issuing_and_reports_status(tmp_path):
    client, fake = make_client(tmp_path / "missing.crt")
    r = client.post("/api/keys", json={"email": "dan@corp.example"})
    assert r.status_code == 503
    assert "export-ca.ps1" in r.json()["detail"]
    assert fake.generated() == []
    status = client.get("/api/status").json()
    assert status["ca_fingerprint_sha256"] is None and "export-ca.ps1" in status["ca_error"]


def test_reissue_revokes_then_issues(ca_file):
    client, fake = make_client(ca_file)
    first = client.post("/api/keys", json={"email": "erin@corp.example"}).json()
    second = client.post("/api/keys/reissue", json={"email": "erin@corp.example"}).json()
    assert second["api_key"] != first["api_key"]
    assert fake.deleted() == [{"key_aliases": ["erin@corp.example"]}]
    assert list(fake.keys) == ["erin@corp.example"]


def test_reissue_keeps_old_key_when_new_file_cannot_be_built(ca_file):
    client, fake = make_client(ca_file)
    client.post("/api/keys", json={"email": "frank@corp.example"})
    ca_file.unlink()
    assert client.post("/api/keys/reissue", json={"email": "frank@corp.example"}).status_code == 503
    assert fake.deleted() == []
    assert "frank@corp.example" in fake.keys


def test_revoke(ca_file):
    client, fake = make_client(ca_file)
    client.post("/api/keys", json={"email": "gina@corp.example"})
    assert client.post("/api/keys/revoke", json={"email": "gina@corp.example"}).json() == {"revoked": "gina@corp.example"}
    assert fake.keys == {}


def test_list_keys_pages_through_all(ca_file):
    client, _ = make_client(ca_file)
    for name in ("hank", "ivy", "jo"):
        client.post("/api/keys", json={"email": f"{name}@corp.example"}, headers={"X-Admin-User": "admin"})
    keys = client.get("/api/keys").json()["keys"]
    assert [k["alias"] for k in keys] == ["hank@corp.example", "ivy@corp.example", "jo@corp.example"]
    assert keys[0]["issued_via"] == "onboarding-ui" and keys[0]["issued_by"] == "admin"


def test_missing_model_limits_use_fallback(ca_file):
    fake = FakeLiteLLM(models=[{"model_name": "small-model", "model_info": {}}])
    client, _ = make_client(ca_file, fake)
    f = client.post("/api/keys", json={"email": "kim@corp.example"}).json()
    assert f["models"][0]["context"] == 8192 and f["models"][0]["output"] == 4096


def test_unknown_default_model_blocks_issuing(ca_file):
    client, fake = make_client(ca_file, default_model="no-such-model")
    assert client.post("/api/keys", json={"email": "lee@corp.example"}).status_code == 503
    assert fake.generated() == []


def test_bootstrap_script_served(ca_file, tmp_path):
    script = tmp_path / "bootstrap.ps1"
    script.write_text("# bootstrap\n")
    client, _ = make_client(ca_file, bootstrap_path=script)
    r = client.get("/bootstrap.ps1")
    assert r.status_code == 200 and r.text == "# bootstrap\n"
    assert 'filename="bootstrap.ps1"' in r.headers["content-disposition"]
    assert client.get("/api/status").json()["bootstrap_available"] is True


def test_missing_bootstrap_script(ca_file, tmp_path):
    client, _ = make_client(ca_file, bootstrap_path=tmp_path / "missing.ps1")
    assert client.get("/bootstrap.ps1").status_code == 404
    assert client.get("/api/status").json()["bootstrap_available"] is False


def test_index_served(ca_file):
    client, _ = make_client(ca_file)
    r = client.get("/")
    assert r.status_code == 200 and "Developer onboarding" in r.text
