"""Validate source rating counts and join price observations on exact date labels."""
import csv
import io
from datetime import datetime


def parse_ratings(raw, prices):
    price_by_date = {p['chartDateLabel']:p['sourceChartSharePrice'] for p in prices}
    rows=[]; seen=set()
    for r in csv.DictReader(io.StringIO(raw)):
        date=datetime.strptime(r['Date'],'%m/%d/%Y').date().isoformat()
        if date in seen:
            raise ValueError('Duplicate rating date')
        seen.add(date)
        counts={key:int(r[key]) for key in ('Sell','Hold','Buy','StrongBuy','TotalRatings')}
        if any(v<0 for v in counts.values()) or sum(counts[k] for k in ('Sell','Hold','Buy','StrongBuy'))!=counts['TotalRatings']:
            raise ValueError('Invalid rating counts')
        rows.append(dict(chartDateLabel=date,**counts,sourceChartSharePrice=price_by_date.get(date)))
    return sorted(rows,key=lambda r:r['chartDateLabel'])
