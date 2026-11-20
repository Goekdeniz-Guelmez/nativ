import AppKit
import SwiftUI

/// The Training page: a run list, a form built from the trainer's own option
/// list, and a live view of the selected run.
struct TrainingView: View {
    @ObservedObject var store: TrainingStore
    var titleLeadingInset: CGFloat = 0

    @State private var isEditingLimits = false
    @State private var showsAllOptions = false

    /// Options shown first when the selected algorithm has them. Every other
    /// option the trainer reports is listed under "All options".
    private static let commonOptionNames = [
        "model", "dataset", "epochs", "iters", "batch_size",
        "learning_rate", "max_seq_length", "grad_checkpoint",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if store.isBackendMissing {
                unavailable
            } else {
                HStack(alignment: .top, spacing: 0) {
                    runList
                        .frame(width: 250)
                    Divider()
                    detail
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
        }
        .onAppear {
            store.startPolling()
        }
        .onDisappear {
            store.stopPolling()
        }
        .sheet(isPresented: $isEditingLimits) {
            TrainingLimitsEditor(limits: store.usage?.limits ?? TrainingLimits()) { limits in
                Task {
                    await store.saveLimits(limits)
                }
            }
        }
        .alert(
            "Training",
            isPresented: Binding(
                get: { store.errorMessage != nil },
                set: { if !$0 { store.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.errorMessage ?? "")
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Training")
                    .font(.title2.weight(.semibold))
                Text("Fine-tune models on this Mac. Runs keep going when Nativ is closed.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                isEditingLimits = true
            } label: {
                Label("Usage Limits", systemImage: "gauge.with.dots.needle.33percent")
            }
            .buttonStyle(.bordered)
            .disabled(store.usage == nil)

            Button {
                if let url = store.runsDirectory {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Label("Runs Folder", systemImage: "folder")
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 22)
        .padding(.leading, titleLeadingInset)
        .controlPanelDetailHeaderTopPadding()
        .padding(.bottom, 16)
    }

    private var unavailable: some View {
        ContentUnavailableView(
            "Training needs a newer Nativ",
            systemImage: "graduationcap",
            description: Text(
                TrainingClientError.backendUnavailable.errorDescription ?? ""
            )
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Run list

    private var runList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                store.select(.newRun)
            } label: {
                Label("New Run", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered)
            .padding(12)

            if let usage = store.usage {
                Text(usageSummary(usage))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }

            List(
                store.runs,
                selection: Binding(
                    get: { store.selectedRun?.id },
                    set: { id in
                        if let id {
                            store.select(.run(id))
                        }
                    }
                )
            ) { run in
                VStack(alignment: .leading, spacing: 3) {
                    Text(run.title)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        TrainingStatusBadge(status: run.status)
                        if let algorithm = run.algorithm {
                            Text(algorithm)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if run.isActive, let progress = run.progress {
                        ProgressView(value: progress)
                    }
                }
                .padding(.vertical, 2)
                .tag(run.id)
            }
            .listStyle(.sidebar)
        }
    }

    private func usageSummary(_ usage: TrainingUsage) -> String {
        var parts = ["\(usage.activeRuns) running"]
        if let cap = usage.limits.maxConcurrentRuns {
            parts[0] += " of \(cap)"
        }
        if let cap = usage.limits.maxRunsPerDay {
            parts.append("\(usage.runsLast24h) of \(cap) today")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if let run = store.selectedRun {
            runDetail(run)
        } else if store.description == nil {
            ProgressView("Reading the trainer…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            newRunForm
        }
    }

    private var newRunForm: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    if store.taskNames.count > 1 {
                        Picker("Task", selection: $store.task) {
                            ForEach(store.taskNames, id: \.self) { name in
                                Text(name).tag(name)
                            }
                        }
                        .frame(maxWidth: 220)
                    }
                    Picker("Algorithm", selection: $store.algorithm) {
                        ForEach(store.algorithmNames, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    .frame(maxWidth: 260)
                }
                if let description = store.currentAlgorithm?.description, !description.isEmpty {
                    Text(description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                LabeledContent("Run name") {
                    TextField("Optional", text: $store.runName)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 360)
                }

                // The training type is the choice that most changes a run, so
                // it gets its own control when the algorithm offers it.
                let trainType = store.options.first { $0.name == "train_type" && $0.choices?.isEmpty == false }
                if let trainType {
                    trainTypePicker(trainType)
                }
                // Options the chosen optimizer does not read are left out.
                let applicable = store.options.filter { store.applies($0) }
                let common = applicable.filter { Self.commonOptionNames.contains($0.name) }
                let others = applicable.filter {
                    !Self.commonOptionNames.contains($0.name) && $0.name != trainType?.name
                }
                optionGrid(common)
                DisclosureGroup("All options (\(others.count))", isExpanded: $showsAllOptions) {
                    optionGrid(others)
                        .padding(.top, 8)
                }

                Toggle(isOn: $store.mergeIntoLibrary) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Merge after training and add to my models")
                        Text("Fuses the trained weights into a full model and saves it in Nativ's model folder, so it appears in the model list.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)

                if let check = store.check {
                    checkResult(check)
                }

                HStack(spacing: 10) {
                    Button("Check") {
                        Task {
                            await store.runCheck()
                        }
                    }
                    .buttonStyle(.bordered)
                    Button("Start Training") {
                        Task {
                            await store.start()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    if store.isBusy {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                .disabled(store.isBusy || store.algorithm.isEmpty)
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func trainTypePicker(_ option: TrainingOption) -> some View {
        let selection = Binding(
            get: { store.values[option.name] ?? option.defaultValue.displayText },
            set: { store.values[option.name] = $0 }
        )
        return VStack(alignment: .leading, spacing: 4) {
            Picker("Training type", selection: selection) {
                ForEach(option.choices ?? [], id: \.self) { choice in
                    Text(Self.trainTypeTitle(choice.displayText)).tag(choice.displayText)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 420)
            Text(Self.trainTypeNote(selection.wrappedValue))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Friendly names for known training types; anything new shows as reported.
    private static func trainTypeTitle(_ value: String) -> String {
        switch value {
        case "lora": "LoRA"
        case "dora": "DoRA"
        case "full": "Full weights"
        default: value
        }
    }

    private static func trainTypeNote(_ value: String) -> String {
        switch value {
        case "lora": "Trains small adapter layers. Fast and light on memory."
        case "dora": "Like LoRA with an extra magnitude term. A little heavier."
        case "full": "Updates every weight. Needs far more memory; best for small models."
        default: ""
        }
    }

    private func optionGrid(_ options: [TrainingOption]) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 10) {
            ForEach(options) { option in
                GridRow {
                    Text(option.name)
                        .font(.callout.monospaced())
                        .help(option.help ?? option.flag)
                    optionField(option)
                        .frame(maxWidth: 360, alignment: .leading)
                }
            }
        }
    }

    @ViewBuilder
    private func optionField(_ option: TrainingOption) -> some View {
        let text = Binding(
            get: { store.values[option.name] ?? "" },
            set: { store.values[option.name] = $0 }
        )
        if option.type == "bool" {
            Picker(option.name, selection: text) {
                Text("Default (\(option.defaultValue.displayText))").tag("")
                Text("On").tag("true")
                Text("Off").tag("false")
            }
            .labelsHidden()
        } else if let choices = option.choices, !choices.isEmpty {
            Picker(option.name, selection: text) {
                Text("Default (\(option.defaultValue.displayText))").tag("")
                ForEach(choices, id: \.self) { choice in
                    Text(choice.displayText).tag(choice.displayText)
                }
            }
            .labelsHidden()
        } else {
            TextField(Self.placeholder(for: option), text: text)
            .textFieldStyle(.roundedBorder)
        }
    }

    /// The default when there is one; otherwise a hint at what to type.
    private static func placeholder(for option: TrainingOption) -> String {
        let fallback = option.defaultValue.displayText
        if !fallback.isEmpty {
            return fallback
        }
        return switch option.name {
        case "dataset": "Hugging Face dataset ID, e.g. user/name"
        case "model": "Model ID or local folder"
        default: option.type
        }
    }

    private func checkResult(_ check: TrainingCheck) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(
                check.valid ? "These settings are valid." : "These settings have problems.",
                systemImage: check.valid ? "checkmark.circle" : "exclamationmark.triangle"
            )
            .foregroundStyle(check.valid ? Color.green : Color.orange)
            ForEach(check.errors, id: \.self) { message in
                Text(message)
                    .font(.callout)
            }
            ForEach(check.notes, id: \.self) { message in
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func runDetail(_ run: TrainingRun) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Text(run.title)
                        .font(.title3.weight(.semibold))
                    TrainingStatusBadge(status: run.status)
                    Spacer()
                    if run.isActive {
                        Button("Stop", role: .destructive) {
                            Task {
                                await store.stop(run)
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(store.isBusy)
                    }
                }

                if let progress = run.progress, let iteration = run.iteration, let iters = run.iters {
                    ProgressView(value: progress) {
                        Text("Iteration \(iteration) of \(iters)")
                            .font(.callout)
                    }
                }
                if let capped = run.capped {
                    Label(
                        "Stopped at a usage limit: \(capped). The weights so far were saved.",
                        systemImage: "gauge.with.dots.needle.67percent"
                    )
                    .foregroundStyle(.orange)
                }
                if let error = run.error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }

                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                    detailRow("Model", run.model)
                    detailRow("Algorithm", [run.task, run.algorithm].compactMap { $0 }.joined(separator: " / "))
                    detailRow("Started", run.createdAt)
                    detailRow("Ended", run.endedAt)
                    detailRow("Weights", run.adapterPath)
                    if let exportPath = run.exportPath {
                        detailRow(
                            "Merged model",
                            FileManager.default.fileExists(atPath: exportPath)
                                ? "\(TrainingMergeDestination.repoID(forSnapshotPath: exportPath) ?? exportPath) — in your model list"
                                : "Saved when the run ends"
                        )
                    }
                }

                if let history = store.history {
                    Text("Charts")
                        .font(.headline)
                    TrainingChartsView(charts: history.charts)
                }

                if let metrics = run.metrics, !metrics.isEmpty {
                    Text("Latest metrics")
                        .font(.headline)
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                        ForEach(metrics.keys.sorted(), id: \.self) { key in
                            GridRow {
                                Text(key)
                                    .font(.callout.monospaced())
                                    .foregroundStyle(.secondary)
                                Text(metrics[key]?.displayText ?? "")
                                    .font(.callout.monospaced())
                            }
                        }
                    }
                }

                Text("Log")
                    .font(.headline)
                Text(store.log.isEmpty ? "No output yet." : store.log)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func detailRow(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            GridRow {
                Text(label)
                    .foregroundStyle(.secondary)
                Text(value)
                    .textSelection(.enabled)
                    .lineLimit(2)
            }
        }
    }
}

private struct TrainingStatusBadge: View {
    let status: String

    var body: some View {
        Text(status.capitalized)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    private var color: Color {
        switch status {
        case "running": .blue
        case "completed": .green
        case "capped": .orange
        case "failed": .red
        default: .secondary
        }
    }
}

/// Edits the usage caps. An empty field means unlimited.
private struct TrainingLimitsEditor: View {
    @Environment(\.dismiss) private var dismiss

    let onSave: (TrainingLimits) -> Void

    @State private var concurrentRuns: String
    @State private var iterations: String
    @State private var minutes: String
    @State private var memoryGB: String
    @State private var runsPerDay: String

    init(limits: TrainingLimits, onSave: @escaping (TrainingLimits) -> Void) {
        self.onSave = onSave
        _concurrentRuns = State(initialValue: limits.maxConcurrentRuns.map(String.init) ?? "")
        _iterations = State(initialValue: limits.maxIters.map(String.init) ?? "")
        _minutes = State(initialValue: limits.maxMinutes.map { String(format: "%g", $0) } ?? "")
        _memoryGB = State(initialValue: limits.maxMemoryGB.map { String(format: "%g", $0) } ?? "")
        _runsPerDay = State(initialValue: limits.maxRunsPerDay.map(String.init) ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Usage Limits")
                .font(.title3.weight(.semibold))
            Text("Limits apply to every training run on this Mac, including runs an agent starts. Leave a field empty for no limit.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 10) {
                row("Runs at the same time", $concurrentRuns)
                row("Iterations per run", $iterations)
                row("Minutes per run", $minutes)
                row("Memory per run (GB)", $memoryGB)
                row("Runs per day", $runsPerDay)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                Button("Save") {
                    onSave(limits)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    /// Non-positive or unreadable entries count as no limit.
    private var limits: TrainingLimits {
        TrainingLimits(
            maxConcurrentRuns: Int(concurrentRuns).flatMap { $0 > 0 ? $0 : nil },
            maxIters: Int(iterations).flatMap { $0 > 0 ? $0 : nil },
            maxMinutes: Double(minutes).flatMap { $0 > 0 ? $0 : nil },
            maxMemoryGB: Double(memoryGB).flatMap { $0 > 0 ? $0 : nil },
            maxRunsPerDay: Int(runsPerDay).flatMap { $0 > 0 ? $0 : nil }
        )
    }

    private func row(_ label: String, _ text: Binding<String>) -> some View {
        GridRow {
            Text(label)
            TextField("No limit", text: text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 120)
        }
    }
}
