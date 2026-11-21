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

    /// The iteration under the pointer, snapped to one the run reported.
    @State private var hoveredIteration: Double?

    private static let palette: [Color] = [.blue, .green, .orange, .purple, .pink, .teal]
    private static let tooltipWidth: CGFloat = 176

    private func color(for line: TrainingChart.Line) -> Color {
        let index = chart.lines.firstIndex { $0.id == line.id } ?? 0
        return Self.palette[index % Self.palette.count]
    }

    /// What each line last reported at or before the hovered iteration.
    /// Validation is reported less often than training, so its point can sit
    /// a few iterations back; a line with nothing yet is left out.
    private var hoveredValues: [(line: TrainingChart.Line, point: TrainingChart.Point)] {
        guard let hoveredIteration else {
            return []
        }
        return chart.lines.compactMap { line in
            line.points.last { $0.iteration <= hoveredIteration }.map { (line, $0) }
        }
    }

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
                if let hoveredIteration {
                    RuleMark(x: .value("Selected iteration", hoveredIteration))
                        .foregroundStyle(Color.secondary.opacity(0.7))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    ForEach(hoveredValues, id: \.line.id) { item in
                        PointMark(
                            x: .value("Iteration", item.point.iteration),
                            y: .value(chart.title, item.point.value)
                        )
                        .foregroundStyle(by: .value("Series", item.line.label))
                        .symbolSize(42)
                    }
                }
            }
            .chartForegroundStyleScale(
                domain: chart.lines.map(\.label),
                range: chart.lines.map { color(for: $0) }
            )
            .chartYScale(domain: yDomain)
            .chartLegend(chart.lines.count > 1 ? .visible : .hidden)
            .frame(height: 150)
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    ZStack(alignment: .topLeading) {
                        Rectangle()
                            .fill(.clear)
                            .contentShape(Rectangle())
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(let location):
                                    updateHover(at: location, proxy: proxy, geometry: geometry)
                                case .ended:
                                    hoveredIteration = nil
                                }
                            }
                        if let hoveredIteration,
                           let center = tooltipCenter(
                               for: hoveredIteration, proxy: proxy, geometry: geometry
                           ) {
                            tooltip(iteration: hoveredIteration)
                                .position(center)
                                .allowsHitTesting(false)
                                .transition(.identity)
                        }
                    }
                    .transaction { transaction in
                        transaction.animation = nil
                    }
                }
            }
            .onChange(of: chart) { _, _ in
                // New reports arrive while a run is live; drop a stale selection.
                if let hoveredIteration,
                   !chart.lines.contains(where: { $0.points.contains { $0.iteration == hoveredIteration } }) {
                    self.hoveredIteration = nil
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    /// Snap the pointer to the nearest iteration any line reported.
    private func updateHover(at location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) {
        guard let anchor = proxy.plotFrame else {
            hoveredIteration = nil
            return
        }
        let plotFrame = geometry[anchor]
        guard plotFrame.contains(location),
              let x: Double = proxy.value(atX: location.x - plotFrame.minX) else {
            hoveredIteration = nil
            return
        }
        let nearest = chart.lines
            .flatMap { $0.points.map(\.iteration) }
            .min { abs($0 - x) < abs($1 - x) }
        if nearest != hoveredIteration {
            hoveredIteration = nearest
        }
    }

    /// Beside the rule, on whichever side has room, kept inside the plot.
    private func tooltipCenter(
        for iteration: Double, proxy: ChartProxy, geometry: GeometryProxy
    ) -> CGPoint? {
        guard let anchor = proxy.plotFrame, let offset = proxy.position(forX: iteration) else {
            return nil
        }
        let plotFrame = geometry[anchor]
        let ruleX = plotFrame.minX + offset
        let half = Self.tooltipWidth / 2
        let gap: CGFloat = 10
        var x = ruleX + gap + half
        if x + half > plotFrame.maxX {
            x = ruleX - gap - half
        }
        x = min(max(x, plotFrame.minX + half), max(plotFrame.maxX - half, plotFrame.minX + half))
        let height = CGFloat(34 + 18 * max(hoveredValues.count, 1))
        return CGPoint(x: x, y: plotFrame.minY + height / 2 + 2)
    }

    private func tooltip(iteration: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Iteration \(TrainingJSON.number(iteration).displayText)")
                .font(.caption.weight(.semibold))
            ForEach(hoveredValues, id: \.line.id) { item in
                HStack {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(color(for: item.line))
                            .frame(width: 7, height: 7)
                        Text(item.line.label)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    Text(TrainingJSON.number(item.point.value).displayText)
                        .fontWeight(.medium)
                        .monospacedDigit()
                }
                .font(.caption)
            }
        }
        .padding(10)
        .frame(width: Self.tooltipWidth)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 0.75)
        )
        .shadow(color: .black.opacity(0.16), radius: 10, y: 4)
    }
}
