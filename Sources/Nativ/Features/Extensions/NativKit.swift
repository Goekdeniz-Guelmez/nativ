import Foundation

enum NativKitMCPReference: Equatable, Hashable, Sendable {
    case catalog(id: String)
    case configured(id: UUID)
}

/// A stable reference to a capability included in a Kit definition.
enum NativKitComponent: Equatable, Hashable, Identifiable, Sendable {
    case mcpServer(NativKitMCPReference)
    case nativeTool(name: String)
    case customTool(id: UUID)
    case skill(id: UUID)
    case extensionPackage(id: String)

    var id: String {
        switch self {
        case .mcpServer(.catalog(let id)):
            "mcp-catalog:\(id)"
        case .mcpServer(.configured(let id)):
            "mcp-configured:\(id.uuidString)"
        case .nativeTool(let name):
            "tool-native:\(name)"
        case .customTool(let id):
            "tool-custom:\(id.uuidString)"
        case .skill(let id):
            "skill:\(id.uuidString)"
        case .extensionPackage(let id):
            "extension:\(id)"
        }
    }
}

extension NativKitComponent: Codable {
    private enum Kind: String, Codable {
        case mcpCatalog
        case mcpConfigured
        case nativeTool
        case customTool
        case skill
        case extensionPackage
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case catalogID
        case configuredID
        case name
        case id
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .mcpCatalog:
            self = .mcpServer(.catalog(id: try container.decode(String.self, forKey: .catalogID)))
        case .mcpConfigured:
            self = .mcpServer(.configured(id: try container.decode(UUID.self, forKey: .configuredID)))
        case .nativeTool:
            self = .nativeTool(name: try container.decode(String.self, forKey: .name))
        case .customTool:
            self = .customTool(id: try container.decode(UUID.self, forKey: .id))
        case .skill:
            self = .skill(id: try container.decode(UUID.self, forKey: .id))
        case .extensionPackage:
            self = .extensionPackage(id: try container.decode(String.self, forKey: .id))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .mcpServer(.catalog(let id)):
            try container.encode(Kind.mcpCatalog, forKey: .type)
            try container.encode(id, forKey: .catalogID)
        case .mcpServer(.configured(let id)):
            try container.encode(Kind.mcpConfigured, forKey: .type)
            try container.encode(id, forKey: .configuredID)
        case .nativeTool(let name):
            try container.encode(Kind.nativeTool, forKey: .type)
            try container.encode(name, forKey: .name)
        case .customTool(let id):
            try container.encode(Kind.customTool, forKey: .type)
            try container.encode(id, forKey: .id)
        case .skill(let id):
            try container.encode(Kind.skill, forKey: .type)
            try container.encode(id, forKey: .id)
        case .extensionPackage(let id):
            try container.encode(Kind.extensionPackage, forKey: .type)
            try container.encode(id, forKey: .id)
        }
    }
}

/// An additive bundle of capabilities for a role or workflow.
struct NativKit: Codable, Equatable, Hashable, Identifiable, Sendable {
    let id: String
    var name: String
    var summary: String
    var symbol: String
    var tintName: String
    var components: [NativKitComponent]

    var mcpReferences: [NativKitMCPReference] {
        components.compactMap { component in
            guard case .mcpServer(let reference) = component else { return nil }
            return reference
        }
    }

    var mcpServerIDs: [String] {
        mcpReferences.compactMap { reference in
            guard case .catalog(let id) = reference else { return nil }
            return id
        }
    }

    var skillIDs: [UUID] {
        components.compactMap { component in
            guard case .skill(let id) = component else { return nil }
            return id
        }
    }

    var extensionIDs: [String] {
        components.compactMap { component in
            guard case .extensionPackage(let id) = component else { return nil }
            return id
        }
    }

    var toolCount: Int {
        components.count { component in
            switch component {
            case .nativeTool, .customTool: true
            default: false
            }
        }
    }

    var inventory: String {
        var parts: [String] = []
        if !mcpReferences.isEmpty {
            parts.append("\(mcpReferences.count) MCP server\(mcpReferences.count == 1 ? "" : "s")")
        }
        if toolCount > 0 {
            parts.append("\(toolCount) tool\(toolCount == 1 ? "" : "s")")
        }
        if !skillIDs.isEmpty {
            parts.append("\(skillIDs.count) skill\(skillIDs.count == 1 ? "" : "s")")
        }
        if !extensionIDs.isEmpty {
            parts.append("\(extensionIDs.count) extension\(extensionIDs.count == 1 ? "" : "s")")
        }
        return parts.joined(separator: " · ")
    }

