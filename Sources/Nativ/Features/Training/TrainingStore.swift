import Foundation
import SwiftUI

/// State for the Training page. Everything it shows comes from the trainer:
/// the list of tasks, algorithms, and options is read at runtime, so a new
/// algorithm or modality appears here without a change to Nativ.
@MainActor
final class TrainingStore: ObservableObject {
    /// What the detail pane shows.
    enum Selection: Hashable {
        case newRun
        case run(String)
    }

    @Published private(set) var description: TrainingDescription?
    @Published private(set) var usage: TrainingUsage?
    @Published private(set) var runs: [TrainingRun] = []
    @Published private(set) var log = ""
    @Published private(set) var history: TrainingHistory?
    @Published private(set) var check: TrainingCheck?
    @Published private(set) var isBusy = false
    @Published private(set) var isBackendMissing = false
    @Published var errorMessage: String?
    @Published var selection: Selection = .newRun

    @Published var task = "" {
        didSet {
            if task != oldValue {
                let preferred = description?.tasks[task]?.defaultAlgorithm
                algorithm = preferred.flatMap { algorithmNames.contains($0) ? $0 : nil }
                    ?? algorithmNames.first ?? ""
            }
        }
    }
    @Published var algorithm = "" {
        didSet {
            if algorithm != oldValue {
                values.removeAll()
                check = nil
            }
        }
    }
    /// Form text keyed by option name. An empty entry keeps the default.
    @Published var values: [String: String] = [:]
    @Published var runName = ""
    /// Merge the trained weights into a full model and add it to the model list.
    @Published var mergeIntoLibrary = false
    /// Nativ's model folder, supplied by the host when the page is shown.
    var modelSearchPath: String?

    private var client: TrainingRunClient?
    private var pollTask: Task<Void, Never>?

    var runsDirectory: URL? { client?.runsDirectory }

    var taskNames: [String] {
        (description?.tasks.keys).map { $0.sorted() } ?? []
    }

    var algorithmNames: [String] {
        (description?.tasks[task]?.algorithms.keys).map { $0.sorted() } ?? []
    }

    var currentAlgorithm: TrainingAlgorithm? {
        description?.tasks[task]?.algorithms[algorithm]
    }

    /// Options a person sets for a run, in the order the trainer lists them.
    var options: [TrainingOption] {
        currentAlgorithm?.options.filter { !$0.isManaged } ?? []
    }

    var selectedRun: TrainingRun? {
        guard case .run(let id) = selection else {
            return nil
        }
        return runs.first { $0.id == id }
    }

    func configure(client: TrainingRunClient?) {
        self.client = client
    }

    /// Begin refreshing while the page is on screen.
    func startPolling() {
        guard pollTask == nil else {
            return
        }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    func refresh() async {
        guard let client else {
            return
        }
        do {
            if description == nil {
                let loaded = try await client.describe()
                description = loaded
                if task.isEmpty {
                    task = loaded.tasks.keys.sorted().first ?? ""
                }
            }
            async let nextRuns = client.runs()
            async let nextUsage = client.usage()
            runs = try await nextRuns
            usage = try await nextUsage
            if case .run(let id) = selection {
                log = (try? await client.log(id)) ?? ""
                if let next = try? await client.history(id), next != history {
                    history = next
                }
            }
            isBackendMissing = false
        } catch TrainingClientError.backendUnavailable {
            isBackendMissing = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func select(_ next: Selection) {
        selection = next
        log = ""
        history = nil
        Task {
            await refresh()
        }
    }

    /// Whether an option applies with the current choices. The trainer says
    /// which options depend on another one, such as the optimizer.
    func applies(_ option: TrainingOption) -> Bool {
        guard let requires = option.requires else {
            return true
        }
        return requires.allSatisfy { name, allowed in
            let typed = (values[name] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let current = typed.isEmpty
                ? options.first { $0.name == name }?.defaultValue.displayText ?? ""
                : typed
            return allowed.contains(current)
        }
    }

    /// The options to send: only fields the person filled in, and only those
    /// that apply, so a value left in a hidden field is not sent.
    func collectOptions() throws -> [String: TrainingJSON] {
        var result: [String: TrainingJSON] = [
            "task": .string(task),
            "algorithm": .string(algorithm),
        ]
        for option in options where applies(option) {
            if let value = try option.jsonValue(from: values[option.name] ?? "") {
                result[option.name] = value
            }
        }
        return result
    }

    func runCheck() async {
        await perform { client in
            self.check = try await client.check(options: try self.collectOptions())
        }
    }

    func start() async {
        await perform { client in
            var options = try self.collectOptions()
            let result = try await client.check(options: options)
            self.check = result
            guard result.valid else {
                return
            }
            if self.mergeIntoLibrary {
                guard let modelSearchPath = self.modelSearchPath else {
                    throw TrainingClientError.failed("Nativ's model folder is not available.")
                }
                let destination = TrainingMergeDestination(
                    modelSearchPath: modelSearchPath,
                    name: self.mergedModelName(options: options)
                )
                try destination.prepare()
                destination.apply(to: &options)
            }
            let run = try await client.start(options: options, name: self.runName)
            self.runName = ""
            self.check = nil
            self.selection = .run(run.id)
            await self.refresh()
        }
    }

    /// The run name when given, otherwise the last part of the model id.
    private func mergedModelName(options: [String: TrainingJSON]) -> String {
        let name = runName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty {
            return name
        }
        let model = options["model"]?.displayText ?? "model"
        return model.split(separator: "/").last.map(String.init) ?? model
    }

    func stop(_ run: TrainingRun) async {
        await perform { client in
            _ = try await client.stop(run.id)
            await self.refresh()
        }
    }

    func saveLimits(_ limits: TrainingLimits) async {
        await perform { client in
            try client.writeLimits(limits)
            await self.refresh()
        }
    }

    private func perform(
        _ work: @MainActor (TrainingRunClient) async throws -> Void
    ) async {
        guard let client, !isBusy else {
            return
        }
        isBusy = true
        defer {
            isBusy = false
        }
        do {
            try await work(client)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
