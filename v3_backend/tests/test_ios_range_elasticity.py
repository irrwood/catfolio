"""Execute the bounded presentation-only rubber band without an app or market data."""
from pathlib import Path
import subprocess
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[2] / 'CatfolioIOS/CatfolioIOS/VolumeProfileView.swift'

class RangeElasticityTests(unittest.TestCase):
    def test_resistance_symmetry_locality_and_invalid_geometry(self):
        source = SOURCE.read_text()
        rule = source[source.index('enum FiftyTwoWeekEdgeElasticity {'):source.index('private struct FiftyTwoWeekRange: View')]
        harness = '''
import Foundation
''' + rule + '''
let band = FiftyTwoWeekEdgeElasticity.self
for x in stride(from: CGFloat(0), through: 300, by: 5) {
    precondition(band.pull(location: x, lower: 0, upper: 300) == 0)
}
var previous: CGFloat = 0
for distance in stride(from: CGFloat(1), through: 1000, by: 1) {
    let left = band.pull(location: -distance, lower: 0, upper: 300)
    let right = band.pull(location: 300 + distance, lower: 0, upper: 300)
    precondition(abs(left + right) < 0.000001)
    precondition(right > previous && right < band.limit && right < distance)
    previous = right
}
precondition(band.pull(location: .nan, lower: 0, upper: 300) == 0)
precondition(band.pull(location: -20, lower: 0, upper: 0) == 0)
precondition(band.influence(index: 0, count: 45, pull: -10) == 1)
precondition(band.influence(index: 44, count: 45, pull: 10) == 1)
precondition(band.influence(index: 22, count: 45, pull: 10) == 0)
precondition(band.influence(index: 0, count: 45, pull: 0) == 0)
for index in 0..<45 {
    precondition(band.influence(index: index, count: 45, pull: -10) == band.influence(index: 44-index, count: 45, pull: 10))
}
print("PASS: bounds, symmetry, resistance, locality, reset, invalid geometry")
'''
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'main.swift'
            path.write_text(harness)
            run = subprocess.run(['swift', str(path)], capture_output=True, text=True)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)

if __name__ == '__main__':
    unittest.main()