    func mcpEntries(in catalog: MCPServerCatalog) -> [MCPCatalogEntry] {
        mcpServerIDs.compactMap(catalog.entry(id:))
    }
}

enum NativKitCatalogError: Error, Equatable {
    case duplicateKitIdentifier(String)
    case duplicateComponent(kitID: String, componentID: String)
    case conflictingSkillIdentifier(UUID)
    case unknownMCPServer(kitID: String, catalogID: String)
    case unknownSkill(kitID: String, skillID: UUID)
}

/// An immutable, validated collection of bundled and user Kit definitions.
struct NativKitCatalog: Sendable {
    static let bundled: NativKitCatalog = {
        do {
            return try NativKitCatalog(
                kits: NativKit.bundledDefinitions,
                mcpCatalog: .bundled,
                skillDefinitions: NativSkill.kitDefinitions
            )
        } catch {
            preconditionFailure("Invalid bundled Kit catalog: \(error)")
        }
    }()

    let kits: [NativKit]
    let skillDefinitions: [NativSkill]
    private let kitsByID: [String: NativKit]
    private let skillsByID: [UUID: NativSkill]
    private let bundledKitIDs: Set<String>

    init(
        kits: [NativKit],
        mcpCatalog: MCPServerCatalog,
        skillDefinitions: [NativSkill] = []
    ) throws {
        let skillsByID = try Self.indexSkills(skillDefinitions)
        let kitsByID = try Self.indexKits(
            kits,
            mcpCatalog: mcpCatalog,
            skillsByID: skillsByID,
            validatesReferences: true
        )
        self.kits = kits
        self.skillDefinitions = skillDefinitions
        self.kitsByID = kitsByID
        self.skillsByID = skillsByID
        bundledKitIDs = Set(kits.map(\.id))
    }

    private init(
        kits: [NativKit],
        skillDefinitions: [NativSkill],
        kitsByID: [String: NativKit],
        skillsByID: [UUID: NativSkill],
        bundledKitIDs: Set<String>
    ) {
        self.kits = kits
        self.skillDefinitions = skillDefinitions
        self.kitsByID = kitsByID
        self.skillsByID = skillsByID
        self.bundledKitIDs = bundledKitIDs
    }

    func merging(userKits: [NativKit]) throws -> NativKitCatalog {
        let merged = kits + userKits
        let indexed = try Self.indexKits(
            merged,
            mcpCatalog: .empty,
            skillsByID: skillsByID,
            validatesReferences: false
        )
        return NativKitCatalog(
            kits: merged,
            skillDefinitions: skillDefinitions,
            kitsByID: indexed,
            skillsByID: skillsByID,
            bundledKitIDs: bundledKitIDs
        )
    }

    func kit(id: String) -> NativKit? {
        kitsByID[id]
    }

    func skillDefinition(id: UUID) -> NativSkill? {
        skillsByID[id]
    }

    func isBundled(kitID: String) -> Bool {
        bundledKitIDs.contains(kitID)
    }

    private static func indexSkills(_ skills: [NativSkill]) throws -> [UUID: NativSkill] {
        var indexed: [UUID: NativSkill] = [:]
        for skill in skills {
            if let existing = indexed[skill.id], existing != skill {
                throw NativKitCatalogError.conflictingSkillIdentifier(skill.id)
            }
            indexed[skill.id] = skill
        }
        return indexed
    }

    private static func indexKits(
        _ kits: [NativKit],
        mcpCatalog: MCPServerCatalog,
        skillsByID: [UUID: NativSkill],
        validatesReferences: Bool
    ) throws -> [String: NativKit] {
        var indexed: [String: NativKit] = [:]
        for kit in kits {
            guard indexed.updateValue(kit, forKey: kit.id) == nil else {
                throw NativKitCatalogError.duplicateKitIdentifier(kit.id)
            }
            var componentIDs = Set<String>()
            for component in kit.components {
                guard componentIDs.insert(component.id).inserted else {
                    throw NativKitCatalogError.duplicateComponent(
                        kitID: kit.id,
                        componentID: component.id
                    )
                }
                guard validatesReferences else { continue }
                switch component {
                case .mcpServer(.catalog(let id)):
                    guard mcpCatalog.entry(id: id) != nil else {
                        throw NativKitCatalogError.unknownMCPServer(
                            kitID: kit.id,
                            catalogID: id
                        )
                    }
                case .skill(let id):
                    guard skillsByID[id] != nil else {
                        throw NativKitCatalogError.unknownSkill(kitID: kit.id, skillID: id)
                    }
                case .mcpServer(.configured), .nativeTool, .customTool, .extensionPackage:
                    break
                }
            }
        }
        return indexed
    }
}

