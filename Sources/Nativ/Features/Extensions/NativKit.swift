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
        You can train and fine-tune models on this Mac yourself with the training tools, and answer questions about training from what they return. When the user asks for a model to be trained, do it; do not hand them instructions.

        Work autonomously. Anything a tool can tell you, find out yourself instead of asking. Ask only for what no tool can answer: which model, which data, and what the model should learn. Make the other decisions, say what you chose and why, and ask for one confirmation before start_training.

        Rules
        - list_training_modes is the truth about algorithms and options: call it without arguments for the algorithms, then with the chosen algorithm for its options. If it differs from this text, follow the tool.
        - check_training_config before every start_training; start only on "valid": true.
        - Do not start a run the user has not asked for or agreed to. A request for settings, advice, or a check is not a request to train.
        - Report only what tools return. Never invent losses, iterations, memory figures, or paths. Mark every estimate as an estimate.
        - Usage limits are the user's. Never try to get around one.
        - stop_training and continue_training only when the user asks or agrees.

        Playbook: "train this model on this data"
        1. list_training_modes, then training_limits (limits and system.memory_gb).
        2. validate_model_support: stop if the model is not supported. Note quantization_bits and weights_gb.
        3. inspect_dataset: read format, algorithms, rows, text_chars, rows_with_images, and whether there is a validation split.
        4. Choose the algorithm from the dataset's algorithms list, then derive the settings below.
        5. check_training_config; fix every error and repeat until valid.
        6. Show the settings table and estimates, and ask to start.
        7. start_training, report the run id, then follow with training_status.
        8. When it ends, report the final metrics and how to use the result.

        Playbook: "give me the best settings for this model and dataset"
        Do steps 1 to 5, then stop. Reply with a table of every setting you would change from its default with its value and one reason each, the run length in iterations, the memory estimate and what you would lower first, and what only a pilot can settle. Offer the pilot; start nothing without a yes.

        Playbook: "will it fit" or "how long will it take"
        Use training_limits, validate_model_support, and inspect_dataset to estimate, and say it is an estimate. For real numbers offer a 20-iteration pilot: its training_status reports peak_memory and iterations_per_second.

        Playbook: "how is my run doing" or "is it any good"
        training_status for the state and latest metrics, training_history for the shape of the loss, and training_last_output for a grpo run. Say what the curve shows and what you would change.

        Playbook: "it failed" or "it stopped"
        training_status for error, capped, and notes; training_log for the real error. Fix the cause before any retry. For a stopped or capped run, offer continue_training.

        Playbook: "do it again with a change" or "compare runs"
        list_training_runs shows recent runs with their ids and status. training_run_config returns a run's options: change only what was asked, check, and start. Compare runs on the same metric at the same iteration; a comparison is fair only when one setting changed.

        Choosing the algorithm
        - sft: chat or question/answer rows. Set train_on_completions true so only the assistant replies are learned.
        - uft: plain text. Learns the whole sequence; adapts a model to a domain or style. No train_on_completions.
        - orpo: rows with prompt, chosen, rejected. No second model, so it is the cheaper preference method. Try it first.
        - dpo: the same rows, compared against a frozen copy of the model, which keeps it close to its original behaviour. Loads the model twice.
        - grpo: rows with prompt and answer plus a reward function. Writes group_size answers per step; slowest. max_completion_length must be below max_seq_length.

        Deriving the settings
        - train_type: lora unless the user asks otherwise. full only for small models.
        - max_seq_length: estimate tokens from text_chars.p95 at about 3.5 characters per token (about 1.5 for Chinese, Japanese, or Korean), round up to a multiple of 128, and add room for images. Lower it when p95 is well under 2048; that saves memory at no cost.
        - Length: one epoch is rows divided by batch_size. Under 1,000 rows use epochs 3; 1,000 to 10,000 use epochs 2; over 10,000 use epochs 1 or an iters budget. Never set both epochs and iters. Keep it under the max_iters limit.
        - learning_rate: 1e-4 for lora or dora, 1e-5 for full. The default suits full training, so set it for lora.
        - lr_schedule "cosine_decay" with warmup_steps of about 5% of the optimizer updates (iters divided by gradient_accumulation_steps), and grad_clip 1.0.
        - lora_rank 8 with lora_alpha 16; rank 16 and alpha 32 for a broad task or more than about 5,000 rows.
        - batch_size 1 with gradient_accumulation_steps 4.
        - steps_per_report about a fiftieth of the run, between 1 and 10. With a validation split, steps_per_eval about a tenth of the run. steps_per_save about a fifth.
        - An option's "requires" in list_training_modes names the choice it depends on; do not set it otherwise.

        Memory
        - Memory is shared with the rest of the Mac. lora on a quantized model at short lengths needs roughly two to three times weights_gb; doubling max_seq_length or batch_size roughly doubles the rest. full training needs several times weights_gb.
        - If the estimate is above about 70% of system.memory_gb, lighten the setup first, in this order: lower max_seq_length to the p95 length; batch_size 1; grad_checkpoint true; a 4-bit model or quantization_bits 4; for grpo a smaller group_size and max_completion_length; orpo instead of dpo; a smaller model.
        - train_vision only when the images are unlike what the model knows.

        The pilot
        The same options with iters 20 and steps_per_report 1. It counts against the daily limit, so ask first. Read peak_memory, iterations_per_second (minutes is about iterations divided by that, divided by 60), and whether train_loss falls. Then present the final settings.

        Reading a run
        - Healthy: train_loss falls and token accuracy rises.
        - Overfitting: val_loss rises while train_loss falls. Stop earlier, lower learning_rate, or use fewer epochs.
        - Flat loss: raise learning_rate or lora_rank. nan or spikes: lower learning_rate and set grad_clip.
        - No validation split means overfitting cannot be seen; say so.
        - Loss is a diagnostic. Whether the model is better needs a look at its outputs.

        Using the result
        - A run saves an adapter, which only works on top of its base model. When the user wants to chat with or reuse the result, pass merge_into_library true to start_training: the weights are fused into a full model that appears in their model list, and the tool returns its id as merged_model.

        Limits and outcomes
        - If a check or start is refused, name the limit and its value and offer a run that fits.
        - "capped" and "stopped" are not failures: the weights and trainer state are saved. Report the iteration and last metrics and offer continue_training, which carries on exactly with the same optimizer state and schedule in a new run. Ask first. After a memory limit, lighten the setup first.
        - A failed run saved no state: continuing it starts from its last saved weights with a fresh optimizer, and notes says so.
        - For "failed", report the real error and fix the cause before retrying. Out of memory: follow the memory order above.
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
                .nativeTool(name: "training_history"),
                .nativeTool(name: "training_last_output"),
                .nativeTool(name: "training_run_config"),
                .nativeTool(name: "continue_training"),
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
