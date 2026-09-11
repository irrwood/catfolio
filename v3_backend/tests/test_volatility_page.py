from pathlib import Path
from fastapi.testclient import TestClient
from app.main import app
from app import volatility

client = TestClient(app)

def test_shared_shell_and_mobile_contract():
    response = client.get('/sentiment?ui=v5')
    assert response.status_code == 200
    for text in ('design-system.css', 'v5-shell', 'volatility.css', 'volatility.js', 'sentiment-meter', 'Today Insight'):
        assert text in response.text
    css = (Path(__file__).resolve().parents[1] / 'app/static/volatility.css').read_text()
    assert '@media(max-width:700px)' in css
    assert 'prefers-reduced-motion' in css

def test_missing_snapshot(monkeypatch, tmp_path):
    monkeypatch.setattr(volatility, 'DATA', tmp_path / 'absent.json')
    response = client.get('/api/volatility/semiconductors')
    assert response.status_code == 200
    assert response.json()['status'] == 'unavailable'
    assert response.json()['score'] is None

def test_home_insight():
    response = client.get('/lab?ui=v5')
    assert 'today-volatility-insight' in response.text
    assert 'href="/sentiment"' in response.text
