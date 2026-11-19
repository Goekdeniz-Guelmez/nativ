import Foundation
import NativServerKit

/// Tools that let the model train: it checks, starts, follows, and stops
/// runs itself. They are thin calls into `mlx_vlm.train_runs`, so the model
/// sees exactly what the trainer reports and works under the user's limits.
enum ChatTrainingToolRegistry {
    static let listModesToolName = "list_training_modes"
    static let limitsToolName = "training_limits"
    static let validateModelToolName = "validate_model_support"
    static let inspectDatasetToolName = "inspect_dataset"
    static let checkToolName = "check_training_config"
    static let startToolName = "start_training"
    static let statusToolName = "training_status"
    static let logToolName = "training_log"
    static let listRunsToolName = "list_training_runs"
    static let stopToolName = "stop_training"

    static let toolNames = [
        listModesToolName, limitsToolName, validateModelToolName, inspectDatasetToolName,
        checkToolName, startToolName, statusToolName, logToolName, listRunsToolName,
        stopToolName,
    ]

    // The Training extension supplies the client while it is enabled. With no
    // client the tools are not offered to the model at all.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var currentClient: TrainingRunClient?

    static var client: TrainingRunClient? {
        lock.withLock { currentClient }
    }

    static var isAvailable: Bool {
        client != nil
    }

    static func setClient(_ client: TrainingRunClient?) {
        lock.withLock { currentClient = client }
    }

    static func definitions() -> [MLXChatToolDefinition] {
        let runID: (String, MLXJSONValue) = (
            "run_id",
            property("string", "Run id, id prefix, or name. Omit for the newest run.")
        )
        let options: (String, MLXJSONValue) = (
            "options",
            property(
                "object",
                "Training options keyed by the names from list_training_modes, e.g. {\"model\": \"org/name\", \"algorithm\": \"sft\", \"data\": \"/path/to/data\", \"epochs\": 2}. Set only what the user asked for."
            )
        )
        return [
            definition(
                listModesToolName,
                "List what the trainer can do. Without arguments: every task and algorithm with a description. With algorithm: that algorithm's options with types and defaults. Call this before building training options; never assume option names.",
                properties: [
                    ("task", property("string", "Task to describe. Omit for the default task.")),
                    ("algorithm", property("string", "Algorithm whose options to list.")),
                ]
            ),
            definition(
                limitsToolName,
                "Show the user's training usage limits and current usage: concurrent runs, runs per day, iterations, minutes, and memory per run. null means unlimited.",
                properties: []
            ),
            definition(
                validateModelToolName,
                "Check that a model's architecture can be trained. Reads its config only; says nothing about memory fit.",
                properties: [("model", property("string", "Hugging Face id or local path."))],
                required: ["model"]
            ),
            definition(
                inspectDatasetToolName,
                "Check that a dataset loads, and report its splits, row counts, and columns.",
                properties: [
                    ("data", property("string", "Folder with train.jsonl, a .jsonl file, or a Hub dataset.")),
                    ("dataset", property("string", "Dataset loaded with Hugging Face datasets; overrides data.")),
                    ("hf_dataset_config", property("string", "Optional Hugging Face dataset configuration.")),
                    ("train_split", property("string", "Training split name. Default: train.")),
                ]
            ),
            definition(
                checkToolName,
                "Validate training options without starting anything. Always call this before start_training and fix every error it reports.",
                properties: [options],
                required: ["options"]
            ),
            definition(
                startToolName,
                "Start a training run in the background and return its run id. Call check_training_config first. Refused when a usage limit is reached.",
                properties: [
                    options,
                    ("name", property("string", "Optional short label for the run.")),
                    (
                        "merge_into_library",
                        property(
                            "boolean",
                            "true merges the trained weights into a full model and adds it to the user's model list when the run ends. Use it when the user wants to chat with or reuse the result."
                        )
                    ),
                ],
                required: ["options"]
            ),
            definition(
                statusToolName,
                "Show a run's status, iteration, and latest metrics. Status is running, completed, capped (stopped at a usage limit with weights saved), stopped, or failed.",
                properties: [runID]
            ),
            definition(
                logToolName,
                "Show the end of a run's training log. Use it when a run failed or looks wrong.",
                properties: [runID, ("lines", property("integer", "Lines to return, 1-200. Default 40."))]
            ),
            definition(
                listRunsToolName,
                "List recent training runs, newest first, with their status.",
                properties: [("limit", property("integer", "Runs to return, 1-50. Default 10."))]
            ),
            definition(
                stopToolName,
                "Stop a running training run. Checkpoints saved so far are kept. Only call this when the user asks.",
                properties: [runID]
            ),
        ]
    }

    private static func property(_ type: String, _ description: String) -> MLXJSONValue {
        .object(["type": .string(type), "description": .string(description)])
    }

