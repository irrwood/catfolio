from fastapi.testclient import TestClient
from fastapi import FastAPI
from app.routes.analyst_history import router
from app import analyst_history as data
import pytest
app = FastAPI()
app.include_router(router)
client = TestClient(app)

def test_shared_shell():
    r = client.get('/analyst-history?ui=v5')
    assert r.status_code == 200
    for contract in ('v5-shell','design-system.css','analyst-history.js','原始数据没有个人分析师姓名'):
        assert contract in r.text

@pytest.mark.parametrize('query',['horizon=22','direction=BUY','offset=-1'])
def test_invalid_parameters(query):
    assert client.get('/api/analyst-history/events?institution=x&'+query).status_code == 422

def test_missing_archive(monkeypatch,tmp_path):
    monkeypatch.setattr(data,'ROOT',tmp_path)
    assert client.get('/api/analyst-history/summary').status_code == 503

def test_filter_and_page(monkeypatch):
    monkeypatch.setattr(data,'release_path',lambda:'/demo')
    monkeypatch.setattr(data,'institution_events',lambda *args:[{'symbol':'NVDA','id':i} for i in range(25)]+[{'symbol':'AAPL','id':26}])
    r=client.get('/api/analyst-history/events?institution=x&ticker=nvda&offset=20').json()
    assert r['total']==25
    assert len(r['items'])==5
    assert r['items'][0]['id']==20
