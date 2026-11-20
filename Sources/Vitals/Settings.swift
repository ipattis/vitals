import Foundation

/// User preferences, persisted in UserDefaults.
final class AppSettings: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published var interval: Double { didSet { defaults.set(interval, forKey: "interval") } }
    @Published var alwaysOnTop: Bool { didSet { defaults.set(alwaysOnTop, forKey: "alwaysOnTop") } }
    @Published var allSpaces: Bool { didSet { defaults.set(allSpaces, forKey: "allSpaces") } }
    @Published var showDockIcon: Bool { didSet { defaults.set(showDockIcon, forKey: "showDockIcon") } }
    @Published var tab: DashboardTab { didSet { if persist { defaults.set(tab.rawValue, forKey: "dashboardTab") } } }
    /// Agent shown in the Agents tab's detail pane (not persisted: agent ids change per run).
    @Published var selectedAgent: String?
    @Published var menuBar: Set<MenuBarItem> {
        didSet { defaults.set(menuBar.map(\.rawValue), forKey: "menuBarItems") }
    }

    private let persist: Bool

    /// `persist: false` keeps tab changes out of UserDefaults (used by `--snapshot`).
    init(persist: Bool = true) {
        self.persist = persist
        defaults.register(defaults: [
            "interval": 1.0,
            "alwaysOnTop": false,
            "allSpaces": false,
            "showDockIcon": true,
            "menuBarItems": [MenuBarItem.cpu, .memory, .network].map(\.rawValue),
        ])
        interval = defaults.double(forKey: "interval")
        alwaysOnTop = defaults.bool(forKey: "alwaysOnTop")
        allSpaces = defaults.bool(forKey: "allSpaces")
        showDockIcon = defaults.bool(forKey: "showDockIcon")
        tab = DashboardTab(rawValue: defaults.string(forKey: "dashboardTab") ?? "") ?? .machine
        let raw = defaults.stringArray(forKey: "menuBarItems") ?? []
        menuBar = Set(raw.compactMap(MenuBarItem.init(rawValue:)))
    }
}

enum MenuBarItem: String, CaseIterable, Identifiable {
    case agents, cpu, gpu, memory, network, disk, temperature, power
    var id: String { rawValue }
    var title: String {
        switch self {
        case .agents: "Working Agents"
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .memory: "Memory"
        case .network: "Network"
        case .disk: "Disk"
        case .temperature: "Temperature"
        case .power: "Power"
        }
    }
}

enum DashboardTab: String, CaseIterable, Identifiable {
    case machine, agents
    var id: String { rawValue }
    var title: String { self == .machine ? "Machine" : "Agents" }
}
