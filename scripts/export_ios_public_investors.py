"""Project a published Core release into the offline iOS disclosure catalog."""
import argparse
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
POSITION_FIELDS = ('positionId', 'issuerName', 'ticker', 'cusip', 'securityId', 'shares', 'reportedValue', 'reportedValueLow', 'reportedValueHigh', 'weight', 'owner', 'option', 'confidence', 'securityIdentityRole')
ACTIVITY_FIELDS = ('activityId', 'investorId', 'type', 'exactDate', 'periodStart', 'periodEnd', 'shares', 'sharesDelta', 'amount', 'amountLow', 'amountHigh', 'owner', 'ticker', 'issuerName', 'cusip', 'option', 'confidence', 'eventNature', 'sourceId')

def pick(row, fields):
    return {key: row.get(key) for key in fields}

def project(bundle):
    if bundle['schemaVersion'] != 1:
        raise ValueError('Unsupported Core public investor schema')
    sources = {s['sourceId']: s for s in bundle['sources']}
    snapshots = bundle['disclosedViews'] + [s for s in bundle['snapshots'] if s['investorId'] == 'pelosi']
    result = dict(schemaVersion=1, releaseId=bundle['releaseId'], asOf=bundle['asOf'], investors=[])
    for investor in bundle['investors']:
        ident = investor['investorId']
        derived = bundle['derived'][ident]
        record = dict(investor, snapshot=None, activities=[], history=[])
        for historical in sorted((s for s in snapshots if s["investorId"] == ident and s["filedDate"] <= bundle["asOf"]), key=lambda s: (s["effectiveDate"], s["filedDate"])):
            item = pick(historical, ("snapshotId", "effectiveDate", "filedDate", "currency", "sourceURL", "confidence", "completeReport", "confidentialOmitted"))
            item["positions"] = [pick(p, POSITION_FIELDS) for p in historical["positions"]]
            record["history"].append(item)
        snapshot = next((s for s in snapshots if s['investorId'] == ident and s['snapshotId'] == derived['latestSnapshotId']), None)
        if snapshot:
            if snapshot['filedDate'] > bundle['asOf']:
                raise ValueError('Future disclosure')
            record['snapshot'] = pick(snapshot, ('snapshotId', 'effectiveDate', 'filedDate', 'currency', 'sourceURL', 'confidence', 'completeReport', 'totalReportedValue', 'sourceLineage'))
            record['snapshot']['positions'] = [pick(p, POSITION_FIELDS) for p in snapshot['positions']]
        allowed = set(derived['activityIds'])
        for activity in bundle['activities']:
            if activity['investorId'] != ident or activity['activityId'] not in allowed:
                continue
            source = sources[activity['sourceId']]
            if source['filedDate'] > bundle['asOf']:
                raise ValueError('Future activity source')
            row = pick(activity, ACTIVITY_FIELDS)
            row.update(filedDate=source['filedDate'], sourceURL=source['sourceURL'])
            record['activities'].append(row)
        result['investors'].append(record)
    return result

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pointer', type=Path, default=Path('/Volumes/T7/CatData/core/storage/public-investors/current.json'))
    parser.add_argument('--output', type=Path, default=ROOT / 'CatfolioIOS/CatfolioIOS/Resources/public_investors.json')
    args = parser.parse_args()
    pointer = json.loads(args.pointer.read_text())
    if not pointer.get('persisted'):
        raise ValueError('Only persisted Core releases may be exported')
    data = Path(pointer['path']).read_bytes()
    bundle = json.loads(data)
    if bundle['releaseId'] != pointer['releaseId']:
        raise ValueError('Release pointer mismatch')
    result = project(bundle)
    result['coreSHA256'] = hashlib.sha256(data).hexdigest()
    args.output.write_text(json.dumps(result, ensure_ascii=False, separators=(',', ':')) + '\n')
    print(f"Exported {len(result['investors'])} investors from {result['releaseId']}")

if __name__ == '__main__':
    main()