    private static func definition(
        _ name: String,
        _ description: String,
        properties: [(String, MLXJSONValue)],
        required: [String] = []
    ) -> MLXChatToolDefinition {
        var parameters: [String: MLXJSONValue] = [
            "type": .string("object"),
            "additionalProperties": .bool(false),
            "properties": .object(Dictionary(uniqueKeysWithValues: properties)),
        ]
        if !required.isEmpty {
            parameters["required"] = .array(required.map { .string($0) })
        }
        return MLXChatToolDefinition(function: MLXChatFunctionDefinition(
            name: name,
            description: description,
            parameters: .object(parameters)
        ))
    }
}

enum ChatTrainingToolError: LocalizedError, Equatable {
    case unavailable
    case unsupportedTool(String)
    case invalidArguments(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "Training is not available. Ask the user to enable the Training extension in Nativ."
        case .unsupportedTool(let name):
            "Unsupported training tool: \(name)."
        case .invalidArguments(let message):
            message
        }
    }
}

/// One call to the run manager: its arguments and optional JSON on stdin.
struct ChatTrainingToolCommand: Equatable, Sendable {
    var arguments: [String]
    var input: Data? = nil
    /// For list_training_modes: narrow the trainer's full description.
    var task: String? = nil
    var algorithm: String? = nil
    /// For start_training: also save a merged model into the model list.
    var mergeIntoLibrary = false
    var runName = ""
    var modelName = "model"

    init(toolName: String, argumentsJSON: String?) throws {
        let text = argumentsJSON?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let object = text.isEmpty
            ? [String: TrainingJSON]()
            : try? JSONDecoder().decode([String: TrainingJSON].self, from: Data(text.utf8))
        guard let arguments = object else {
            throw ChatTrainingToolError.invalidArguments("Arguments must be a JSON object.")
        }
        func string(_ key: String) throws -> String? {
            switch arguments[key] {
            case nil, .some(.null):
                return nil
            case .some(.string(let value)) where !value.contains("\0"):
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            default:
                throw ChatTrainingToolError.invalidArguments("\(key) must be a string.")
            }
        }
        func integer(_ key: String, default fallback: Int, range: ClosedRange<Int>) throws -> String {
            switch arguments[key] {
            case nil, .some(.null):
                return String(fallback)
            case .some(.number(let value)) where value.rounded() == value:
                return String(min(max(Int(value), range.lowerBound), range.upperBound))
            default:
                throw ChatTrainingToolError.invalidArguments("\(key) must be a whole number.")
            }
        }
        // Small models sometimes send the options object as a JSON string.
        func options() throws -> Data {
            var value = arguments["options"] ?? .null
            if case .string(let text) = value,
               let decoded = try? JSONDecoder().decode(TrainingJSON.self, from: Data(text.utf8)) {
                value = decoded
            }
            guard case .object = value else {
                throw ChatTrainingToolError.invalidArguments(
                    "options is required and must be a JSON object of training options."
                )
            }
            return try JSONEncoder().encode(value)
        }

        switch toolName {
        case ChatTrainingToolRegistry.listModesToolName:
            self.arguments = ["describe"]
            task = try string("task")
            algorithm = try string("algorithm")
        case ChatTrainingToolRegistry.limitsToolName:
            self.arguments = ["limits"]
        case ChatTrainingToolRegistry.validateModelToolName:
            guard let model = try string("model") else {
                throw ChatTrainingToolError.invalidArguments("model is required.")
            }
            self.arguments = ["validate-model", model]
        case ChatTrainingToolRegistry.inspectDatasetToolName:
            var dataset: [String: TrainingJSON] = [:]
            for key in ["data", "dataset", "hf_dataset_config", "train_split"] {
                if let value = try string(key) {
                    dataset[key] = .string(value)
                }
            }
            self.arguments = ["inspect-dataset", "--options-file", "-"]
            input = try JSONEncoder().encode(dataset)
        case ChatTrainingToolRegistry.checkToolName:
            self.arguments = ["check", "--options-file", "-"]
            input = try options()
        case ChatTrainingToolRegistry.startToolName:
            runName = try string("name") ?? ""
            self.arguments = ["start", "--options-file", "-", "--name", runName]
            input = try options()
            switch arguments["merge_into_library"] {
            case nil, .some(.null):
                break
            case .some(.bool(let merge)):
                mergeIntoLibrary = merge
            default:
                throw ChatTrainingToolError.invalidArguments("merge_into_library must be true or false.")
            }
            if let data = input,
               case .object(let values)? = try? JSONDecoder().decode(TrainingJSON.self, from: data),
               case .string(let model)? = values["model"] {
                modelName = model.split(separator: "/").last.map(String.init) ?? model
            }
        case ChatTrainingToolRegistry.statusToolName:
            self.arguments = ["status"] + [try string("run_id")].compactMap { $0 }
        case ChatTrainingToolRegistry.logToolName:
            self.arguments = ["log"] + [try string("run_id")].compactMap { $0 }
                + ["--lines", try integer("lines", default: 40, range: 1...200)]
        case ChatTrainingToolRegistry.listRunsToolName:
            self.arguments = ["list", "--limit", try integer("limit", default: 10, range: 1...50)]
        case ChatTrainingToolRegistry.stopToolName:
            self.arguments = ["stop"] + [try string("run_id")].compactMap { $0 }
        default:
            throw ChatTrainingToolError.unsupportedTool(toolName)
        }
    }

