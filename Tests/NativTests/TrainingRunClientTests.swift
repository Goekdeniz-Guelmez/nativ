import Foundation
import XCTest

final class TrainingRunClientTests: XCTestCase {
    private let client = TrainingRunClient(
        pythonURL: URL(fileURLWithPath: "/opt/py/bin/python3"),
        environment: ["PYTHONHOME": "/opt/py", "PYTHONNOUSERSITE": "1", "PATH": "/usr/bin"],
        runsDirectory: URL(fileURLWithPath: "/Users/someone/it's here/runs")
    )

    func testArgumentsTargetTheRunManagerAndRunsFolder() {
        XCTAssertEqual(
            client.arguments(for: ["status", "abc"]),
            ["-c", TrainingRunClient.bootstrap, "--runs-dir", "/Users/someone/it's here/runs", "status", "abc"]
        )
    }

    func testDescriptionDecodesWhateverTheTrainerReports() throws {
        let json = """
        {"version": "0.9.0", "limits": {"max_concurrent_runs": 1},
         "tasks": {
          "vlm": {"default_algorithm": "sft", "algorithms": {"sft": {"description": "Supervised fine-tuning settings.", "config": "SFTTrainConfig",
            "options": [
              {"name": "model", "flag": "--model", "type": "str", "default": null, "choices": null, "help": "Model path.", "group": "general"},
              {"name": "train_type", "flag": "--train-type", "type": "str", "default": "lora", "choices": ["lora", "dora", "full"], "help": null, "group": "general"},
              {"name": "iters", "flag": "--iters", "type": "int", "default": 100, "choices": null, "help": "Iterations.", "group": "training"},
              {"name": "max_iters", "flag": "--max-iters", "type": "int", "default": null, "choices": null, "help": null, "group": "managed"}
            ]}}},
          "asr": {"algorithms": {"ctc": {"description": "", "options": [], "reward_functions": ["accuracy_reward"]}}}
         }}
        """
        let description: TrainingDescription = try TrainingRunClient.decode(
            status: 0,
            output: Data(json.utf8),
            errorOutput: ""
        )
        // A modality or algorithm Nativ has never heard of decodes the same way.
        XCTAssertEqual(description.tasks.keys.sorted(), ["asr", "vlm"])
        XCTAssertEqual(description.tasks["vlm"]?.defaultAlgorithm, "sft")
        XCTAssertNil(description.tasks["asr"]?.defaultAlgorithm)
        XCTAssertEqual(description.tasks["asr"]?.algorithms["ctc"]?.rewardFunctions, ["accuracy_reward"])
        let options = try XCTUnwrap(description.tasks["vlm"]?.algorithms["sft"]?.options)
        XCTAssertEqual(options.map(\.name), ["model", "train_type", "iters", "max_iters"])
        XCTAssertEqual(options[1].choices?.map(\.displayText), ["lora", "dora", "full"])
        XCTAssertEqual(options[2].defaultValue.displayText, "100")
        XCTAssertEqual(options.filter(\.isManaged).map(\.name), ["max_iters"])
    }

    func testRunDecodesProgressAndCapReason() throws {
        let json = """
        {"runs": [{"id": "20261116-165938-sft-b553", "name": "capped", "status": "capped", "task": "vlm",
          "algorithm": "sft", "model": "org/model", "created_at": "2026-11-16T16:59:38+01:00",
          "ended_at": "2026-11-16T17:00:10+01:00", "exit_code": 0, "adapter_path": "/runs/x/adapters",
          "log_path": "/runs/x/train.log", "notes": [], "iters": 2000, "iteration": 10,
          "metrics": {"train_loss": 0.0031, "iteration": 10, "train_token_accuracy": 1.0},
          "capped": "max_minutes (0.1) reached"}]}
        """
        let list: TrainingRunList = try TrainingRunClient.decode(
            status: 0,
            output: Data(json.utf8),
            errorOutput: ""
        )
        let run = try XCTUnwrap(list.runs.first)
        XCTAssertEqual(run.title, "capped")
        XCTAssertFalse(run.isActive)
        XCTAssertEqual(run.progress ?? 0, 0.005, accuracy: 1e-9)
        XCTAssertEqual(run.capped, "max_minutes (0.1) reached")
        XCTAssertEqual(run.metrics?["train_loss"]?.displayText, "0.0031")
        XCTAssertEqual(run.metrics?["iteration"]?.displayText, "10")
    }

