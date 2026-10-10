import SwiftUI
import Charts

/// Shared geometry and interaction for History's dividend and order rings.
struct HistoryProportionRing<Row: Identifiable>: View {
    let layout: HistoryRingLayout<Row>
    @Binding var selection: Row.ID?
    let color: (Row) -> Color
    @State private var selectedShare: Double?

    var body: some View {
        Chart(layout.segments) { segment in
            SectorMark(angle: .value(L10n.text("比例"), segment.fraction),
                       innerRadius: .ratio(HistoryRingLayout<Row>.innerRadiusRatio),
                       angularInset: layout.angularInset)
                .cornerRadius(layout.cornerRadius)
                .foregroundStyle(color(segment.row))
                .opacity(selection == nil || segment.id == selection ? 1 : 0.45)
        }
        .chartLegend(.hidden)
        .chartAngleSelection(value: $selectedShare)
        .onChange(of: selectedShare) { _, share in
            if let share, let row = layout.row(at: share) { selection = row.id }
        }
        .onChange(of: selection) { _, value in
            if value == nil { selectedShare = nil }
        }
        .background {
            if layout.segments.isEmpty {
                Circle()
                    .strokeBorder(CatfolioTheme.subtleFill,
                        lineWidth: HistoryRingLayout<Row>.diameter * (1 - HistoryRingLayout<Row>.innerRadiusRatio) / 2)
                    .aspectRatio(1, contentMode: .fit)
            }
        }
        .frame(width: HistoryRingLayout<Row>.diameter, height: HistoryRingLayout<Row>.diameter)
    }
}
