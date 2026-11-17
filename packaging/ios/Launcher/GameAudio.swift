import AVFoundation

/// Owns the game's RemoteIO audio session. Serialize changes off the UI thread so a slow
/// system audio transition cannot stall Play, Quit, or a notification callback.
final class GameAudio: @unchecked Sendable {
    struct ResumptionEvent: Sendable {
        let name: Notification.Name
        let shouldResume: @Sendable (Notification) -> Bool

        static var system: Self {
            #if compiler(>=6.4)
            if #available(iOS 27.0, *) {
                return Self(name: AVAudioSession.resumptionRecommendationNotification) { note in
                    let context = note.userInfo?[AVAudioSession.resumptionContextKey]
                        as? AVAudioSession.ResumptionContext
                    return context?.recommendation == .shouldResume
                }
            }
            #endif
            return .interruptionEnded
        }

        // On older systems a game can resume after the end of an interruption
        // without requiring an explicit play action.
        static let interruptionEnded = Self(name: AVAudioSession.interruptionNotification) { note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            return raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:)) == .ended
        }
    }

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
    private let resumption: ResumptionEvent
    private let setActive: @Sendable (Bool) throws -> Void
    // Both fields belong to queue. An observer captures the identity of its game session.
    private var observer: NSObjectProtocol?
    private var generation: UUID?

    init(queue: DispatchQueue = DispatchQueue(label: "dev.horizon.game-audio", qos: .userInitiated),
         notifications: NotificationCenter = .default,
         resumption: ResumptionEvent = .system,
         setActive: @escaping @Sendable (Bool) throws -> Void) {
        self.queue = queue
        self.notifications = notifications
        self.resumption = resumption
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
            let resumption = self.resumption
            self.observer = self.notifications.addObserver(
                forName: resumption.name, object: nil, queue: nil
            ) { [weak self] note in
                guard resumption.shouldResume(note) else { return }
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
