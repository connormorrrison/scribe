import AVFoundation

/// The microphone and the speaker for talking to the agent: listens until the person stops talking, handing the
/// sound over as it's heard, and plays the agent's spoken reply.
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
    private static let pause: TimeInterval = 1.0
    /// Gives up if nothing is said at all.
    private static let waitForSpeech: TimeInterval = 10
    private static let longest: TimeInterval = 120

    /// Listens until the person pauses after speaking, `finish()` is called, or the task is cancelled, handing
    /// over each tenth of a second of sound as it's heard (16 kHz mono 16-bit PCM, `SpeechAudio.format`). Returns
    /// whether there's anything to transcribe: false if nothing was said, or it was cancelled. `level` gets how loud
    /// each tenth of a second was (dBFS), for showing the person they're being heard.
    func listen(_ heard: @escaping (Data) -> Void, level: @escaping (Float) -> Void = { _ in }) async throws -> Bool {
        finishRequested = false
        try await Self.activateSession()

        let engine = AVAudioEngine()
        let (chunks, stop) = try SpeechAudio.start(engine)
        defer {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            stop.finish()
        }

        let started = Date()
        var noiseFloor: Float = 0
        var spoke = false
        var quietSince: Date?
        // Ends on its own if the task is cancelled.
        for await chunk in chunks {
            if finishRequested { break }
            heard(chunk.pcm)
            level(chunk.power)
            noiseFloor = min(noiseFloor, chunk.power)
            // Speech is well above the quietest the room has been.
            if chunk.power > max(noiseFloor + 15, -45) {
                spoke = true
                quietSince = nil
            } else if spoke {
                let since = quietSince ?? .now
                quietSince = since
                if Date.now.timeIntervalSince(since) > Self.pause { break }
            }
            let elapsed = Date.now.timeIntervalSince(started)
            if (!spoke && elapsed > Self.waitForSpeech) || elapsed > Self.longest { break }
        }

        // Tapped "done" before the meter caught any speech: still transcribe it, ElevenLabs may hear something.
        return !Task.isCancelled && (spoke || finishRequested)
    }

    /// Stops listening now (the person tapped to say they're done).
    func finish() { finishRequested = true }

    // MARK: Speaking

    /// Plays `audio` to the end, or until the task is cancelled.
    /// `started` runs the moment the audio starts, so anything shown alongside it can keep time with it.
    /// `level` gets how loud the audio is as it plays (dBFS, about 30 times a second).
    func play(_ audio: Data, started: () -> Void = {}, level: @escaping (Float) -> Void = { _ in }) async throws {
        try await Self.activateSession()

        let player = try AVAudioPlayer(data: audio)
        player.delegate = self
        self.player = player
        player.isMeteringEnabled = true
        player.prepareToPlay()
        let meter = Task { [weak self] in
            while !Task.isCancelled, let player = self?.player {
                player.updateMeters()
                level(player.averagePower(forChannel: 0))
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
        defer { meter.cancel() }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                playback = continuation
                if player.play() { started() } else { stopPlayback() }
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

    /// Lets other apps' audio carry on. Returns straight away; the session ends in the background.
    func deactivate() {
        Self.sessionQueue.async {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    // MARK: Audio session

    /// Starting and ending the audio session can block for a noticeable moment (ending it waits on other apps), so
    /// it happens off the main thread. One serial queue keeps the calls in order: an ending queued after one turn
    /// can't land after the next turn has started.
    private static let sessionQueue = DispatchQueue(label: "com.connormorrison.Scribe.audio-session",
                                                    qos: .userInitiated)

    private static func activateSession() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sessionQueue.async {
                do {
                    let session = AVAudioSession.sharedInstance()
                    try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
                    try session.setActive(true)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
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

/// Turns what the microphone hears into what ElevenLabs' realtime transcription takes. It lives outside `VoiceIO`
/// because the microphone's callback runs on the audio thread, not the main actor.
enum SpeechAudio {
    /// 16 kHz mono 16-bit PCM.
    static let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1,
                                      interleaved: true)!

    /// A tenth of a second of sound: the audio, and how loud it was (dBFS).
    struct Chunk: Sendable {
        let pcm: Data
        let power: Float
    }

    /// Starts the microphone. Chunks arrive in the stream until the engine is stopped and the continuation finished.
    static func start(_ engine: AVAudioEngine) throws -> (AsyncStream<Chunk>, AsyncStream<Chunk>.Continuation) {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, let converter = AVAudioConverter(from: inputFormat, to: format) else {
            throw VoiceError.microphoneUnavailable
        }
        let (stream, continuation) = AsyncStream.makeStream(of: Chunk.self)
        input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(inputFormat.sampleRate / 10),
                         format: inputFormat) { buffer, _ in
            continuation.yield(Chunk(pcm: convert(buffer, with: converter), power: power(of: buffer)))
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw VoiceError.microphoneUnavailable
        }
        return (stream, continuation)
    }

    private static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter) -> Data {
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return Data() }
        var fed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let samples = output.int16ChannelData else { return Data() }
        return Data(bytes: samples[0], count: Int(output.frameLength) * MemoryLayout<Int16>.size)
    }

    /// Loudness as dBFS, like a level meter.
    private static func power(of buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.floatChannelData, buffer.frameLength > 0 else { return -160 }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += samples[0][i] * samples[0][i] }
        let rms = (sum / Float(buffer.frameLength)).squareRoot()
        return 20 * log10(max(rms, 1e-8))
    }
}
