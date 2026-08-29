from fastapi.testclient import TestClient


SAMPLE_CSV = """Date,Action,Ticker,Quantity,Price,Currency,Name
2025-01-02,BUY,AAPL,3,200,USD,Apple Inc.
2025-02-03,SELL,AAPL,1,220,USD,Apple Inc.
"""


def test_csv_import_accepts_valid_file(monkeypatch, tmp_path):
    from app.main import app
    from app.routes import import_csv

    monkeypatch.setattr(import_csv, "V2_DIR", tmp_path)
    monkeypatch.setattr(import_csv, "demo_mode", lambda: False)
    response = TestClient(app).post(
        "/api/import-csv",
        files={"file": ("transactions.csv", SAMPLE_CSV, "text/csv")},
    )

    assert response.status_code == 200
    payload = response.json()
    assert payload["ok"] is True
    assert payload["transactions_count"] == 2
    assert payload["holdings_count"] == 1
    assert payload["holdings"][0]["shares"] == 2
    assert (tmp_path / "portfolio_analysis.json").exists()


def test_csv_import_rejects_writes_in_demo_mode(monkeypatch, tmp_path):
    from app.main import app
    from app.routes import import_csv

    monkeypatch.setattr(import_csv, "V2_DIR", tmp_path)
    monkeypatch.setattr(import_csv, "demo_mode", lambda: True)
    response = TestClient(app).post(
        "/api/import-csv",
        files={"file": ("transactions.csv", SAMPLE_CSV, "text/csv")},
    )

    assert response.status_code == 403
    assert response.json()["ok"] is False
    assert not (tmp_path / "portfolio_analysis.json").exists()


def test_csv_import_rejects_non_csv_and_oversized_files(monkeypatch, tmp_path):
    from app.main import app
    from app.routes import import_csv

    monkeypatch.setattr(import_csv, "V2_DIR", tmp_path)
    monkeypatch.setattr(import_csv, "demo_mode", lambda: False)
    client = TestClient(app)

    wrong_type = client.post(
        "/api/import-csv",
        files={"file": ("transactions.txt", SAMPLE_CSV, "text/plain")},
    )
    assert wrong_type.status_code == 400

    oversized = client.post(
        "/api/import-csv",
        files={"file": ("large.csv", b"x" * (5 * 1024 * 1024 + 1), "text/csv")},
    )
    assert oversized.status_code == 413
    assert not (tmp_path / "portfolio_analysis.json").exists()


def test_csv_import_backs_up_existing_portfolio(monkeypatch, tmp_path):
    from app.main import app
    from app.routes import import_csv

    original_portfolio = '{"summary":{"source":"original"}}'
    original_broker = '{"source":"original"}'
    (tmp_path / "portfolio_analysis.json").write_text(original_portfolio, encoding="utf-8")
    (tmp_path / "trading212_data.json").write_text(original_broker, encoding="utf-8")
    monkeypatch.setattr(import_csv, "V2_DIR", tmp_path)
    monkeypatch.setattr(import_csv, "demo_mode", lambda: False)

    response = TestClient(app).post(
        "/api/import-csv",
        files={"file": ("transactions.csv", SAMPLE_CSV, "text/csv")},
    )

    assert response.status_code == 200
    assert response.json()["backup_created"] is True
    backup_dirs = list((tmp_path / "csv_import_backups").iterdir())
    assert len(backup_dirs) == 1
    assert (backup_dirs[0] / "portfolio_analysis.json").read_text(encoding="utf-8") == original_portfolio
    assert (backup_dirs[0] / "trading212_data.json").read_text(encoding="utf-8") == original_broker
