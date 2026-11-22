import Foundation

/// A JSON value of unknown shape. The trainer reports its own options and
/// metrics, so the host never hard-codes their names or types.
enum TrainingJSON: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([TrainingJSON])
    case object([String: TrainingJSON])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([TrainingJSON].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: TrainingJSON].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .number(let value):
            if value.rounded() == value, abs(value) < 1e15 {
                try container.encode(Int64(value))
            } else {
                try container.encode(value)
            }
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }

    /// Text for a form field or a metrics row.
    var displayText: String {
        switch self {
        case .null:
            return ""
        case .bool(let value):
            return value ? "true" : "false"
        case .number(let value):
            if value.rounded() == value, abs(value) < 1e15 {
                return String(Int64(value))
            }
            return String(format: "%.5g", value)
        case .string(let value):
            return value
        case .array(let values):
            return values.map(\.displayText).joined(separator: " ")
        case .object:
            guard let data = try? JSONEncoder().encode(self) else {
                return ""
            }
            return String(decoding: data, as: UTF8.self)
        }
    }
}

struct TrainingOption: Codable, Hashable, Identifiable, Sendable {
    let name: String
    let flag: String
    let type: String
    let defaultValue: TrainingJSON
    let choices: [TrainingJSON]?
    let help: String?
    let group: String
    /// Other options this one depends on: it only applies while each named
    /// option holds one of the listed values (`beta1` needs an Adam optimizer).
    let requires: [String: [String]]?

    var id: String { name }

    /// Options the run manager sets itself; never shown in the form.
    var isManaged: Bool { group == "managed" }

    private enum CodingKeys: String, CodingKey {
        case name, flag, type, choices, help, group, requires
        case defaultValue = "default"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        flag = try container.decode(String.self, forKey: .flag)
        type = try container.decode(String.self, forKey: .type)
        defaultValue = try container.decodeIfPresent(TrainingJSON.self, forKey: .defaultValue) ?? .null
        choices = try container.decodeIfPresent([TrainingJSON].self, forKey: .choices)
        help = try container.decodeIfPresent(String.self, forKey: .help)
        group = try container.decodeIfPresent(String.self, forKey: .group) ?? "general"
        requires = try container.decodeIfPresent([String: [String]].self, forKey: .requires)
    }

    /// Convert form text to the JSON value the trainer expects. Empty text
    /// means "leave the default", reported as `nil`.
    func jsonValue(from text: String) throws -> TrainingJSON? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        switch type {
        case "bool":
            switch trimmed.lowercased() {
            case "true", "yes", "1": return .bool(true)
            case "false", "no", "0": return .bool(false)
            default: throw TrainingClientError.invalidOption(name, "expects true or false")
            }
        case "int":
            guard let value = Int(trimmed) else {
                throw TrainingClientError.invalidOption(name, "expects a whole number")
            }
            return .number(Double(value))
        case "float":
            guard let value = Double(trimmed), value.isFinite else {
                throw TrainingClientError.invalidOption(name, "expects a number")
            }
            return .number(value)
        case "json":
            guard let value = try? JSONDecoder().decode(
                TrainingJSON.self,
                from: Data(trimmed.utf8)
            ) else {
                throw TrainingClientError.invalidOption(name, "expects JSON")
            }
            return value
        case "list":
            return .array(trimmed.split(whereSeparator: \.isWhitespace).map { .string(String($0)) })
        default:
            return .string(trimmed)
        }
    }
}

struct TrainingAlgorithm: Codable, Hashable, Sendable {
    let description: String
    let options: [TrainingOption]
    let rewardFunctions: [String]?

    private enum CodingKeys: String, CodingKey {
        case description, options
        case rewardFunctions = "reward_functions"
    }
}

struct TrainingTask: Codable, Hashable, Sendable {
    let algorithms: [String: TrainingAlgorithm]
    /// The algorithm the trainer uses when none is named.
    let defaultAlgorithm: String?