private extension NativSkill {
    static func kit(_ identifier: String, _ name: String, _ instructions: String) -> NativSkill {
        guard let id = UUID(uuidString: identifier) else {
            preconditionFailure("Invalid built-in Kit skill identifier: \(identifier)")
        }
        return NativSkill(id: id, name: name, instructions: instructions, isEnabled: true)
    }

    static let engineeringKitSkill = kit(
        "A1000000-0000-4000-8000-000000000001",
        "Working in a codebase",
        """
        You're helping with software. Ground every answer in the actual repository, not assumptions.

        - Use the Git and filesystem tools to read real files, history, and diffs before proposing changes; cite concrete paths and symbols.
        - When you touch GitHub, prefer read-only queries and summarize findings precisely.
        - Match the project's existing style and conventions. Keep changes minimal and explain the reasoning.
        - Fetch documentation when an API or library detail is uncertain rather than guessing.
        """
    )

    static let researchKitSkill = kit(
        "A2000000-0000-4000-8000-000000000002",
        "Researching with sources",
        """
        You're doing careful research. Prioritize accuracy and traceability.

        - Use the fetch tool to read primary sources and link each claim to its source.
        - Record durable findings in the memory tool and recall them before re-fetching.
        - Query the SQLite tool for the user's dataset instead of estimating.
        - Separate what sources say from inference, and flag uncertainty plainly.
        """
    )

    static let trainingKitSkill = kit(
        "A3000000-0000-4000-8000-000000000003",
        "Training models",
        """
        You can train and fine-tune models on this Mac yourself with the training tools. When the user asks for a model to be trained, do it; do not hand them instructions.

        Flow
        - list_training_modes first: without arguments for the algorithms, then with the chosen algorithm for its options. The tool is the truth; if it differs from this text, follow the tool.
        - training_limits, validate_model_support, and inspect_dataset before building a run.
        - check_training_config before every start_training; start only on "valid": true and tell the user about errors and notes.
        - Follow with training_status. Report only what tools return; never invent losses, iterations, or paths.

        Choosing the algorithm from the data
        - sft: chat or question/answer rows. Teaches the model to produce the answers. Set train_on_completions true so only the assistant replies are learned.
        - uft: plain text. Learns the whole sequence; use it to adapt a model to a domain or style. Not for train_on_completions.
        - orpo: rows with prompt, chosen, rejected. Learns the chosen answer while pushing away the rejected one. No second model, so it is the cheaper preference method.
        - dpo: the same rows, but compared against a frozen copy of the model, which keeps it close to its original behaviour. Loads the model twice, so it needs about double the memory.
        - grpo: rows with prompt and answer plus a reward function. The model writes group_size answers per step and is rewarded for better ones. Slowest, because it generates text every step. max_completion_length must be smaller than max_seq_length.

        Settings that decide quality
        - train_type: lora trains small adapters and is the default; dora is a little heavier; full updates every weight and only fits small models.
        - lora_rank sets adapter capacity (8 is a good start, 16-32 for harder tasks); keep lora_alpha near twice the rank.
        - learning_rate: about 1e-4 for lora or dora, 1e-5 or lower for full. Too high makes the loss jump or turn into nan; too low and it barely moves.
        - Length: use epochs when the user speaks in passes, else iters; never both. 1-3 epochs suits small datasets; more tends to memorise.
        - lr_schedule "cosine_decay" with warmup_steps of 5-10% of the run gives a smoother finish. grad_clip 1.0 guards against spikes.
        - A valid split enables val_loss through steps_per_eval; use it to see overfitting.

        Settings that decide memory
        - max_seq_length is the main lever: set it just above the longest row. Shorter rows are unaffected; longer ones are cut, and a row that would lose its image tokens is rejected.
        - batch_size 1 with gradient_accumulation_steps 4-8 behaves like a larger batch without the memory.
        - grad_checkpoint true trades speed for memory. quantization_bits 4 shrinks the base model for lora or dora.
        - train_vision also trains the image encoder; use it only when the images are unlike what the model knows.

        Using the result
        - A run saves an adapter, which only works on top of its base model. When the user wants to chat with or reuse the result, pass merge_into_library true to start_training: the trained weights are fused into a full model that appears in their model list, and the tool returns its id as merged_model.

        A clean run
        - Set only what the user asked for or the task needs; leave the rest at defaults and say which settings you chose and why.
        - For an untested model and dataset, offer a short pilot of 20-50 iterations first to confirm the loss falls and memory fits.
        - Healthy: train_loss falls and token accuracy rises. val_loss rising while train_loss falls is overfitting: stop earlier or lower learning_rate. A flat loss needs a higher learning_rate or more capacity.

        Limits and outcomes
        - Usage limits are the user's. If a check or start is refused, name the limit and its value and offer a run that fits. Never try to get around a limit.
        - "capped" is not a failure: the weights are saved. Report the iteration and last metrics and offer to continue with resume_adapter_file set to the saved adapters.safetensors. Ask first.
        - For "failed", read training_status and training_log, report the real error, and fix the cause before retrying. Out of memory: lower max_seq_length, turn on grad_checkpoint, or quantize.
        - stop_training only when the user asks. Checkpoints are kept.
        """
    )

