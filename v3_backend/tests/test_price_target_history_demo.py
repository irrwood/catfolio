import json
from pathlib import Path
import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient
from app.routes import price_target_history as route
app=FastAPI();app.include_router(route.router);client=TestClient(app)

@pytest.fixture
def catalog(monkeypatch,tmp_path):
    path=tmp_path/'catalog.json'
    point=dict(date='2026-09-01',price=120.25,low=100.,mean=130.,high=150.,sell=1,hold=2,buy=3,strongBuy=4)
    path.write_text(json.dumps({'entries':{s:dict(symbol=s,currency='USD',name=s,exchange='NASDAQ',sourceURL='https://www.marketbeat.com/',retrievedOn='2026-09-09',status='AVAILABLE',warnings=[],points=[dict(point,price=p)]) for s,p in [('AAPL',120.25),('MSFT',400.50)]}}))
    monkeypatch.setattr(route,'CATALOG',path)

def test_shared_chart_shell(catalog):
    r=client.get('/price-target-history?ui=v5&symbol=MSFT')
    assert r.status_code==200
    for token in ['design-system.css','v5-shell','pt-chart','echarts.min.js','MSFT每月股价目标']:
        assert token in r.text
    assert '苹果公司' not in r.text

def test_symbols_never_share_prices(catalog):
    for symbol,expected in [('AAPL',120.25),('MSFT',400.50)]:
        assert client.get('/api/price-target-history?symbol='+symbol).json()['records'][0]['sourceChartSharePrice']==expected
        d=client.get('/api/ratings-history?symbol='+symbol).json()['records'][0]
        assert d['sourceChartSharePrice']==expected and d['TotalRatings']==10
    assert client.get('/api/price-target-history?symbol=UNKNOWN').status_code==404

def test_missing_data(monkeypatch,tmp_path):
    monkeypatch.setattr(route,'CATALOG',tmp_path/'missing.json')
    assert client.get('/api/price-target-history').status_code==503

def test_unknown_and_currency(catalog):
    for query in ('symbol=UNKNOWN','symbol=AAPL&currency=EUR','symbol=%3Cscript%3E'):
        r=client.get('/price-target-history?'+query)
        assert '暂无该证券的历史数据' in r.text
        assert 'id="pt-chart"' not in r.text
        assert '<SCRIPT> · 历史分析' not in r.text

def test_desktop_link_contract():
    js=(Path(__file__).resolve().parents[1]/'app/static/portfolio-holdings.js').read_text()
    assert 'href="/price-target-history?symbol=${encodeURIComponent(row.ticker' in js