    private enum CodingKeys: String, CodingKey {
        case algorithms
        case defaultAlgorithm = "default_algorithm"
    }
}

/// Usage caps. `nil` means unlimited.
struct TrainingLimits: Codable, Equatable, Sendable {
    var maxConcurrentRuns: Int? = 1
    var maxIters: Int?
    var maxMinutes: Double?
    var maxMemoryGB: Double?
    var maxRunsPerDay: Int?

    private enum CodingKeys: String, CodingKey {
        case maxConcurrentRuns = "max_concurrent_runs"
        case maxIters = "max_iters"
        case maxMinutes = "max_minutes"
        case maxMemoryGB = "max_memory_gb"
        case maxRunsPerDay = "max_runs_per_day"
    }

    init(
        maxConcurrentRuns: Int? = 1,
        maxIters: Int? = nil,
        maxMinutes: Double? = nil,
        maxMemoryGB: Double? = nil,
        maxRunsPerDay: Int? = nil
    ) {
        self.maxConcurrentRuns = maxConcurrentRuns
        self.maxIters = maxIters
        self.maxMinutes = maxMinutes
        self.maxMemoryGB = maxMemoryGB
        self.maxRunsPerDay = maxRunsPerDay
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        maxConcurrentRuns = try container.decodeIfPresent(Int.self, forKey: .maxConcurrentRuns)
        maxIters = try container.decodeIfPresent(Int.self, forKey: .maxIters)
        maxMinutes = try container.decodeIfPresent(Double.self, forKey: .maxMinutes)
        maxMemoryGB = try container.decodeIfPresent(Double.self, forKey: .maxMemoryGB)
        maxRunsPerDay = try container.decodeIfPresent(Int.self, forKey: .maxRunsPerDay)
    }

    /// Every cap is written, with `null` for unlimited. A missing key would
    /// fall back to the trainer's default instead of the user's choice.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(maxConcurrentRuns, forKey: .maxConcurrentRuns)
        try container.encode(maxIters, forKey: .maxIters)
        try container.encode(maxMinutes, forKey: .maxMinutes)
        try container.encode(maxMemoryGB, forKey: .maxMemoryGB)
        try container.encode(maxRunsPerDay, forKey: .maxRunsPerDay)
    }
}

struct TrainingDescription: Codable, Hashable, Sendable {
    let version: String
    let tasks: [String: TrainingTask]
}

struct TrainingUsage: Codable, Equatable, Sendable {
    let limits: TrainingLimits
    let activeRuns: Int
    let runsLast24h: Int

    private enum CodingKeys: String, CodingKey {
        case limits
        case activeRuns = "active_runs"
        case runsLast24h = "runs_last_24h"
    }
}

struct TrainingRun: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let name: String?
    let status: String
    let task: String?
    let algorithm: String?
    let model: String?
    let createdAt: String?
    let endedAt: String?
    let exitCode: Int?
    let adapterPath: String?
    let logPath: String?
    let notes: [String]?
    let iters: Int?
    let iteration: Int?
    let metrics: [String: TrainingJSON]?
    let capped: String?
    let error: String?
    /// Where a merged, standalone model is written when the run asked for one.
    let exportPath: String?
    /// Whether the run ended early with weights a new run can carry on from.
    let canContinue: Bool?
    /// The run this one carries on, when it was started with Continue.
    let continuedFrom: String?

    private enum CodingKeys: String, CodingKey {
        case id, name, status, task, algorithm, model, notes, iters, iteration, metrics, capped, error
        case exportPath = "export_path"
        case canContinue = "can_continue"
        case continuedFrom = "continued_from"
        case createdAt = "created_at"
        case endedAt = "ended_at"
        case exitCode = "exit_code"
        case adapterPath = "adapter_path"
        case logPath = "log_path"
    }

    var isActive: Bool { status == "running" }
    var title: String { name ?? id }

    /// Completed fraction, when the run has reported both numbers.
    var progress: Double? {
        guard let iteration, let iters, iters > 0 else {
            return nil
        }
        return min(1, Double(iteration) / Double(iters))
    }
}

