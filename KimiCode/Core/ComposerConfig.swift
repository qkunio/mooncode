import Foundation

/// 输入框的权限 / 模型 / 思考强度；新会话继承上次仍可用的选择。
struct ComposerConfig: Codable, Equatable, Sendable {
    var permission: PermissionMode
    var modelID: String?
    var effort: String?

    var patch: AgentConfigPatch {
        AgentConfigPatch(model: modelID, thinking: effort, permissionMode: permission)
    }

    static func initial(
        models: [ModelInfo], defaultModelID: String?, remembered: ComposerConfig?
    ) -> ComposerConfig {
        if var remembered, let model = models.first(where: { $0.model == remembered.modelID }) {
            remembered.effort = model.resolvedEffort(remembered.effort)
            return remembered
        }
        let model = models.first { $0.model == defaultModelID } ?? models.first
        return ComposerConfig(
            permission: .auto,
            modelID: model?.model,
            effort: model?.resolvedEffort(nil)
        )
    }
}
