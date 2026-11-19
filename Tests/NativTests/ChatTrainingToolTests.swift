import Foundation
import NativServerKit
import XCTest

final class ChatTrainingToolTests: XCTestCase {
    private func command(_ tool: String, _ arguments: String?) throws -> ChatTrainingToolCommand {
        try ChatTrainingToolCommand(toolName: tool, argumentsJSON: arguments)
    }

    private func object(_ data: Data?) throws -> [String: TrainingJSON] {
        try JSONDecoder().decode([String: TrainingJSON].self, from: try XCTUnwrap(data))
    }

    func testEveryToolHasADefinitionAndAUniqueName() {
        let names = ChatTrainingToolRegistry.definitions().map(\.function.name)
        XCTAssertEqual(names, ChatTrainingToolRegistry.toolNames)
        XCTAssertEqual(Set(names).count, names.count)
    }

    func testToolsAreOfferedOnlyWhileTheExtensionProvidesAClient() {
        ChatTrainingToolRegistry.setClient(nil)
        XCTAssertFalse(ChatTrainingToolRegistry.isAvailable)
        ChatTrainingToolRegistry.setClient(
            TrainingRunClient(
                pythonURL: URL(fileURLWithPath: "/usr/bin/false"),
                environment: [:],
                runsDirectory: URL(fileURLWithPath: "/tmp/runs")
            )
        )
        XCTAssertTrue(ChatTrainingToolRegistry.isAvailable)
        ChatTrainingToolRegistry.setClient(nil)
    }

