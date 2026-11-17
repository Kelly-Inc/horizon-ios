import AVFoundation

/// Owns the game's RemoteIO audio session. Serialize changes off the UI thread so a slow
/// system audio transition cannot stall Play, Quit, or a notification callback.
final class GameAudio: @unchecked Sendable {
    static let shared = GameAudio { active in
        let session = AVAudioSession.sharedInstance()
        if active {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
        } else {
            try session.setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private let queue: DispatchQueue
    private let notifications: NotificationCenter
    private let setActive: @Sendable (Bool) throws -> Void
    // Both fields belong to queue. An observer captures the identity of its game session.
    private var observer: NSObjectProtocol?
    private var generation: UUID?

    init(queue: DispatchQueue = DispatchQueue(label: "dev.horizon.game-audio", qos: .userInitiated),
         notifications: NotificationCenter = .default,
         setActive: @escaping @Sendable (Bool) throws -> Void) {
        self.queue = queue
        self.notifications = notifications
        self.setActive = setActive
    }

    deinit {
        if let observer { notifications.removeObserver(observer) }
    }

    func start() {
        queue.async {
            guard self.generation == nil else { return }
            let generation = UUID()
            self.generation = generation
            self.observer = self.notifications.addObserver(
                forName: AVAudioSession.interruptionNotification, object: nil, queue: nil
            ) { [weak self] note in
                let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                guard raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:)) == .ended else { return }
                self?.queue.async { [weak self] in
                    guard let self, self.generation == generation else { return }
                    self.applyActive(true)
                }
            }
            self.applyActive(true)
        }
    }

    func stop() {
        queue.async {
            self.generation = nil
            if let observer = self.observer { self.notifications.removeObserver(observer) }
            self.observer = nil
            // RemoteIO can open during game loading, before the launcher hands off.
            self.applyActive(false)
        }
    }

    private func applyActive(_ active: Bool) {
        do {
            try setActive(active)
        } catch {
            NSLog("Horizon: changing the game audio session to active=\(active) failed: \(error)")
        }
    }
}