    /// Point the run's export at the model folder and return the model id the
    /// result will have. Does nothing unless a merge was asked for.
    mutating func prepareMerge(modelSearchPath: String?, date: Date = Date()) throws -> String? {
        guard mergeIntoLibrary else {
            return nil
        }
        guard let modelSearchPath, !modelSearchPath.isEmpty, let data = input,
              case .object(var options)? = try? JSONDecoder().decode(TrainingJSON.self, from: data) else {
            throw ChatTrainingToolError.invalidArguments(
                "The merged model cannot be saved because the model folder is not available."
            )
        }
        let destination = TrainingMergeDestination(
            modelSearchPath: modelSearchPath,
            name: runName.isEmpty ? modelName : runName,
            date: date
        )
        try destination.prepare()
        destination.apply(to: &options)
        input = try JSONEncoder().encode(TrainingJSON.object(options))
        return destination.repoID
    }

    /// Shrink the trainer's full description to what the model asked for, so
    /// one call does not spend the context on every option of every algorithm.
    func summarizeModes(_ output: String) throws -> String {
        let description = try JSONDecoder().decode(TrainingDescription.self, from: Data(output.utf8))
        let taskName = task ?? description.tasks.keys.sorted().first ?? ""
        guard let algorithm else {
            var tasks: [String: TrainingJSON] = [:]
            for (name, entry) in description.tasks {
                var algorithms: [String: TrainingJSON] = [:]
                for (algorithmName, details) in entry.algorithms {
                    var summary: [String: TrainingJSON] = ["description": .string(details.description)]
                    if let rewards = details.rewardFunctions {
                        summary["reward_functions"] = .array(rewards.map { .string($0) })
                    }
                    algorithms[algorithmName] = .object(summary)
                }
                tasks[name] = .object([
                    "default_algorithm": entry.defaultAlgorithm.map { .string($0) } ?? .null,
                    "algorithms": .object(algorithms),
                ])
            }
            return try Self.encode([
                "tasks": .object(tasks),
                "next": .string("Call list_training_modes with an algorithm to see its options."),
            ])
        }
        guard let details = description.tasks[taskName]?.algorithms[algorithm] else {
            let known = description.tasks[taskName]?.algorithms.keys.sorted() ?? []
            throw ChatTrainingToolError.invalidArguments(
                "Unknown algorithm '\(algorithm)' for task '\(taskName)'. Available: \(known.joined(separator: ", "))."
            )
        }
        let options: [TrainingJSON] = details.options.filter { !$0.isManaged }.map { option in
            var entry: [String: TrainingJSON] = [
                "name": .string(option.name),
                "type": .string(option.type),
                "default": option.defaultValue,
            ]
            if let choices = option.choices {
                entry["choices"] = .array(choices)
            }
            if let help = option.help {
                entry["help"] = .string(help)
            }
            return .object(entry)
        }
        return try Self.encode([
            "task": .string(taskName),
            "algorithm": .string(algorithm),
            "description": .string(details.description),
            "options": .array(options),
        ])
    }

    private static func encode(_ object: [String: TrainingJSON]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(TrainingJSON.object(object)), as: UTF8.self)
    }
}

struct ChatTrainingToolExecutor {
    func execute(call: MLXChatToolCall, modelSearchPath: String? = nil) async throws -> String {
        guard let name = call.function?.name else {
            throw ChatTrainingToolError.unsupportedTool("unknown")
        }
        var command = try ChatTrainingToolCommand(toolName: name, argumentsJSON: call.function?.arguments)
        guard let client = ChatTrainingToolRegistry.client else {
            throw ChatTrainingToolError.unavailable
        }
        let mergedModelID = try command.prepareMerge(modelSearchPath: modelSearchPath)
        let output = try await client.output(command.arguments, input: command.input)
        if name == ChatTrainingToolRegistry.listModesToolName {
            return try command.summarizeModes(output)
        }
        // Tell the model the id the merged result will have in the model list.
        if let mergedModelID,
           case .object(var result)? = try? JSONDecoder().decode(TrainingJSON.self, from: Data(output.utf8)),
           result["error"] == nil {
            result["merged_model"] = .string(mergedModelID)
            if let data = try? JSONEncoder().encode(TrainingJSON.object(result)) {
                return String(decoding: data, as: UTF8.self)
            }
        }
        return output
    }

    func failurePayload(operation: String, error: Error) -> String {
        let payload: [String: TrainingJSON] = [
            "ok": .bool(false),
            "tool": .string(operation),
            "error": .string(error.localizedDescription),
        ]
        guard let data = try? JSONEncoder().encode(TrainingJSON.object(payload)) else {
            return #"{"ok":false,"error":"Training tool failed."}"#
        }
        return String(decoding: data, as: UTF8.self)
    }
}