    func testFailuresBecomeReadableErrors() {
        XCTAssertThrowsError(
            try TrainingRunClient.decode(
                TrainingUsage.self,
                status: 1,
                output: Data(#"{"error": "Usage cap: 1 of 1 concurrent runs in use.", "type": "RuntimeError"}"#.utf8),
                errorOutput: ""
            )
        ) { error in
            XCTAssertEqual(
                error as? TrainingClientError,
                .failed("Usage cap: 1 of 1 concurrent runs in use.")
            )
        }
        XCTAssertThrowsError(
            try TrainingRunClient.decode(
                TrainingUsage.self,
                status: 1,
                output: Data(),
                errorOutput: "/opt/py/bin/python3: No module named mlx_vlm.train_runs"
            )
        ) { error in
            XCTAssertEqual(error as? TrainingClientError, .backendUnavailable)
        }
        XCTAssertThrowsError(
            try TrainingRunClient.decode(
                TrainingUsage.self,
                status: 0,
                output: Data("not json".utf8),
                errorOutput: ""
            )
        )
    }

    func testFormTextConvertsByOptionType() throws {
        func option(_ type: String) throws -> TrainingOption {
            try JSONDecoder().decode(
                TrainingOption.self,
                from: Data(#"{"name": "x", "flag": "--x", "type": "\#(type)"}"#.utf8)
            )
        }
        XCTAssertNil(try option("int").jsonValue(from: "  "))
        XCTAssertEqual(try option("int").jsonValue(from: "20"), .number(20))
        XCTAssertEqual(try option("float").jsonValue(from: "1e-4"), .number(1e-4))
        XCTAssertEqual(try option("bool").jsonValue(from: "true"), .bool(true))
        XCTAssertEqual(try option("str").jsonValue(from: " org/model "), .string("org/model"))
        XCTAssertEqual(
            try option("list").jsonValue(from: "q_proj v_proj"),
            .array([.string("q_proj"), .string("v_proj")])
        )
        XCTAssertEqual(
            try option("json").jsonValue(from: #"{"prompt_feature": "question"}"#),
            .object(["prompt_feature": .string("question")])
        )
        XCTAssertThrowsError(try option("int").jsonValue(from: "ten"))
        XCTAssertThrowsError(try option("json").jsonValue(from: "{oops"))
    }

    func testLimitsAlwaysWriteEveryCap() throws {
        let limits = TrainingLimits(maxConcurrentRuns: nil, maxIters: 2000, maxMinutes: 60)
        let object = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(limits)
        ) as? [String: Any]
        // Unlimited is written as null so the trainer does not fall back to its default.
        XCTAssertEqual(object?.keys.sorted(), [
            "max_concurrent_runs", "max_iters", "max_memory_gb", "max_minutes", "max_runs_per_day",
        ])
        XCTAssertTrue(object?["max_concurrent_runs"] is NSNull)
        XCTAssertEqual(object?["max_iters"] as? Int, 2000)
        XCTAssertEqual(try JSONDecoder().decode(TrainingLimits.self, from: JSONEncoder().encode(limits)), limits)
    }

    func testWriteLimitsStoresTheFileBesideTheRuns() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("nativ-training-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: folder)
        }
        let client = TrainingRunClient(
            pythonURL: URL(fileURLWithPath: "/usr/bin/false"),
            environment: [:],
            runsDirectory: folder
        )
        try client.writeLimits(TrainingLimits(maxRunsPerDay: 3))
        let stored = try JSONDecoder().decode(
            TrainingLimits.self,
            from: Data(contentsOf: folder.appendingPathComponent("limits.json"))
        )
        XCTAssertEqual(stored, TrainingLimits(maxRunsPerDay: 3))
    }

    func testLauncherScriptQuotesPathsAndForwardsArguments() {
        let script = client.launcherScript()
        XCTAssertTrue(script.hasPrefix("#!/bin/sh\n"))
        XCTAssertTrue(script.contains("export PYTHONHOME='/opt/py'\n"))
        XCTAssertFalse(script.contains("PATH='/usr/bin'"))
        XCTAssertTrue(script.contains("exec '/opt/py/bin/python3' -c 'import importlib.util"))
        XCTAssertTrue(script.contains("sys.exit(\"No module named mlx_vlm.train_runs\")"))
        XCTAssertTrue(
            script.hasSuffix(#"' --runs-dir '/Users/someone/it'\''s here/runs' "$@""# + "\n")
        )
    }

    func testChartsFollowTheMetricsTheAlgorithmReported() throws {
        func history(_ series: String) throws -> TrainingHistory {
            try JSONDecoder().decode(
                TrainingHistory.self,
                from: Data(#"{"id": "r", "status": "running", "algorithm": "x", "iters": 10, "series": \#(series)}"#.utf8)
            )
        }
        // Plain supervised training: loss and accuracy, plus the machine charts.
        let supervised = try history("""
            {"train_loss": [[5, 2.0], [10, 1.0]], "val_loss": [[10, 1.5]],
             "train_token_accuracy": [[5, 0.4], [10, 0.6]],
             "train_num_tokens": [[5, 20]], "val_tokens_per_second": [[10, 68.0]], "val_time": [[10, 0.1]],
             "learning_rate": [[5, 0.001]], "tokens_per_second": [[5, 9.0]]}
            """)
        XCTAssertEqual(supervised.charts.map(\.id), ["loss", "token_accuracy", "learning_rate"])
        XCTAssertEqual(supervised.charts[0].title, "Loss")
        XCTAssertEqual(supervised.charts[0].lines.map(\.label), ["Training", "Validation"])
        XCTAssertEqual(supervised.charts[0].lines[0].points.last, .init(iteration: 10, value: 1.0))
        XCTAssertEqual(supervised.charts[1].title, "Token accuracy")

        // A preference algorithm reports more, so it gets more charts.
        let preference = try history("""
            {"train_loss": [[5, 0.7]], "train_reward_accuracy": [[5, 0.5]], "train_reward_margin": [[5, 0.1]],
             "train_chosen_reward": [[5, 1.0]], "train_rejected_reward": [[5, -1.0]], "peak_memory": [[5, 2.0]]}
            """)
        XCTAssertEqual(
            preference.charts.map(\.id),
            ["loss", "chosen_reward", "rejected_reward", "reward_accuracy", "reward_margin", "peak_memory"]
        )
        XCTAssertTrue(try history("{}").charts.isEmpty)
    }

    func testMergedModelsUseTheModelFolderLayout() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("nativ-models-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: folder)
        }
        let destination = TrainingMergeDestination(
            modelSearchPath: folder.path,
            name: "My Run -- v2!",
            date: Date(timeIntervalSince1970: 0)
        )
        XCTAssertTrue(destination.repoID.hasPrefix("nativ-trained/my-run-v2-19700101-"))
        // The cache layout separates owner and name with "--"; a name must never contain it.
        XCTAssertFalse(destination.repoID.dropFirst("nativ-trained/".count).contains("--"))
        XCTAssertEqual(destination.snapshotURL.lastPathComponent, "trained")
        XCTAssertEqual(
            destination.repositoryURL.lastPathComponent,
            "models--" + destination.repoID.replacingOccurrences(of: "/", with: "--")
        )
        try destination.prepare()
        let ref = try String(
            contentsOf: destination.repositoryURL.appendingPathComponent("refs/main"),
            encoding: .utf8
        )
        XCTAssertEqual(ref, "trained")
        // The trainer creates the snapshot folder itself and refuses an existing one.
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.snapshotURL.path))
        var options: [String: TrainingJSON] = ["model": .string("org/name")]
        destination.apply(to: &options)
        XCTAssertEqual(options["export_qat_path"], .string(destination.snapshotURL.path))
        XCTAssertEqual(
            TrainingMergeDestination.repoID(forSnapshotPath: destination.snapshotURL.path),
            destination.repoID
        )
        XCTAssertEqual(TrainingMergeDestination.sanitized("///"), "model")
    }
}