    static let kitDefinitions = [engineeringKitSkill, researchKitSkill, trainingKitSkill]
}

private extension NativKit {
    static let bundledDefinitions: [NativKit] = [
        NativKit(
            id: "engineering",
            name: "Engineering",
            summary: "Read code, work with Git and GitHub, and pull in docs while you build.",
            symbol: "chevron.left.forwardslash.chevron.right",
            tintName: "indigo",
            components: [
                .mcpServer(.catalog(id: "git")),
                .mcpServer(.catalog(id: "github")),
                .mcpServer(.catalog(id: "filesystem")),
                .mcpServer(.catalog(id: "fetch")),
                .skill(id: NativSkill.engineeringKitSkill.id),
            ]
        ),
        NativKit(
            id: "research",
            name: "Research",
            summary: "Gather sources from the web, keep notes, and query your own data.",
            symbol: "magnifyingglass",
            tintName: "purple",
            components: [
                .mcpServer(.catalog(id: "fetch")),
                .mcpServer(.catalog(id: "memory")),
                .mcpServer(.catalog(id: "sqlite")),
                .skill(id: NativSkill.researchKitSkill.id),
            ]
        ),
        NativKit(
            id: "training",
            name: "Training",
            summary: "Let the model fine-tune models on this Mac and follow the runs, within your usage limits.",
            symbol: "graduationcap",
            tintName: "teal",
            components: [
                .nativeTool(name: "list_training_modes"),
                .nativeTool(name: "training_limits"),
                .nativeTool(name: "validate_model_support"),
                .nativeTool(name: "inspect_dataset"),
                .nativeTool(name: "check_training_config"),
                .nativeTool(name: "start_training"),
                .nativeTool(name: "training_status"),
                .nativeTool(name: "training_log"),
                .nativeTool(name: "list_training_runs"),
                .nativeTool(name: "stop_training"),
                .skill(id: NativSkill.trainingKitSkill.id),
                .extensionPackage(id: "com.nativ.training"),
            ]
        ),
    ]
}

enum NativKitState: Equatable {
    case off
    case partial
    case enabled
}

struct NativKitActivationSnapshot: Equatable {
    let state: NativKitState
    let inactivePartNames: [String]
}

/// Additively enables Kit components and derives status from their live state.
@MainActor
enum NativKitActivation {
    static func enableMissing(
        in kit: NativKit,
        model: NativModel,
        kitCatalog: NativKitCatalog? = nil,
        mcpCatalog: MCPServerCatalog = .bundled,
        isExtensionEnabled: (String) -> Bool,
        enableExtension: (String) -> Void
    ) {
        var settings = model.settings
        let extensionIDs = enableMissing(
            in: kit,
            settings: &settings,
            kitCatalog: kitCatalog ?? model.kitLibrary.catalog,
            mcpCatalog: mcpCatalog
        )
        if settings != model.settings {
            model.settings = settings
        }
        for extensionID in extensionIDs where !isExtensionEnabled(extensionID) {
            enableExtension(extensionID)
        }
    }

