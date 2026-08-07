import json
import logging

from fastapi.testclient import TestClient

from app.logging import JsonFormatter, request_id_context
from app.main import app


def test_health_endpoints() -> None:
    with TestClient(app) as client:
        assert client.get("/health/live").json() == {"status": "ok"}
        assert client.get("/health/ready").json() == {"status": "ready"}
    assert app.state.ready is False


def test_request_id_is_preserved() -> None:
    with TestClient(app) as client:
        response = client.get("/health/live", headers={"x-request-id": "test-123"})
    assert response.headers["x-request-id"] == "test-123"


def test_request_id_is_generated() -> None:
    with TestClient(app) as client:
        response = client.get("/health/live")
    assert response.headers["x-request-id"]


def test_metrics_are_prometheus_text() -> None:
    with TestClient(app) as client:
        response = client.get("/metrics")
    assert response.status_code == 200
    assert "http_requests_total" in response.text
    assert response.headers["content-type"].startswith("text/plain")


def test_log_formatter_emits_json_with_request_id() -> None:
    token = request_id_context.set("correlation-123")
    try:
        record = logging.LogRecord("test", logging.INFO, __file__, 1, "hello", (), None)
        payload = json.loads(JsonFormatter().format(record))
    finally:
        request_id_context.reset(token)
    assert payload["message"] == "hello"
    assert payload["request_id"] == "correlation-123"