/// The options a run was started with, for starting another like it.
struct TrainingRunConfig: Codable, Equatable, Sendable {
    let id: String
    let name: String?
    let options: [String: TrainingJSON]
}

/// The latest text a run generated, for algorithms that generate (GRPO).
struct TrainingSample: Codable, Equatable, Sendable {
    let prompt: String?
    let completion: String?
    let answer: String?
    let reward: Double?
    let rewardFunction: String?
    let group: Int?

    private enum CodingKeys: String, CodingKey {
        case prompt, completion, answer, reward, group
        case rewardFunction = "reward_function"
    }
}

private struct TrainingSampleResponse: Codable {
    let sample: TrainingSample?
}

private struct TrainingDeleted: Codable {
    let deleted: String
}

/// A run's metrics over time, exactly as the trainer reported them.
struct TrainingHistory: Codable, Equatable, Sendable {
    let id: String
    let name: String?
    let status: String
    let task: String?
    let algorithm: String?
    let iters: Int?
    /// Metric name to `[iteration, value]` points.
    let series: [String: [[Double]]]

    /// Charts for this run. Which charts exist depends on what the algorithm
    /// reported: every objective metric becomes one chart with its training
    /// and validation lines, so a preference or reward algorithm gets more
    /// charts than plain supervised training without any list kept here.
    var charts: [TrainingChart] {
        var objective: [String: [TrainingChart.Line]] = [:]
        for (name, points) in series {
            let label: String
            let base: String
            if name.hasPrefix("train_") {
                label = "Training"
                base = String(name.dropFirst("train_".count))
            } else if name.hasPrefix("val_") {
                label = "Validation"
                base = String(name.dropFirst("val_".count))
            } else {
                continue
            }
            // Counts, timings, and throughput describe the machine, not the objective.
            if base.hasPrefix("num_") || base.hasSuffix("_per_second") || base.hasSuffix("time") {
                continue
            }
            let line = TrainingChart.Line(label: label, points: Self.points(points))
            if !line.points.isEmpty {
                objective[base, default: []].append(line)
            }
        }
        var charts = objective.keys
            .sorted { lhs, rhs in
                // Loss first, then the rest alphabetically.
                (lhs == "loss" ? "" : lhs) < (rhs == "loss" ? "" : rhs)
            }
            .map { base in
                TrainingChart(
                    id: base,
                    title: Self.title(base),
                    lines: (objective[base] ?? []).sorted { $0.label < $1.label }
                )
            }
        for (name, title) in Self.systemCharts {
            let line = TrainingChart.Line(label: title, points: Self.points(series[name] ?? []))
            if !line.points.isEmpty {
                charts.append(TrainingChart(id: name, title: title, lines: [line]))
            }
        }
        return charts
    }

    private static let systemCharts = [
        ("learning_rate", "Learning rate"),
        ("iterations_per_second", "Iterations per second"),
        ("peak_memory", "Peak memory (GB)"),
    ]

    private static func points(_ raw: [[Double]]) -> [TrainingChart.Point] {
        raw.compactMap { pair in
            pair.count == 2 && pair[1].isFinite
                ? TrainingChart.Point(iteration: pair[0], value: pair[1])
                : nil
        }
    }

    private static func title(_ base: String) -> String {
        let words = base.replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }
}

struct TrainingChart: Identifiable, Equatable, Sendable {
    struct Point: Equatable, Sendable {
        let iteration: Double
        let value: Double
    }

    struct Line: Identifiable, Equatable, Sendable {
        let label: String
        let points: [Point]

        var id: String { label }
    }

    let id: String
    let title: String
    let lines: [Line]
}

