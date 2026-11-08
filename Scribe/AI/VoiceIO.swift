import AVFoundation

/// The microphone and the speaker for talking to the agent: records until the person stops talking, and plays the
/// agent's spoken reply.
@MainActor
final class VoiceIO: NSObject, AVAudioPlayerDelegate {
    private var finishRequested = false
    private var player: AVAudioPlayer?
    private var playback: CheckedContinuation<Void, Never>?

    /// Asks for the microphone the first time; afterwards answers straight away.
    static func microphoneAllowed() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: true
        case .denied: false
        default: await AVAudioApplication.requestRecordPermission()
        }
    }

    // MARK: Listening

    /// How long a pause ends what the person is saying.
    private static let pause: TimeInterval = 1.4
    /// Gives up if nothing is said at all.
    private static let waitForSpeech: TimeInterval = 10
    private static let longest: TimeInterval = 120

    /// Records until the person pauses after speaking, `finish()` is called, or the task is cancelled. Returns the
    /// recording (an m4a the caller deletes), or nil if nothing was said or it was cancelled.
    func record() async throws -> URL? {
        finishRequested = false
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try session.setActive(true)

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("speech-\(UUID().uuidString).m4a")
        let recorder = try AVAudioRecorder(url: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ])
        recorder.isMeteringEnabled = true
        guard recorder.record() else { throw VoiceError.microphoneUnavailable }

        let started = Date()
        var noiseFloor: Float = 0
        var heard = false
        var quietSince: Date?
        while !Task.isCancelled, !finishRequested {
            try? await Task.sleep(for: .milliseconds(80))
            recorder.updateMeters()
            let power = recorder.averagePower(forChannel: 0)
            noiseFloor = min(noiseFloor, power)
            // Speech is well above the quietest the room has been.
            if power > max(noiseFloor + 15, -45) {
                heard = true
                quietSince = nil
            } else if heard {
                let since = quietSince ?? .now
                quietSince = since
                if Date.now.timeIntervalSince(since) > Self.pause { break }
            }
            let elapsed = Date.now.timeIntervalSince(started)
            if (!heard && elapsed > Self.waitForSpeech) || elapsed > Self.longest { break }
        }
        recorder.stop()

        // Tapped "done" before the meter caught any speech: still send it, ElevenLabs may hear something.
        if Task.isCancelled || !(heard || finishRequested) {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return url
    }

    /// Ends the current recording now (the person tapped to say they're done).
    func finish() { finishRequested = true }

    // MARK: Speaking

    /// Plays `audio` to the end, or until the task is cancelled.
    func play(_ audio: Data) async throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try session.setActive(true)

        let player = try AVAudioPlayer(data: audio)
        player.delegate = self
        self.player = player
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                playback = continuation
                if !player.play() { stopPlayback() }
            }
        } onCancel: {
            Task { @MainActor in self.stopPlayback() }
        }
        deactivate()
    }

    func stopPlayback() {
        player?.stop()
        player = nil
        playback?.resume()
        playback = nil
    }

    /// Lets other apps' audio carry on.
    func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.stopPlayback() }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in self.stopPlayback() }
    }
}

enum VoiceError: LocalizedError {
    case microphoneUnavailable

    var errorDescription: String? {
        "The microphone couldn't start. Make sure no other app is using it, then try again."
    }
}
