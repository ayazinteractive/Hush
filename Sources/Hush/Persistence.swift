import Foundation
import ServiceManagement

/// Volumes are remembered per bundle ID, so they survive quitting the app you
/// turned down — and quitting the mixer. UserDefaults is the right size of tool
/// here: no files, no schema.
enum Settings {
    /// The bundle ID was com.cryonayes.hush before 1.0; its defaults domain went with
    /// it, so the first read carries volumes and mutes over once. Launch at login is
    /// left out on purpose: it is registered per bundle ID and has to be asserted again.
    private static let defaults: UserDefaults = {
        let d = UserDefaults.standard
        if d.object(forKey: "volumes") == nil, d.object(forKey: "muted") == nil,
           let old = UserDefaults(suiteName: "com.cryonayes.hush") {
            for key in ["volumes", "muted"] { if let v = old.object(forKey: key) { d.set(v, forKey: key) } }
        }
        return d
    }()

    static var volumes: [String: Float] {
        get { (defaults.dictionary(forKey: "volumes") as? [String: Double] ?? [:]).mapValues(Float.init) }
        set { defaults.set(newValue.mapValues(Double.init), forKey: "volumes") }
    }

    static var muted: Set<String> {
        get { Set(defaults.stringArray(forKey: "muted") ?? []) }
        set { defaults.set(Array(newValue), forKey: "muted") }
    }

    /// On by default, but only asserted once — if you turn it off in the right-click
    /// menu it stays off instead of coming back on the next launch.
    static func enableLaunchAtLoginOnce() {
        guard !defaults.bool(forKey: "didAutoEnableLogin") else { return }
        defaults.set(true, forKey: "didAutoEnableLogin")
        launchAtLogin = true
    }

    /// Needs the app to live somewhere stable — a bundle on the Desktop still works,
    /// but moving it afterwards breaks the registration.
    static var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                newValue ? try SMAppService.mainApp.register()
                         : try SMAppService.mainApp.unregister()
            } catch {
                NSLog("launch at login \(newValue ? "register" : "unregister") failed: \(error)")
            }
        }
    }
}