/// Where a merged model is saved so it shows up in the model list: the model
/// folder uses the Hugging Face cache layout, one `models--owner--name`
/// folder per model with a `refs/main` pointing at a snapshot.
struct TrainingMergeDestination: Equatable, Sendable {
    static let owner = "nativ-trained"
    static let snapshotName = "trained"

    let repoID: String
    let repositoryURL: URL
    let snapshotURL: URL

    init(modelSearchPath: String, name: String, date: Date = Date()) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let modelName = Self.sanitized(name) + "-" + formatter.string(from: date)
        repoID = Self.owner + "/" + modelName
        repositoryURL = URL(
            fileURLWithPath: (modelSearchPath as NSString).expandingTildeInPath,
            isDirectory: true
        ).appendingPathComponent("models--\(Self.owner)--\(modelName)", isDirectory: true)
        snapshotURL = repositoryURL
            .appendingPathComponent("snapshots", isDirectory: true)
            .appendingPathComponent(Self.snapshotName, isDirectory: true)
    }

    /// The model id for a snapshot path this type produced, for display.
    static func repoID(forSnapshotPath path: String) -> String? {
        let parts = URL(fileURLWithPath: path).pathComponents
        guard let folder = parts.last(where: { $0.hasPrefix("models--\(owner)--") }) else {
            return nil
        }
        return owner + "/" + folder.dropFirst("models--\(owner)--".count)
    }

    /// Letters, digits, dots, and single dashes only, so the name is safe as
    /// a folder and never contains the cache layout's `--` separator.
    static func sanitized(_ name: String) -> String {
        var result = ""
        for character in name.lowercased() {
            if character.isASCII, character.isLetter || character.isNumber || character == "." {
                result.append(character)
            } else if !result.hasSuffix("-") {
                result.append("-")
            }
        }
        let trimmed = result.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        return trimmed.isEmpty ? "model" : String(trimmed.prefix(60))
    }

    /// Write the ref before training; the snapshot itself is created by the
    /// trainer at the end. A repository with no snapshot is not listed.
    func prepare() throws {
        let refs = repositoryURL.appendingPathComponent("refs", isDirectory: true)
        try FileManager.default.createDirectory(at: refs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: snapshotURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(Self.snapshotName.utf8).write(
            to: refs.appendingPathComponent("main"),
            options: .atomic
        )
    }

    /// Add the export option to a run's options.
    func apply(to options: inout [String: TrainingJSON]) {
        options["export_qat_path"] = .string(snapshotURL.path)
    }
}

struct TrainingRunList: Codable, Sendable {
    let runs: [TrainingRun]
}

struct TrainingCheck: Codable, Equatable, Sendable {
    let valid: Bool
    let errors: [String]
    let notes: [String]
}

struct TrainingLog: Codable, Sendable {
    let id: String
    let log: String
}

private struct TrainingFailure: Codable {
    let error: String
}

enum TrainingClientError: LocalizedError, Equatable {
    case missingPython(String)
    case backendUnavailable
    case failed(String)
    case invalidResponse(String)
    case invalidOption(String, String)

    var errorDescription: String? {
        switch self {
        case .missingPython(let path):
            "Nativ's Python runtime was not found at \(path)."
        case .backendUnavailable:
            "This copy of Nativ ships an MLX-VLM without the training run manager. Update Nativ to use Training."
        case .failed(let message):
            message
        case .invalidResponse(let detail):
            "The trainer returned an unexpected response: \(detail)"
        case .invalidOption(let name, let reason):
            "\(name) \(reason)."
        }
    }
}

/// Runs `python -m mlx_vlm.train_runs` and decodes its JSON output.
///
/// The trainer is a separate process: nothing here imports or links it, and
/// training itself runs detached from Nativ, so it outlives the app.
struct TrainingRunClient: Sendable {
    static let limitsFileName = "limits.json"

    let pythonURL: URL
    let environment: [String: String]
    let runsDirectory: URL

