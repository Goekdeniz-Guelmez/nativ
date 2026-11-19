import AppKit
import Foundation
import NativExtensionSDK
import NativServerKit
import SwiftUI

/// Host adapter for the Training extension.
///
/// Training runs in Nativ's bundled Python through `mlx_vlm.train_runs`. The
/// adapter only locates that runtime and supplies the page; it holds no
/// training logic and no list of algorithms.
@MainActor
final class TrainingExtension: NativHostExtension {
    static let extensionID = "com.nativ.training"
    static let runsPageID = "com.nativ.training.runs"
    static let showRunsFolderCommandID = "com.nativ.training.show-runs-folder"
    /// Developer override: a Python with a newer MLX-VLM than the bundled one.
    static let pythonPathDefaultsKey = "nativ.training.pythonPath"

    let manifest: NativExtensionManifest

    private let store = TrainingStore()
    private let defaults: UserDefaults

    init(bundle: Bundle = .main, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        manifest = Self.loadBundledManifest(bundle: bundle) ?? Self.fallbackManifest
    }

    func activate(context: NativExtensionHostContext) {
        do {
            let client = try Self.makeClient(defaults: defaults)
            store.configure(client: client)
            ChatTrainingToolRegistry.setClient(client)
            try Self.writeLauncher(for: client)
        } catch {
            store.configure(client: nil)
            store.errorMessage = error.localizedDescription
        }
    }

    func deactivate() {
        // Runs are detached on purpose: disabling the page must not end a
        // training job the user started.
        store.stopPolling()
        store.configure(client: nil)
        ChatTrainingToolRegistry.setClient(nil)
    }

    func makePage(id: String, context: NativExtensionPageContext) -> AnyView? {
        guard id == Self.runsPageID else {
            return nil
        }
        store.modelSearchPath = context.model.settings.modelSearchPath
        return AnyView(
            TrainingView(store: store, titleLeadingInset: context.titleLeadingInset)
        )
    }

    func performCommand(id: String) {
        guard id == Self.showRunsFolderCommandID, let url = store.runsDirectory else {
            return
        }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    /// The trainer's default runs folder, shared with the command line so
    /// runs started by an agent or a terminal appear on the page too.
    static var runsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".mlx-vlm", isDirectory: true)
            .appendingPathComponent("runs", isDirectory: true)
    }

    /// A stable command an agent can call without knowing where Nativ lives.
    static var launcherURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".mlx-vlm", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("nativ-train-runs")
    }

    static func makeClient(defaults: UserDefaults) throws -> TrainingRunClient {
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUNBUFFERED"] = "1"
        if let path = defaults.string(forKey: pythonPathDefaultsKey), !path.isEmpty {
            return TrainingRunClient(
                pythonURL: URL(fileURLWithPath: (path as NSString).expandingTildeInPath),
                environment: environment,
                runsDirectory: runsDirectory
            )
        }
        let distribution = try Nativ.distributionURL()
        environment["PYTHONHOME"] = distribution.appendingPathComponent("python").path
        environment["PYTHONNOUSERSITE"] = "1"
        return TrainingRunClient(
            pythonURL: distribution.appendingPathComponent("python/bin/python3"),
            environment: environment,
            runsDirectory: runsDirectory
        )
    }

    private static func writeLauncher(for client: TrainingRunClient) throws {
        let url = launcherURL
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(client.launcherScript().utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
    }

    private static func loadBundledManifest(bundle: Bundle) -> NativExtensionManifest? {
        guard let url = bundle.resourceURL?
            .appendingPathComponent("Training", isDirectory: true)
            .appendingPathComponent("Manifest.json"),
            let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? JSONDecoder().decode(NativExtensionManifest.self, from: data)
    }

    private static let fallbackManifest = NativExtensionManifest(
        id: extensionID,
        version: "1.0.0",
        minimumNativVersion: "0.4.6",
        displayName: "Training",
        summary: "Fine-tune models on your Mac with the MLX-VLM trainer: start, follow, and stop runs within usage caps you set.",
        developer: "Nativ",
        systemImage: "graduationcap",
        included: true,
        enabledByDefault: false,
        runtime: .builtIn,
        contributions: .init(
            sidebar: [
                .init(
                    id: runsPageID,
                    title: "Training",
                    systemImage: "graduationcap",
                    order: 240
                )
            ],
            commands: [
                .init(
                    id: showRunsFolderCommandID,
                    title: "Show Training Runs Folder",
                    systemImage: "folder"
                )
            ],
            settings: [
                .init(id: "com.nativ.training.limits", title: "Usage limits")
            ]
        ),
        permissions: [.modelsTraining, .namespacedStorage]
    )
}
