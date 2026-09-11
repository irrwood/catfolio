import pytest
from app.ratings_history import parse_ratings
HEADER='Date,Sell,Hold,Buy,StrongBuy,TotalRatings,\n'

def test_exact_join_and_missing_price():
    rows=parse_ratings(HEADER+'09/01/2026,4,12,22,1,39,\n08/01/2026,2,10,22,1,35,\n',[{'chartDateLabel':'2026-09-01','sourceChartSharePrice':318.75}])
    assert rows[0]['sourceChartSharePrice'] is None
    assert rows[1]['sourceChartSharePrice']==318.75
    assert rows[1]['TotalRatings']==39

@pytest.mark.parametrize('body',['09/01/2026,4,12,22,1,38,\n','09/01/2026,-1,12,22,1,34,\n','09/01/2026,4,12,22,1,39,\n09/01/2026,4,12,22,1,39,\n'])
def test_invalid_counts_and_duplicates(body):
    with pytest.raises(ValueError):parse_ratings(HEADER+body,[])