    /// Runs the run manager's file directly. `python -m mlx_vlm.train_runs`
    /// would first import the whole `mlx_vlm` package, which takes seconds;
    /// the manager itself only needs the standard library, and the page polls it.
    static let bootstrap = """
        import importlib.util, os, runpy, sys
        spec = importlib.util.find_spec("mlx_vlm")
        path = os.path.join(os.path.dirname(spec.origin), "train_runs.py") if spec and spec.origin else ""
        if not os.path.exists(path):
            sys.exit("No module named mlx_vlm.train_runs")
        sys.argv[0] = path
        runpy.run_path(path, run_name="__main__")
        """

    func arguments(for command: [String]) -> [String] {
        ["-c", Self.bootstrap, "--runs-dir", runsDirectory.path] + command
    }

    func describe() async throws -> TrainingDescription {
        try await run(["describe"])
    }

    func usage() async throws -> TrainingUsage {
        try await run(["limits"])
    }

    func runs(limit: Int = 50) async throws -> [TrainingRun] {
        let list: TrainingRunList = try await run(["list", "--limit", String(limit)])
        return list.runs
    }

    func status(_ runID: String) async throws -> TrainingRun {
        try await run(["status", runID])
    }

    func log(_ runID: String, lines: Int = 200) async throws -> String {
        let result: TrainingLog = try await run(["log", runID, "--lines", String(lines)])
        return result.log
    }

    func history(_ runID: String, maxPoints: Int = 300) async throws -> TrainingHistory {
        try await run(["history", runID, "--max-points", String(maxPoints)])
    }

    func check(options: [String: TrainingJSON]) async throws -> TrainingCheck {
        try await run(["check", "--options-file", "-"], input: try JSONEncoder().encode(options))
    }

    func start(options: [String: TrainingJSON], name: String) async throws -> TrainingRun {
        try await run(
            ["start", "--options-file", "-", "--name", name],
            input: try JSONEncoder().encode(options)
        )
    }

    /// Asks the run to save and end; it answers at its next report, so this
    /// can take a little while.
    func stop(_ runID: String) async throws -> TrainingRun {
        try await run(["stop", runID])
    }

    /// Start a new run that carries on an ended one.
    func continueRun(_ runID: String) async throws -> TrainingRun {
        try await run(["continue", runID])
    }

    func delete(_ runID: String) async throws {
        let _: TrainingDeleted = try await run(["delete", runID])
    }

    func config(_ runID: String) async throws -> TrainingRunConfig {
        try await run(["config", runID])
    }

    func sample(_ runID: String) async throws -> TrainingSample? {
        let response: TrainingSampleResponse = try await run(["sample", runID])
        return response.sample
    }

