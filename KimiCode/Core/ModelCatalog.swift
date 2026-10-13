import Foundation

/// 电脑返回的完整模型目录；来源和各组内的模型都沿用服务端顺序。
struct ModelCatalog: Sendable {
    struct Group: Identifiable, Sendable {
        let id: String
        let name: String
        let models: [ModelInfo]
    }

    let models: [ModelInfo]

    var groups: [Group] {
        var order: [String] = []
        var grouped: [String: [ModelInfo]] = [:]
        for model in models {
            if grouped[model.provider] == nil { order.append(model.provider) }
            grouped[model.provider, default: []].append(model)
        }
        return order.map { provider in
            let items = grouped[provider] ?? []
            return Group(id: provider, name: items.first?.providerName ?? provider, models: items)
        }
    }

    func groups(matching query: String, providerID: String?) -> [Group] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return groups.compactMap { group in
            guard providerID == nil || group.id == providerID else { return nil }
            let matches = group.models.filter { model in
                term.isEmpty || [model.name, model.model, model.provider, model.providerName]
                    .contains { $0.localizedStandardContains(term) }
            }
            guard !matches.isEmpty else { return nil }
            return Group(id: group.id, name: group.name, models: matches)
        }
    }
}
