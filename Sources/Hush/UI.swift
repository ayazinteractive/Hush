import SwiftUI
import CoreAudio

@MainActor
final class MixerModel: ObservableObject {
    @Published var apps: [AudioApp] = []
    @Published private(set) var volumes: [String: Float] = Settings.volumes
    @Published private(set) var muted: Set<String> = Settings.muted
    @Published var error: String?
    @Published var errorIsPermission = false

    private var taps: [String: AppTap] = [:]

    /// Apps whose tap couldn't be created, with when and why. Keeps a failing tap from
    /// being retried on every pixel of a slider drag, and ties the error to an app
    /// that still exists.
    private var failures: [String: (at: Date, error: TapError?, message: String)] = [:]
    private static let retryAfter: TimeInterval = 10

    /// Refreshed by the device listener rather than re-read per slider tick — this
    /// is a CoreAudio round trip and `syncTaps()` runs on every pixel of a drag.
    private var outputUID: String? = defaultOutputDeviceUID

    private var pollTimer: Timer?
    private var playingProcesses: Set<AudioObjectID> = []
    private var persistTask: Task<Void, Never>?

    init() {
        refresh()
        watchOutputDevice()
        watchProcessList()

        // CoreAudio accepts listeners on kAudioProcessPropertyIsRunningOutput and
        // then never fires them — verified: 33 registrations, all status 0, zero
        // callbacks while a process played for 11s. So "started/stopped playing" is
        // the one thing left to poll. This only reads flags and calls refresh() when
        // the set actually changes, rather than rebuilding the list every tick.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollPlaybackState() }
        }
    }

    private func pollPlaybackState() {
        let ids: [AudioObjectID] = caArray(AudioObjectID(kAudioObjectSystemObject),
                                           kAudioHardwarePropertyProcessObjectList)
        let playing = Set(ids.filter { (caValue($0, kAudioProcessPropertyIsRunningOutput) ?? UInt32(0)) != 0 })
        guard playing != playingProcesses else { return }
        playingProcesses = playing
        refresh()
    }

    func volume(_ id: String) -> Float { volumes[id] ?? 1.0 }
    func isMuted(_ id: String) -> Bool { muted.contains(id) }

    func setVolume(_ value: Float, for app: AudioApp) {
        // A continuous slider almost never lands on exactly 1.0, which is the only
        // value that drops the tap; treat "close to 100%" as 100%.
        volumes[app.id] = abs(value - 1) < 0.02 ? 1 : value
        syncTaps()
        persistSoon()
    }

    func toggleMute(_ app: AudioApp) {
        muted.formSymmetricDifference([app.id])
        Settings.muted = muted      // discrete action, no need to coalesce
        syncTaps()
    }

    /// A drag emits a value per pixel; without this every one of them re-encodes
    /// the whole volumes dictionary into UserDefaults.
    private func persistSoon() {
        persistTask?.cancel()
        persistTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            Settings.volumes = volumes
        }
    }

    func refresh() {
        apps = AudioApp.all()
        syncTaps()
    }

    /// Single reconciler: brings every tap in line with the current volumes, process
    /// groups and output device. Covers first launch (saved volume, no tap yet), a
    /// helper appearing under an app you already turned down, and an output device
    /// switch — all of which are the same problem, "this tap no longer matches".
    private func syncTaps() {
        let currentUID = outputUID
        let alive = Set(apps.map(\.id))
        for id in Array(taps.keys) where !alive.contains(id) {
            taps[id]?.stop()
            taps[id] = nil
        }
        failures = failures.filter { alive.contains($0.key) }

        for app in apps {
            let gain = isMuted(app.id) ? 0 : volume(app.id)

            // At 100% and unmuted, drop the tap so the app keeps its native,
            // zero-latency path. Otherwise keep it even while the app is silent:
            // tapping only once playback is noticed (a 2 s poll) lets a muted app's
            // short sounds, like notification chimes, through at full volume.
            guard gain != 1.0 else {
                taps[app.id]?.stop()
                taps[app.id] = nil
                failures[app.id] = nil
                continue
            }

            if let tap = taps[app.id] {
                if tap.processIDs == app.processIDs && tap.outputUID == currentUID {
                    tap.gain = gain
                    continue
                }
                tap.stop()          // stale: new helper, or the user switched output
                taps[app.id] = nil
            }

            if let failed = failures[app.id], Date().timeIntervalSince(failed.at) < Self.retryAfter { continue }
            do {
                let tap = try AppTap(app: app)
                tap.gain = gain
                taps[app.id] = tap
                failures[app.id] = nil
            } catch {
                failures[app.id] = (Date(), error as? TapError, error.localizedDescription)
            }
        }

        let shown = failures.values.max { $0.at < $1.at }
        error = shown?.message
        errorIsPermission = shown?.error?.isPermissionProblem ?? false
    }

    /// Rebuild taps when the user plugs in headphones — the aggregate device pins
    /// its output at creation, so an untouched tap would just go silent.
    private func watchOutputDevice() {
        listen(to: AudioObjectID(kAudioObjectSystemObject),
               kAudioHardwarePropertyDefaultOutputDevice) { model in
            model.outputUID = defaultOutputDeviceUID
            model.syncTaps()
        }
    }

    /// Processes appearing and disappearing — a new app launching, an old one quitting.
    private func watchProcessList() {
        listen(to: AudioObjectID(kAudioObjectSystemObject),
               kAudioHardwarePropertyProcessObjectList) { $0.refresh() }
    }

    private func listen(to object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                        _ handler: @escaping @MainActor (MixerModel) -> Void) {
        var addr = AudioObjectPropertyAddress(mSelector: selector,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in
                guard let self else { return }
                handler(self)
            }
        }
        logFailure(AudioObjectAddPropertyListenerBlock(object, &addr, DispatchQueue.main, block),
                   "AudioObjectAddPropertyListenerBlock")
    }
}

/// `icon(forFile:)` hits Icon Services. Called from a view body it runs per row on
/// every re-render, which during a slider drag is every frame.
@MainActor
enum IconCache {
    private static var cache: [String: NSImage] = [:]

    static func icon(_ path: String?) -> NSImage? {
        guard let path else { return nil }
        if let cached = cache[path] { return cached }
        let icon = NSWorkspace.shared.icon(forFile: path)
        cache[path] = icon
        return icon
    }
}

struct MixerView: View {
    @ObservedObject var model: MixerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.apps.isEmpty {
                Text("No apps with audio").foregroundStyle(.secondary)
            }
            ForEach(model.apps) { app in
                row(app).opacity(app.isPlaying ? 1 : 0.55)
            }
            if let error = model.error {
                VStack(alignment: .leading, spacing: 4) {
                    Text(error).font(.caption).foregroundStyle(.red)
                    if model.errorIsPermission {
                        Button("Open Privacy Settings") {
                            NSWorkspace.shared.open(URL(string:
                                "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                        }
                        .font(.caption)
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 300)
    }

    private func row(_ app: AudioApp) -> some View {
        let volume = model.volume(app.id)
        let isMuted = model.isMuted(app.id)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if let icon = IconCache.icon(app.bundlePath) {
                    Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                }
                Text(app.name).lineLimit(1)
                Spacer()
                Button {
                    model.toggleMute(app)
                } label: {
                    Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(isMuted ? Color.red : Color.secondary)

                Text("\(Int((volume * 100).rounded()))%")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)
            }
            // Past 1.0 is amplification — something macOS itself won't do for you.
            Slider(value: Binding(get: { volume }, set: { model.setVolume($0, for: app) }),
                   in: 0...2)
                .disabled(isMuted)
        }
    }
}
