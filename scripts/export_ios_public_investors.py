"""Project a published Core release into the offline iOS disclosure catalog."""
import argparse
import copy
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
POSITION_FIELDS = ('positionId', 'issuerName', 'ticker', 'cusip', 'securityId', 'shares', 'reportedValue', 'reportedValueLow', 'reportedValueHigh', 'weight', 'owner', 'option', 'confidence', 'securityIdentityRole')
ACTIVITY_FIELDS = ('activityId', 'investorId', 'type', 'exactDate', 'periodStart', 'periodEnd', 'shares', 'sharesDelta', 'amount', 'amountLow', 'amountHigh', 'owner', 'ticker', 'issuerName', 'cusip', 'option', 'confidence', 'eventNature', 'sourceId')
UPDATE_ROOT = ROOT / 'data/public-investors'

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

def apply_updates(catalog, updates, archive_root=UPDATE_ROOT):
    """Merge archived disclosure supplements without changing holding snapshots."""
    result = copy.deepcopy(catalog)
    if result['schemaVersion'] != 1:
        raise ValueError('Unsupported iOS public investor schema')
    investors = {i['investorId']: i for i in result['investors']}
    sources = {s['sourceId']: s for s in result.get('supplementalSources', [])}
    for update in updates:
        if update['schemaVersion'] != 1:
            raise ValueError('Unsupported disclosure update schema')
        local_sources = {s['sourceId']: s for s in update['sources']}
        for source in local_sources.values():
            if source['filedDate'] > update['asOf']:
                raise ValueError('Future activity source')
            archive = (archive_root / source['archive']).resolve()
            if not archive.is_relative_to(archive_root.resolve()):
                raise ValueError('Source archive outside disclosure directory')
            if hashlib.sha256(archive.read_bytes()).hexdigest() != source['sha256']:
                raise ValueError('Source archive checksum mismatch')
            sources[source['sourceId']] = source
        seen = set()
        for activity in update['activities']:
            if activity['activityId'] in seen:
                raise ValueError('Duplicate update activity')
            seen.add(activity['activityId'])
            if activity['investorId'] not in investors:
                raise ValueError('Unknown investor')
            source = local_sources[activity['sourceId']]
            if (activity.get('exactDate') or '') > source['filedDate']:
                raise ValueError('Activity occurs after source date')
            row = dict(activity)
            row.update(pick(source, ('filedDate', 'sourceURL', 'sourceType', 'dateBasis')))
            investor = investors[activity['investorId']]
            existing = {a['activityId']: a for a in investor['activities']}
            existing[row['activityId']] = row
            investor['activities'] = list(existing.values())
        result['asOf'] = max(result['asOf'], update['asOf'])
    if sources:
        result['coreReleaseId'] = result.get('coreReleaseId', result['releaseId'])
        result['supplementalSources'] = sorted(sources.values(), key=lambda s: s['sourceId'])
        # The original Core digest remains intact; the app cache uses a new
        # content-derived release ID that includes the disclosure supplements.
        payload = {k: v for k, v in result.items() if k != 'releaseId'}
        canonical = json.dumps(payload, ensure_ascii=False, sort_keys=True, separators=(',', ':'))
        result['releaseId'] = hashlib.sha256(canonical.encode()).hexdigest()[:16]
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pointer', type=Path, default=Path('/Volumes/T7/CatData/core/storage/public-investors/current.json'))
    parser.add_argument('--output', type=Path, default=ROOT / 'CatfolioIOS/CatfolioIOS/Resources/public_investors.json')
    parser.add_argument('--base-catalog', type=Path, help='Previously exported catalog when the Core volume is unavailable')
    parser.add_argument('--updates', type=Path, default=UPDATE_ROOT / 'updates')
    args = parser.parse_args()
    if args.base_catalog:
        result = json.loads(args.base_catalog.read_text())
    else:
        pointer = json.loads(args.pointer.read_text())
        if not pointer.get('persisted'):
            raise ValueError('Only persisted Core releases may be exported')
        data = Path(pointer['path']).read_bytes()
        bundle = json.loads(data)
        if bundle['releaseId'] != pointer['releaseId']:
            raise ValueError('Release pointer mismatch')
        result = project(bundle)
        result['coreSHA256'] = hashlib.sha256(data).hexdigest()
    updates = [json.loads(path.read_text()) for path in sorted(args.updates.glob('*.json'))]
    result = apply_updates(result, updates, args.updates.parent)
    args.output.write_text(json.dumps(result, ensure_ascii=False, separators=(',', ':')) + '\n')
    print(f"Exported {len(result['investors'])} investors from {result['releaseId']}")

if __name__ == '__main__':
    main()