    func testCheckAndStartSendOptionsOnStandardInput() throws {
        let check = try command(
            "check_training_config",
            #"{"options": {"model": "org/name", "algorithm": "sft", "epochs": 2}}"#
        )
        XCTAssertEqual(check.arguments, ["check", "--options-file", "-"])
        XCTAssertEqual(
            try object(check.input),
            ["model": .string("org/name"), "algorithm": .string("sft"), "epochs": .number(2)]
        )

        // A small model may send the options object as a JSON string.
        let start = try command(
            "start_training",
            #"{"options": "{\"model\": \"org/name\"}", "name": " colors "}"#
        )
        XCTAssertEqual(start.arguments, ["start", "--options-file", "-", "--name", "colors"])
        XCTAssertEqual(try object(start.input), ["model": .string("org/name")])

        XCTAssertThrowsError(try command("start_training", #"{"name": "x"}"#))
        XCTAssertThrowsError(try command("check_training_config", #"{"options": 3}"#))
    }

    func testRunCommandsDefaultToTheNewestRunAndClampNumbers() throws {
        XCTAssertEqual(try command("training_status", nil).arguments, ["status"])
        XCTAssertEqual(try command("training_status", #"{"run_id": "abc"}"#).arguments, ["status", "abc"])
        XCTAssertEqual(
            try command("training_log", #"{"run_id": "abc", "lines": 9000}"#).arguments,
            ["log", "abc", "--lines", "200"]
        )
        XCTAssertEqual(try command("training_log", "{}").arguments, ["log", "--lines", "40"])
        XCTAssertEqual(try command("list_training_runs", #"{"limit": 0}"#).arguments, ["list", "--limit", "1"])
        XCTAssertEqual(try command("stop_training", "").arguments, ["stop"])
        XCTAssertEqual(try command("training_limits", "{}").arguments, ["limits"])
        XCTAssertEqual(
            try command("validate_model_support", #"{"model": "org/name"}"#).arguments,
            ["validate-model", "org/name"]
        )
        XCTAssertThrowsError(try command("validate_model_support", "{}"))
        XCTAssertThrowsError(try command("training_log", #"{"lines": "many"}"#))
        XCTAssertThrowsError(try command("training_status", "[1]"))
        XCTAssertThrowsError(try command("delete_everything", "{}")) { error in
            XCTAssertEqual(error as? ChatTrainingToolError, .unsupportedTool("delete_everything"))
        }
    }

    func testInspectDatasetForwardsOnlyDatasetFields() throws {
        let inspect = try command("inspect_dataset", #"{"data": "/data/colors", "train_split": "train"}"#)
        XCTAssertEqual(inspect.arguments, ["inspect-dataset", "--options-file", "-"])
        XCTAssertEqual(
            try object(inspect.input),
            ["data": .string("/data/colors"), "train_split": .string("train")]
        )
    }

    func testModesAreSummarizedSoOneCallStaysSmall() throws {
        let description = """
        {"version": "0.9.0", "tasks": {"vlm": {"default_algorithm": "sft", "algorithms": {
          "sft": {"description": "Supervised fine-tuning settings.", "options": [
            {"name": "model", "flag": "--model", "type": "str", "default": null, "choices": null, "help": "Model path.", "group": "general"},
            {"name": "train_type", "flag": "--train-type", "type": "str", "default": "lora", "choices": ["lora", "dora", "full"], "help": null, "group": "general"},
            {"name": "max_iters", "flag": "--max-iters", "type": "int", "default": null, "choices": null, "help": null, "group": "managed"}]},
          "grpo": {"description": "", "options": [], "reward_functions": ["accuracy_reward"]}}}}}
        """
        let overview = try object(
            Data(try command("list_training_modes", "{}").summarizeModes(description).utf8)
        )
        guard case .object(let tasks)? = overview["tasks"],
              case .object(let vlm)? = tasks["vlm"],
              case .object(let algorithms)? = vlm["algorithms"] else {
            return XCTFail("Unexpected overview shape")
        }
        XCTAssertEqual(vlm["default_algorithm"], .string("sft"))
        XCTAssertEqual(algorithms.keys.sorted(), ["grpo", "sft"])
        // The overview carries no option lists.
        XCTAssertEqual(
            algorithms["sft"],
            .object(["description": .string("Supervised fine-tuning settings.")])
        )

        let detail = try object(
            Data(try command("list_training_modes", #"{"algorithm": "sft"}"#).summarizeModes(description).utf8)
        )
        guard case .array(let options)? = detail["options"] else {
            return XCTFail("Missing options")
        }
        // Options the run manager owns are not offered to the model.
        XCTAssertEqual(options.count, 2)
        XCTAssertEqual(detail["task"], .string("vlm"))
        XCTAssertThrowsError(
            try command("list_training_modes", #"{"algorithm": "nope"}"#).summarizeModes(description)
        )
    }

    func testRefusalsReachTheModelAsTheTrainersOwnAnswer() throws {
        let refusal = #"{"error": "Usage cap: 1 of 1 concurrent runs in use. Stop a run first.", "type": "RuntimeError"}"#
        XCTAssertEqual(
            try TrainingRunClient.passthrough(status: 1, output: Data(refusal.utf8), errorOutput: ""),
            refusal
        )
        XCTAssertThrowsError(
            try TrainingRunClient.passthrough(
                status: 1,
                output: Data(),
                errorOutput: "python3: No module named mlx_vlm.train_runs"
            )
        ) { error in
            XCTAssertEqual(error as? TrainingClientError, .backendUnavailable)
        }
        let failure = ChatTrainingToolExecutor().failurePayload(
            operation: "start_training",
            error: ChatTrainingToolError.unavailable
        )
        XCTAssertTrue(failure.contains(#""ok":false"#))
        XCTAssertTrue(failure.contains("Training extension"))
    }

    func testStartCanMergeTheResultIntoTheModelFolder() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("nativ-models-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: folder)
        }
        var plain = try command("start_training", #"{"options": {"model": "org/tiny"}}"#)
        XCTAssertNil(try plain.prepareMerge(modelSearchPath: folder.path))
        XCTAssertNil(try object(plain.input)["export_qat_path"])

        var merged = try command(
            "start_training",
            #"{"options": {"model": "org/tiny", "iters": 5}, "merge_into_library": true}"#
        )
        let repoID = try XCTUnwrap(try merged.prepareMerge(modelSearchPath: folder.path))
        XCTAssertTrue(repoID.hasPrefix("nativ-trained/tiny-"))
        guard case .string(let path)? = try object(merged.input)["export_qat_path"] else {
            return XCTFail("Missing export path")
        }
        XCTAssertTrue(path.hasPrefix(folder.path))
        XCTAssertEqual(try object(merged.input)["iters"], .number(5))

        var unavailable = try command(
            "start_training",
            #"{"options": {"model": "org/tiny"}, "merge_into_library": true}"#
        )
        XCTAssertThrowsError(try unavailable.prepareMerge(modelSearchPath: nil))
        XCTAssertThrowsError(
            try command("start_training", #"{"options": {"model": "m"}, "merge_into_library": "yes"}"#)
        )
    }
}