    /// Raw JSON for a command, for callers that pass the trainer's answer on
    /// unchanged. A refusal (a usage limit, a bad option) is still an answer:
    /// the trainer's own error JSON is returned rather than thrown.
    func output(_ command: [String], input: Data? = nil) async throws -> String {
        let pythonURL = pythonURL
        let environment = environment
        let arguments = arguments(for: command)
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(
                    with: Result {
                        let finished = try Self.launch(
                            pythonURL: pythonURL,
                            arguments: arguments,
                            environment: environment,
                            input: input
                        )
                        return try Self.passthrough(
                            status: finished.status,
                            output: finished.output,
                            errorOutput: finished.errorOutput
                        )
                    }
                )
            }
        }
    }

    static func passthrough(status: Int32, output: Data, errorOutput: String) throws -> String {
        let text = String(decoding: output, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if (try? JSONDecoder().decode(TrainingJSON.self, from: Data(text.utf8))) != nil, !text.isEmpty {
            return text
        }
        // No JSON at all: let decode() classify the failure.
        let _: TrainingJSON = try decode(status: status == 0 ? 1 : status, output: output, errorOutput: errorOutput)
        return text
    }

    /// Store the caps beside the runs, where every client of the folder reads them.
    func writeLimits(_ limits: TrainingLimits) throws {
        try FileManager.default.createDirectory(
            at: runsDirectory,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(limits).write(
            to: runsDirectory.appendingPathComponent(Self.limitsFileName),
            options: .atomic
        )
    }

    /// A shell script that runs the trainer with this client's Python and
    /// runs folder, so an agent can call it without knowing where Nativ lives.
    func launcherScript() -> String {
        func quoted(_ text: String) -> String {
            "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        var lines = ["#!/bin/sh", "# Written by Nativ's Training extension. Do not edit."]
        for key in ["PYTHONHOME", "PYTHONNOUSERSITE"] {
            if let value = environment[key] {
                lines.append("export \(key)=\(quoted(value))")
            }
        }
        lines.append(
            "exec \(quoted(pythonURL.path)) -c \(quoted(Self.bootstrap)) "
                + "--runs-dir \(quoted(runsDirectory.path)) \"$@\""
        )
        return lines.joined(separator: "\n") + "\n"
    }

    /// Decode a finished command. Kept separate from process handling so it
    /// can be tested without launching Python.
    static func decode<Response: Decodable>(
        _ type: Response.Type = Response.self,
        status: Int32,
        output: Data,
        errorOutput: String
    ) throws -> Response {
        let decoder = JSONDecoder()
        if status != 0 {
            if let failure = try? decoder.decode(TrainingFailure.self, from: output) {
                throw TrainingClientError.failed(failure.error)
            }
            if errorOutput.contains("No module named") {
                throw TrainingClientError.backendUnavailable
            }
            let detail = errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            throw TrainingClientError.failed(
                detail.isEmpty ? "The trainer exited with status \(status)." : String(detail.suffix(600))
            )
        }
        do {
            return try decoder.decode(Response.self, from: output)
        } catch {
            throw TrainingClientError.invalidResponse(error.localizedDescription)
        }
    }

    private func run<Response: Decodable & Sendable>(
        _ command: [String],
        input: Data? = nil
    ) async throws -> Response {
        let pythonURL = pythonURL
        let environment = environment
        let arguments = arguments(for: command)
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(
                    with: Result {
                        try Self.execute(
                            Response.self,
                            pythonURL: pythonURL,
                            arguments: arguments,
                            environment: environment,
                            input: input
                        )
                    }
                )
            }
        }
    }

    private static func execute<Response: Decodable>(
        _ type: Response.Type,
        pythonURL: URL,
        arguments: [String],
        environment: [String: String],
        input: Data?
    ) throws -> Response {
        let finished = try launch(
            pythonURL: pythonURL,
            arguments: arguments,
            environment: environment,
            input: input
        )
        return try decode(
            Response.self,
            status: finished.status,
            output: finished.output,
            errorOutput: finished.errorOutput
        )
    }

    private static func launch(
        pythonURL: URL,
        arguments: [String],
        environment: [String: String],
        input: Data?
    ) throws -> (status: Int32, output: Data, errorOutput: String) {
        guard FileManager.default.isExecutableFile(atPath: pythonURL.path) else {
            throw TrainingClientError.missingPython(pythonURL.path)
        }
        let process = Process()
        process.executableURL = pythonURL
        process.arguments = arguments
        process.environment = environment
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let inputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.standardInput = inputPipe
        try process.run()

        // Drain stderr on its own queue so a chatty child cannot fill the
        // pipe and stall while stdout is being read.
        let errorBox = TrainingOutputBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            errorBox.set(errorPipe.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }
        if let input {
            try? inputPipe.fileHandleForWriting.write(contentsOf: input)
        }
        try? inputPipe.fileHandleForWriting.close()
        let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        group.wait()
        return (
            process.terminationStatus,
            output,
            String(decoding: errorBox.value, as: UTF8.self)
        )
    }
}

private final class TrainingOutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    var value: Data {
        lock.withLock { data }
    }

    func set(_ newValue: Data) {
        lock.withLock { data = newValue }
    }
}
