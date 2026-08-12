import Foundation

/// UserDefaults-backed persistence for provider and summary preferences.
///
/// Keys intentionally match the previous app's `local.model-compare.preferences.v1`
/// namespace so existing per-provider choices carry over to the rewrite.
final class SettingsStore {
    private let preferences = UserDefaults.standard
    private let preferencePrefix = "local.model-compare.preferences.v1"

    static let shared = SettingsStore()

    init() {
        migrateLegacyDomainsIfNeeded()
    }

    /// Earlier builds (and the previous app) ran as bundle-less binaries, so
    /// their preferences landed in executable-name domains instead of the
    /// bundle-id domain. Import those keys once; existing keys win.
    private func migrateLegacyDomainsIfNeeded() {
        let marker = "\(preferencePrefix).migrated-legacy-domains"
        guard !preferences.bool(forKey: marker) else { return }
        preferences.set(true, forKey: marker)
        for domain in ["ModelCompareStudio", "ModelCompare", "local.model-compare"] {
            guard let legacy = UserDefaults(suiteName: domain)?.persistentDomain(forName: domain) else { continue }
            for (key, value) in legacy where key.hasPrefix(preferencePrefix) {
                if preferences.object(forKey: key) == nil {
                    preferences.set(value, forKey: key)
                }
            }
        }
    }

    private func providerKey(_ provider: ProviderID, _ setting: String) -> String {
        "\(preferencePrefix).provider.\(provider.rawValue).\(setting)"
    }

    private func summaryKey(_ setting: String, provider: ProviderID? = nil) -> String {
        if let provider {
            return "\(preferencePrefix).summary.\(provider.rawValue).\(setting)"
        }
        return "\(preferencePrefix).summary.\(setting)"
    }

    // MARK: - Provider settings

    func loadSettings(for provider: ProviderID) -> ProviderSettings {
        let includeKey = providerKey(provider, "included")
        let included = preferences.object(forKey: includeKey) == nil
            ? !provider.isDirectAPI // CLI providers default on; billable API rows default off.
            : preferences.bool(forKey: includeKey)
        return ProviderSettings(
            included: included,
            model: savedChoice(for: providerKey(provider, "model")),
            effort: savedChoice(for: providerKey(provider, "effort"))
        )
    }

    func save(_ settings: ProviderSettings, for provider: ProviderID) {
        let model = settings.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let effort = settings.effort.trimmingCharacters(in: .whitespacesAndNewlines)
        preferences.set(model.isEmpty ? "Default" : model, forKey: providerKey(provider, "model"))
        preferences.set(effort.isEmpty ? "Default" : effort, forKey: providerKey(provider, "effort"))
        preferences.set(settings.included, forKey: providerKey(provider, "included"))
    }

    // MARK: - Summary settings

    /// Stored summary provider raw value, or "none".
    func loadSummaryProvider() -> String {
        preferences.string(forKey: summaryKey("provider")) ?? "none"
    }

    func saveSummaryProvider(_ rawValue: String) {
        preferences.set(rawValue, forKey: summaryKey("provider"))
    }

    func loadSummaryModel(for provider: ProviderID) -> String {
        savedChoice(for: summaryKey("model", provider: provider))
    }

    func loadSummaryEffort(for provider: ProviderID) -> String {
        savedChoice(for: summaryKey("effort", provider: provider))
    }

    func saveSummary(model: String, effort: String, for provider: ProviderID) {
        let cleanModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanEffort = effort.trimmingCharacters(in: .whitespacesAndNewlines)
        preferences.set(cleanModel.isEmpty ? "Default" : cleanModel, forKey: summaryKey("model", provider: provider))
        preferences.set(cleanEffort.isEmpty ? "Default" : cleanEffort, forKey: summaryKey("effort", provider: provider))
    }

    private func savedChoice(for key: String, fallback: String = "Default") -> String {
        guard let saved = preferences.string(forKey: key), !saved.isEmpty else { return fallback }
        return saved
    }

    // MARK: - Custom presets

    private func presetKey(_ slot: Int) -> String { "\(preferencePrefix).preset.\(slot)" }

    func loadPreset(slot: Int) -> ProviderPreset? {
        guard let data = preferences.data(forKey: presetKey(slot)) else { return nil }
        return try? JSONDecoder().decode(ProviderPreset.self, from: data)
    }

    func savePreset(_ preset: ProviderPreset, slot: Int) {
        guard let data = try? JSONEncoder().encode(preset) else { return }
        preferences.set(data, forKey: presetKey(slot))
    }

    func clearPreset(slot: Int) {
        preferences.removeObject(forKey: presetKey(slot))
    }
}
