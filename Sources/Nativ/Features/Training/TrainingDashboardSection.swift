import SwiftUI

/// Training statistics for the Dashboard. It shows nothing unless the
/// Training extension is enabled and at least one run exists.
struct TrainingDashboardSection: View {
    @StateObject private var model = TrainingDashboardModel()

    var body: some View {
        Group {
            if model.runs.isEmpty {
                EmptyView()
            } else {
                content
            }
        }
        .task {
            await model.poll()
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Training")
                        .font(.title3.weight(.semibold))
                    Text("Runs and their metrics. The charts follow what each algorithm reports.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Run", selection: $model.selectedRunID) {
                    ForEach(model.runs) { run in
                        Text("\(run.title) · \(run.algorithm ?? "run")").tag(Optional(run.id))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 320)
            }

            HStack(spacing: 12) {
                ForEach(model.statusCounts, id: \.label) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(item.count))
                            .font(.title2.weight(.semibold).monospacedDigit())
                        Text(item.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .frame(minWidth: 96, alignment: .leading)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
                }
            }

            if let history = model.history {
                if let iters = history.iters, let run = model.selectedRun, let iteration = run.iteration {
                    Text("\(run.status.capitalized) · iteration \(iteration) of \(iters)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                TrainingChartsView(charts: history.charts)
            }
        }
    }
}

@MainActor
final class TrainingDashboardModel: ObservableObject {
    @Published private(set) var runs: [TrainingRun] = []
    @Published private(set) var history: TrainingHistory?
    @Published var selectedRunID: String? {
        didSet {
            if selectedRunID != oldValue {
                history = nil
                Task {
                    await refresh()
                }
            }
        }
    }

    var selectedRun: TrainingRun? {
        runs.first { $0.id == selectedRunID }
    }

    /// Run counts by status, in a fixed order, leaving out empty groups.
    var statusCounts: [(label: String, count: Int)] {
        var counts = [(label: "Runs", count: runs.count)]
        for status in ["running", "completed", "capped", "stopped", "failed"] {
            let count = runs.filter { $0.status == status }.count
            if count > 0 {
                counts.append((label: status.capitalized, count: count))
            }
        }
        return counts
    }

    /// Refresh while the section is on screen; `.task` cancels this on disappear.
    func poll() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: .seconds(5))
        }
    }

    func refresh() async {
        guard let client = ChatTrainingToolRegistry.client else {
            runs = []
            history = nil
            return
        }
        guard let latest = try? await client.runs(limit: 30) else {
            return
        }
        runs = latest
        if selectedRun == nil {
            selectedRunID = latest.first?.id
        }
        if let id = selectedRunID, let next = try? await client.history(id), next != history {
            history = next
        }
    }
}
