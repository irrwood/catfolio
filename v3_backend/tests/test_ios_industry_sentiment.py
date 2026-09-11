"""Native snapshot decoding and settings/chart wiring contracts."""
import shutil
import subprocess
from pathlib import Path
import pytest

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / 'CatfolioIOS/CatfolioIOS/IndustrySentimentView.swift'


def test_native_snapshot_validation(tmp_path):
    swift = shutil.which('swift')
    if not swift:
        pytest.skip('Swift unavailable')
    model = SOURCE.read_text().split('struct IndustrySentimentSnapshot: Decodable {', 1)[1].split('\nstruct IndustrySentimentView:', 1)[0]
    harness = '''
let raw = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
let snapshot = try IndustrySentimentSnapshot.decode(raw)
precondition(snapshot.score.map { (0...100).contains($0) } ?? true)
precondition(!snapshot.history.isEmpty)
precondition(snapshot.history.last?.date == snapshot.asOf)
var object = try JSONSerialization.jsonObject(with: raw) as! [String: Any]
func rejects(_ object: [String: Any]) throws {
    let data = try JSONSerialization.data(withJSONObject: object)
    do {
        _ = try IndustrySentimentSnapshot.decode(data)
        fatalError("Malformed snapshot accepted")
    } catch {}
}
object["score"] = 101
try rejects(object)
object["score"] = 48
object["history"] = []
try rejects(object)
print("Snapshot validation passed")
'''
    script = tmp_path / 'SentimentValidation.swift'
    script.write_text('import Foundation\nstruct IndustrySentimentSnapshot: Decodable {' + model + harness)
    result = subprocess.run([swift, str(script), str(ROOT / 'CatfolioIOS/CatfolioIOS/Resources/industry_sentiment.json')], capture_output=True, text=True)
    assert result.returncode == 0, result.stderr


def test_settings_and_shared_chart():
    assert 'IndustrySentimentView()' in (ROOT / 'CatfolioIOS/CatfolioIOS/SettingsView.swift').read_text()
    view = SOURCE.read_text()
    assert 'StandardLineChart(' in view
    assert 'dataTransition: .viewportZoom' in view
    assert 'WebView' not in view