    @discardableResult
    static func enableMissing(
        in kit: NativKit,
        settings: inout NativSettings,
        kitCatalog: NativKitCatalog = .bundled,
        mcpCatalog: MCPServerCatalog
    ) -> [String] {
        var extensionIDs: [String] = []
        for component in kit.components {
            switch component {
            case .mcpServer(.catalog(let id)):
                guard let entry = mcpCatalog.entry(id: id) else { continue }
                mcpCatalog.setEnabled(true, for: entry, in: &settings.mcpServers)
            case .mcpServer(.configured(let id)):
                if let index = settings.mcpServers.firstIndex(where: { $0.id == id }) {
                    settings.mcpServers[index].isEnabled = true
                }
            case .nativeTool(let name):
                settings.setToolEnabled(true, toolName: name)
            case .customTool(let id):
                guard let tool = settings.customTools.first(where: { $0.id == id }) else { continue }
                settings.setToolEnabled(true, toolName: tool.toolName)
            case .skill(let id):
                if let index = settings.skills.firstIndex(where: { $0.id == id }) {
                    settings.skills[index].isEnabled = true
                } else if let definition = kitCatalog.skillDefinition(id: id) {
                    settings.skills.append(definition)
                }
            case .extensionPackage(let id):
                extensionIDs.append(id)
            }
        }
        return extensionIDs
    }

    static func state(
        of kit: NativKit,
        model: NativModel,
        kitCatalog: NativKitCatalog? = nil,
        mcpCatalog: MCPServerCatalog = .bundled,
        isExtensionEnabled: (String) -> Bool
    ) -> NativKitState {
        snapshot(
            of: kit,
            model: model,
            kitCatalog: kitCatalog,
            mcpCatalog: mcpCatalog,
            extensionName: { $0 },
            isExtensionEnabled: isExtensionEnabled
        ).state
    }

    static func state(
        of kit: NativKit,
        settings: NativSettings,
        kitCatalog: NativKitCatalog = .bundled,
        isExtensionEnabled: (String) -> Bool,
        mcpCatalog: MCPServerCatalog
    ) -> NativKitState {
        snapshot(
            of: kit,
            settings: settings,
            kitCatalog: kitCatalog,
            extensionName: { $0 },
            isExtensionEnabled: isExtensionEnabled,
            mcpCatalog: mcpCatalog
        ).state
    }

    static func snapshot(
        of kit: NativKit,
        model: NativModel,
        kitCatalog: NativKitCatalog? = nil,
        mcpCatalog: MCPServerCatalog = .bundled,
        extensionName: (String) -> String,
        isExtensionEnabled: (String) -> Bool
    ) -> NativKitActivationSnapshot {
        snapshot(
            of: kit,
            settings: model.settings,
            kitCatalog: kitCatalog ?? model.kitLibrary.catalog,
            extensionName: extensionName,
            isExtensionEnabled: isExtensionEnabled,
            mcpCatalog: mcpCatalog
        )
    }

    static func snapshot(
        of kit: NativKit,
        settings: NativSettings,
        kitCatalog: NativKitCatalog = .bundled,
        extensionName: (String) -> String,
        isExtensionEnabled: (String) -> Bool,
        mcpCatalog: MCPServerCatalog
    ) -> NativKitActivationSnapshot {
        let inactive = kit.components.compactMap { component -> String? in
            switch component {
            case .mcpServer(.catalog(let id)):
                guard let entry = mcpCatalog.entry(id: id) else { return id }
                return mcpCatalog.isEnabled(entry, in: settings.mcpServers) ? nil : entry.name
            case .mcpServer(.configured(let id)):
                guard let server = settings.mcpServers.first(where: { $0.id == id }) else {
                    return "MCP server \(id.uuidString)"
                }
                return server.isEnabled ? nil : (server.name.isEmpty ? "MCP server" : server.name)
            case .nativeTool(let name):
                return settings.isToolEnabled(name) ? nil : humanized(name)
            case .customTool(let id):
                guard let tool = settings.customTools.first(where: { $0.id == id }) else {
                    return "Custom tool \(id.uuidString)"
                }
                return settings.isToolEnabled(tool.toolName) ? nil : tool.name
            case .skill(let id):
                let skill = settings.skills.first(where: { $0.id == id })
                let name = skill?.name ?? kitCatalog.skillDefinition(id: id)?.name ?? "Skill \(id.uuidString)"
                return skill?.isEnabled == true ? nil : name
            case .extensionPackage(let id):
                return isExtensionEnabled(id) ? nil : extensionName(id)
            }
        }
        let state: NativKitState
        if kit.components.isEmpty {
            state = .off
        } else if inactive.isEmpty {
            state = .enabled
        } else if inactive.count == kit.components.count {
            state = .off
        } else {
            state = .partial
        }
        return NativKitActivationSnapshot(state: state, inactivePartNames: inactive)
    }

    private static func humanized(_ name: String) -> String {
        name.split(separator: "_").map { String($0).capitalized }.joined(separator: " ")
    }
}
