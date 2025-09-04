import SwiftUI
import UserNotifications
import AVFoundation
import AudioToolbox

// MARK: - App

@main
struct TimerAppApp: App {
    @StateObject private var notif = NotificationManager.shared
    var body: some Scene {
        WindowGroup {
            ContentView()
                .onAppear {
                    notif.configure()
                    notif.requestAuthorizationIfNeeded()
                }
        }
    }
}

// MARK: - Notifications

final class NotificationManager: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager(); private override init() { super.init() }
    func configure() { UNUserNotificationCenter.current().delegate = self }
    func requestAuthorizationIfNeeded() {
        let c = UNUserNotificationCenter.current()
        c.getNotificationSettings { s in
            guard s.authorizationStatus == .notDetermined else { return }
            c.requestAuthorization(options: [.alert, .sound, .badge]) {_,_ in}
        }
    }
    func scheduleTimerDone(after seconds: Int, customSoundName: String? = nil) {
        let content = UNMutableNotificationContent()
        content.title = "Timer"
        content.body  = "Time’s up!"
        if let name = customSoundName {
            content.sound = UNNotificationSound(named: UNNotificationSoundName(name))
        } else {
            content.sound = .default
        }
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(seconds), repeats: false)
        UNUserNotificationCenter.current().add(.init(identifier: "timer_done", content: content, trigger: trigger))
    }
    func cancelTimerNotification() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["timer_done"])
    }
    // ❗️Без звука в foreground, чтобы не было "двойного" воспроизведения
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent n: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list] // no .sound in foreground
    }
}

// MARK: - Sound Player + Vibration

final class SoundPlayer {
    static let shared = SoundPlayer()
    private var player: AVAudioPlayer?
    private var vibrationTimer: Timer?
    private init() {}

    /// Preview: stop any previous audio, then play bundled file if present; otherwise short system sound.
    /// (Preview does NOT vibrate.)
    func preview(tone: Ringtone) {
        stop() // 🔧 фикс: выключаем предыдущее превью, чтобы звуки не накладывались
        if let file = tone.bundledFileName, let url = Bundle.main.url(forResource: file, withExtension: nil) {
            playBundled(url: url, loop: false, withVibration: false)
        } else {
            AudioServicesPlaySystemSound(tone.previewSystemSoundID)
        }
    }

    /// Timer finished: play bundled file if present; otherwise fallback to a system sound.
    /// Vibrate while playing if `vibrate == true`.
    func playEndSound(customFileName: String?, vibrate: Bool) {
        if let name = customFileName, let url = Bundle.main.url(forResource: name, withExtension: nil) {
            playBundled(url: url, loop: true, withVibration: vibrate)
        } else {
            AudioServicesPlaySystemSound(1005)
            if vibrate { startVibrationLoop() }
        }
    }

    func stop() {
        player?.stop()
        player = nil
        stopVibrationLoop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func playBundled(url: URL, loop: Bool, withVibration: Bool) {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            player?.stop()
            player = try AVAudioPlayer(contentsOf: url)
            player?.numberOfLoops = loop ? -1 : 0
            player?.prepareToPlay()
            player?.play()

            if withVibration { startVibrationLoop() } else { stopVibrationLoop() }
        } catch {
            AudioServicesPlaySystemSound(1005)
            if withVibration { startVibrationLoop() }
        }
    }

    // MARK: Vibration helpers

    private func startVibrationLoop() {
        stopVibrationLoop()
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        vibrationTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
            AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        }
        if let vibrationTimer { RunLoop.main.add(vibrationTimer, forMode: .common) }
    }

    private func stopVibrationLoop() {
        vibrationTimer?.invalidate()
        vibrationTimer = nil
    }
}

// MARK: - Presets

struct Ringtone: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let previewSystemSoundID: UInt32
    let bundledFileName: String?
}

let presetRingtones: [Ringtone] = [
    Ringtone(title: "Если вы дед старый", previewSystemSoundID: 1005, bundledFileName: nil),
    Ringtone(title: "Классика",           previewSystemSoundID: 1007, bundledFileName: "ring_classic.caf"),
    Ringtone(title: "Божественно",        previewSystemSoundID: 1013, bundledFileName: "ring_alarm.caf"),
    Ringtone(title: "Только для олдов",   previewSystemSoundID: 1022, bundledFileName: "ring_chime.caf")
]

// MARK: - UI (Timer)

private enum TimerState { case idle, running, paused, finished }

struct ContentView: View {
    @State private var state: TimerState = .idle
    @State private var remaining: Int = 0
    @State private var hours: Int = 0
    @State private var minutes: Int = 1
    @State private var seconds: Int = 0

    @State private var isRinging: Bool = false

