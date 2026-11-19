import Charts
import SwiftUI

/// A grid of line charts for one run. The set of charts comes from the run's
/// own metrics, so it grows or shrinks with the algorithm.
struct TrainingChartsView: View {
    let charts: [TrainingChart]

    private let columns = [GridItem(.adaptive(minimum: 300, maximum: 520), spacing: 14)]

    var body: some View {
        if charts.isEmpty {
            Text("No metrics reported yet.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                ForEach(charts) { chart in
                    TrainingChartCard(chart: chart)
                }
            }
        }
    }
}

private struct TrainingChartCard: View {
    let chart: TrainingChart

    /// The value range with a little headroom. A flat line (a constant
    /// learning rate, say) has no range of its own, so it gets one.
    private var yDomain: ClosedRange<Double> {
        let values = chart.lines.flatMap { $0.points.map(\.value) }
        guard let low = values.min(), let high = values.max() else {
            return 0...1
        }
        let padding = high > low ? (high - low) * 0.08 : max(abs(high) * 0.1, 1e-9)
        return (low - padding)...(high + padding)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(chart.title)
                    .font(.callout.weight(.semibold))
                Spacer()
                if let last = chart.lines.first?.points.last {
                    Text(TrainingJSON.number(last.value).displayText)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            Chart {
                ForEach(chart.lines) { line in
                    ForEach(Array(line.points.enumerated()), id: \.offset) { _, point in
                        LineMark(
                            x: .value("Iteration", point.iteration),
                            y: .value(chart.title, point.value)
                        )
                        .foregroundStyle(by: .value("Series", line.label))
                        .interpolationMethod(.monotone)
                    }
                    // A single report has no line to draw; show the point.
                    if line.points.count == 1, let point = line.points.first {
                        PointMark(
                            x: .value("Iteration", point.iteration),
                            y: .value(chart.title, point.value)
                        )
                        .foregroundStyle(by: .value("Series", line.label))
                    }
                }
            }
            .chartYScale(domain: yDomain)
            .chartLegend(chart.lines.count > 1 ? .visible : .hidden)
            .frame(height: 150)
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }
}