    @AppStorage("selectedRingtoneTitle") private var selectedRingtoneTitle: String = "Default"
    @AppStorage("vibrationEnabled") private var vibrationEnabled: Bool = true

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private var pickedTotal: Int { hours * 3600 + minutes * 60 + seconds }
    private var selectedRingtone: Ringtone {
        presetRingtones.first(where: { $0.title == selectedRingtoneTitle }) ?? presetRingtones[0]
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {

                if state == .idle || state == .finished {
                    durationPicker
                }

                Text(formatted((state == .idle || state == .finished) ? pickedTotal : remaining))
                    .font(.system(size: 48, weight: .semibold, design: .rounded))
                    .monospacedDigit()

                HStack(spacing: 16) {
                    Button {
                        stopRingtoneIfNeeded()
                        if state == .paused {
                            state = .running
                            rescheduleNotification(seconds: remaining)
                        } else {
                            guard pickedTotal > 0 else { return }
                            remaining = pickedTotal
                            state = .running
                            rescheduleNotification(seconds: remaining)
                        }
                    } label: {
                        Label(state == .paused ? "Resume" : "Start", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled((state == .running) || pickedTotal == 0)

                    Button {
                        if state == .running {
                            state = .paused
                            NotificationManager.shared.cancelTimerNotification()
                            stopRingtoneIfNeeded()
                        }
                    } label: {
                        Label("Pause", systemImage: "pause.fill")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(state != .running)

                    Button {
                        state = .idle
                        remaining = 0
                        NotificationManager.shared.cancelTimerNotification()
                        stopRingtoneIfNeeded()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .controlSize(.large)
                    .disabled(state == .idle)
                }

                if isRinging {
                    Button {
                        stopRingtoneIfNeeded()
                    } label: {
                        Label("Stop Ringtone", systemImage: "speaker.slash.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }

                if state == .finished {
                    Text("Time’s up!").foregroundStyle(.secondary)
                }

                Spacer()

                NavigationLink {
                    RingtonePickerView(selectedTitle: $selectedRingtoneTitle)
                } label: {
                    HStack {
                        Image(systemName: "bell.fill")
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Ringtone")
                            Text(selectedRingtone.title)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary)
                    }
                    .padding()
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .padding()
            .navigationTitle("Timer")
        }
        .onReceive(tick) { _ in
            guard state == .running else { return }
            if remaining > 0 {
                remaining -= 1
            } else {
                state = .finished
                NotificationManager.shared.cancelTimerNotification()
                SoundPlayer.shared.playEndSound(customFileName: selectedRingtone.bundledFileName,
                                                vibrate: vibrationEnabled)
                isRinging = true
            }
        }
    }

    // MARK: helpers

    private func stopRingtoneIfNeeded() {
        if isRinging {
            SoundPlayer.shared.stop()
            isRinging = false
        }
    }

    private func rescheduleNotification(seconds: Int) {
        NotificationManager.shared.cancelTimerNotification()
        NotificationManager.shared.scheduleTimerDone(after: seconds,
                                                     customSoundName: selectedRingtone.bundledFileName)
    }

    private var durationPicker: some View {
        HStack(spacing: 0) {
            unitPicker("h", 0..<24, selection: $hours)
            unitPicker("m", 0..<60, selection: $minutes)
            unitPicker("s", 0..<60, selection: $seconds)
        }
        .frame(height: 160)
    }
    private func unitPicker(_ title: String, _ range: Range<Int>, selection: Binding<Int>) -> some View {
        VStack {
            Picker(title, selection: selection) {
                ForEach(range, id: \.self) { n in Text(String(format: "%02d", n)).tag(n) }
            }
            .pickerStyle(.wheel)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
    private func formatted(_ total: Int) -> String {
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }
}

// MARK: - Ringtone Picker

struct RingtonePickerView: View {
    @Binding var selectedTitle: String
    @AppStorage("vibrationEnabled") private var vibrationEnabled: Bool = true

    private func bundleHasFile(_ name: String?) -> Bool {
        guard let name else { return false }
        return Bundle.main.url(forResource: name, withExtension: nil) != nil
    }

    var body: some View {
        List {
            Section(header: Text("Playback")) {
                Toggle("Vibration", isOn: $vibrationEnabled)
            }

            Section(
                header: Text("Ringtones"),
                footer: VStack(alignment: .leading, spacing: 6) {
                    Text("This thing was made purely for fun in a couple of hours.")
                    Text("I wanna go to Anna Asti's concert.")
                    Text("   ")
                    Text("Vibration available when the timer finishes in the foreground.")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.top, 8)
            ) {
                ForEach(presetRingtones) { tone in
                    HStack {
                        Button {
                            selectedTitle = tone.title
                            SoundPlayer.shared.preview(tone: tone)
                        } label: {
                            HStack {
                                Text(tone.title)
                                Spacer()
                                if selectedTitle == tone.title {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                        }
                    }
                    .contextMenu {
                        if let file = tone.bundledFileName, bundleHasFile(file) {
                            Button("▶︎ Play bundled file") {
                                SoundPlayer.shared.preview(tone: tone)
                            }
                        }
                        Button("■ Stop preview") {
                            SoundPlayer.shared.stop()
                        }
                    }
                }
            }
        }
        .navigationTitle("Ringtones")
        .toolbar {
            Button("Stop Preview") { SoundPlayer.shared.stop() }
        }
        // 🔧 фикс: при уходе со страницы всегда выключаем предпрослушку
        .onDisappear { SoundPlayer.shared.stop() }
    }
}
