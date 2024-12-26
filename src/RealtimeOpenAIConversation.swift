import Accelerate
import Foundation
@preconcurrency import AVFoundation
import Combine
import Speech

public enum ConversationError: Error {
    case sessionNotFound
    case converterInitializationFailed
}

@available(iOS 17.0, *)
@Observable
public final class RealtimeOpenAIConversation: Sendable {
    private let client: RealtimeAPI
    @MainActor private var cancelTask: (() -> Void)?
    private let errorStream: AsyncStream<ServerError>.Continuation

    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let queuedSamples = UnsafeMutableArray<String>()
    private let apiConverter = UnsafeInteriorMutable<AVAudioConverter>()
    private let userConverter = UnsafeInteriorMutable<AVAudioConverter>()
    private let desiredFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24000, channels: 1, interleaved: false)!

    /// A stream of errors that occur during the conversation.
    public let errors: AsyncStream<ServerError>

    /// The unique ID of the conversation.
    @MainActor public private(set) var id: String?

    /// The current session for this conversation.
    @MainActor public private(set) var session: Session?

    /// A list of items in the conversation.
    @MainActor public private(set) var entries: [Item] = []

    /// Whether the conversation is currently connected to the server.
    @MainActor public private(set) var connected: Bool = false

    /// Whether the conversation is currently listening to the user's microphone.
    @MainActor public private(set) var isListening: Bool = false

    /// Whether this conversation is currently handling voice input and output.
    @MainActor public private(set) var handlingVoice: Bool = false

    /// Whether the user is currently speaking.
    /// This only works when using the server's voice detection.
    @MainActor public private(set) var isUserSpeaking: Bool = false

    /// Whether the model is currently speaking.
    @MainActor public private(set) var isPlaying: Bool = false

    /// A list of messages in the conversation.
    /// Note that this doesn't include function call events. To get a complete list, use `entries`.
    @MainActor public var messages: [Item.Message] {
        entries.compactMap { switch $0 {
        case let .message(message): return message
        default: return nil
        } }
    }

    /// Volume level of the user's speech (0.0 to 1.0)
    @MainActor public var userVolume: CGFloat = 0.0

    /// Volume level of the returned audio speech (0.0 to 1.0)
    @MainActor public var returnedAudioVolume: CGFloat = 0.0

    /// Volume levels across four frequency bands for the user's speech (0.0 to 1.0)
    @MainActor public var userFrequencyVolumes: [CGFloat] = [0.0, 0.0, 0.0, 0.0]

    private init(client: RealtimeAPI) {
        self.client = client
        (errors, errorStream) = AsyncStream.makeStream(of: ServerError.self)

        let task = Task.detached { [weak self] in
            guard let self else { return }

            for try await event in client.events {
                await self.handleEvent(event)
            }

            await MainActor.run {
                self.connected = false
            }
        }

        Task { @MainActor in
            self.cancelTask = task.cancel

            client.onDisconnect = { [weak self] in
                guard let self else { return }

                Task { @MainActor in
                    self.connected = false
                }
            }

            _keepIsPlayingPropertyUpdated()
        }
    }

    deinit {
        errorStream.finish()

        DispatchQueue.main.asyncAndWait {
            cancelTask?()
            stopHandlingVoice()
        }
    }

    /// Create a new conversation providing an API token and, optionally, a model.
    public convenience init(authToken token: String, model: String = "gpt-4o-realtime-preview") {
        self.init(client: RealtimeAPI.webSocket(authToken: token, model: model))
    }

    /// Create a new conversation that connects using a custom `URLRequest`.
    public convenience init(connectingTo request: URLRequest) {
        self.init(client: RealtimeAPI.webSocket(connectingTo: request))
    }

    /// Wait for the connection to be established
    @MainActor public func waitForConnection() async {
        while true {
            if connected {
                return
            }

            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    /// Execute a block of code when the connection is established
    @MainActor public func whenConnected<E>(_ callback: @Sendable () async throws(E) -> Void) async throws(E) {
        await waitForConnection()
        try await callback()
    }

    /// Make changes to the current session
    /// Note that this will fail if the session hasn't started yet. Use `whenConnected` to ensure the session is ready.
    public func updateSession(withChanges callback: (inout Session) -> Void) async throws {
        guard var session = await session else {
            throw ConversationError.sessionNotFound
        }

        callback(&session)

        try await setSession(session)
    }

    /// Set the configuration of the current session
    public func setSession(_ session: Session) async throws {
        // update endpoint errors if we include the session id
        var session = session
        session.id = nil

        try await client.send(event: .updateSession(session))
    }

    /// Send a client event to the server.
    /// > Warning: This function is intended for advanced use cases. Use the other functions to send messages and audio data.
    public func send(event: ClientEvent) async throws {
        try await client.send(event: event)
    }

    /// Manually append audio bytes to the conversation.
    /// Commit the audio to trigger a model response when server turn detection is disabled.
    /// > Note: The `Conversation` class can automatically handle listening to the user's mic and playing back model responses.
    /// > To get started, call the `startListening` function.
    public func send(audioDelta audio: Data, commit: Bool = false) async throws {
        try await send(event: .appendInputAudioBuffer(encoding: audio))
        if commit { try await send(event: .commitInputAudioBuffer()) }
    }

    /// Send a text message and wait for a response.
    /// Optionally, you can provide a response configuration to customize the model's behavior.
    /// > Note: Calling this function will automatically call `interruptSpeech` if the model is currently speaking.
    public func send(from role: Item.ItemRole, text: String, response: Response.Config? = nil) async throws {
        if await handlingVoice { await interruptSpeech() }

        try await send(event: .createConversationItem(Item(message: Item.Message(id: String(randomLength: 32), from: role, content: [.input_text(text)]))))
        try await send(event: .createResponse(response))
    }

    /// Send the response of a function call.
    public func send(result output: Item.FunctionCallOutput) async throws {
        try await send(event: .createConversationItem(Item(with: output)))
    }
}

// Listening/Speaking public API
@available(iOS 17.0, *)
public extension RealtimeOpenAIConversation {
    /// Start listening to the user's microphone and sending audio data to the model.
    /// This will automatically call `startHandlingVoice` if it hasn't been called yet.
    /// > Warning: Make sure to handle the case where the user denies microphone access.
    @MainActor func startListening() throws {
        guard !isListening else { return }
        if !handlingVoice { try startHandlingVoice() }

        Task.detached {
            self.audioEngine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: self.audioEngine.inputNode.outputFormat(forBus: 0)) { [weak self] buffer, _ in
                self?.processAudioBufferFromUser(buffer: buffer)
            }
        }

        isListening = true
    }

    /// Stop listening to the user's microphone.
    /// This won't stop playing back model responses. To fully stop handling voice conversations, call `stopHandlingVoice`.
    @MainActor func stopListening() {
        guard isListening else { return }

        audioEngine.inputNode.removeTap(onBus: 0)
        isListening = false
    }

    /// Handle the playback of audio responses from the model.
    @MainActor func startHandlingVoice() throws {
        guard !handlingVoice else { return }

        guard let converter = AVAudioConverter(from: audioEngine.inputNode.outputFormat(forBus: 0), to: desiredFormat) else {
            throw ConversationError.converterInitializationFailed
        }
        userConverter.set(converter)

        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
        try audioSession.setActive(true)

        audioEngine.attach(playerNode)
        audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: converter.inputFormat)
        try audioEngine.inputNode.setVoiceProcessingEnabled(true)

        audioEngine.prepare()
        do {
            try audioEngine.start()
            handlingVoice = true
        } catch {
            print("Failed to enable audio engine: \(error)")
            audioEngine.disconnectNodeInput(playerNode)
            audioEngine.disconnectNodeOutput(playerNode)

            throw error
        }
    }

    /// Interrupt the model's response if it's currently playing.
    /// This lets the model know that the user didn't hear the full response.
    @MainActor func interruptSpeech() {
        if isPlaying,
           let nodeTime = playerNode.lastRenderTime,
           let playerTime = playerNode.playerTime(forNodeTime: nodeTime),
           let itemID = queuedSamples.first
        {
            let audioTimeInMiliseconds = Int((Double(playerTime.sampleTime) / playerTime.sampleRate) * 1000)

            Task {
                do {
                    try await client.send(event: .truncateConversationItem(forItem: itemID, atAudioMs: audioTimeInMiliseconds))
                } catch {
                    print("Failed to send automatic truncation event: \(error)")
                }
            }
        }

        playerNode.stop()
        queuedSamples.clear()
    }

    /// Stop playing audio responses from the model and listening to the user's microphone.
    @MainActor func stopHandlingVoice() {
        guard handlingVoice else { return }

        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        audioEngine.disconnectNodeInput(playerNode)
        audioEngine.disconnectNodeOutput(playerNode)

        try? AVAudioSession.sharedInstance().setActive(false)

        isListening = false
        handlingVoice = false
    }
}

// Event handling private API
@available(iOS 17.0, *)
private extension RealtimeOpenAIConversation {
    @MainActor func handleEvent(_ event: ServerEvent) {
        switch event {
        case let .error(event):
            errorStream.yield(event.error)
        case let .sessionCreated(event):
            connected = true
            session = event.session
        case let .sessionUpdated(event):
            session = event.session
        case let .conversationCreated(event):
            id = event.conversation.id
        case let .conversationItemCreated(event):
            entries.append(event.item)
        case let .conversationItemDeleted(event):
            entries.removeAll { $0.id == event.itemId }
        case let .conversationItemInputAudioTranscriptionCompleted(event):
            updateEvent(id: event.itemId) { message in
                guard case let .input_audio(audio) = message.content[event.contentIndex] else { return }

                message.content[event.contentIndex] = .input_audio(.init(audio: audio.audio, transcript: event.transcript))
            }
        case let .conversationItemInputAudioTranscriptionFailed(event):
            errorStream.yield(event.error)
        case let .responseContentPartAdded(event):
            updateEvent(id: event.itemId) { message in
                message.content.insert(.init(from: event.part), at: event.contentIndex)
            }
        case let .responseContentPartDone(event):
            updateEvent(id: event.itemId) { message in
                message.content[event.contentIndex] = .init(from: event.part)
            }
        case let .responseTextDelta(event):
            updateEvent(id: event.itemId) { message in
                guard case let .text(text) = message.content[event.contentIndex] else { return }

                message.content[event.contentIndex] = .text(text + event.delta)
            }
        case let .responseTextDone(event):
            updateEvent(id: event.itemId) { message in
                message.content[event.contentIndex] = .text(event.text)
            }
        case let .responseAudioTranscriptDelta(event):
            updateEvent(id: event.itemId) { message in
                guard case let .audio(audio) = message.content[event.contentIndex] else { return }

                message.content[event.contentIndex] = .audio(.init(audio: audio.audio, transcript: (audio.transcript ?? "") + event.delta))
            }
        case let .responseAudioTranscriptDone(event):
            updateEvent(id: event.itemId) { message in
                guard case let .audio(audio) = message.content[event.contentIndex] else { return }

                message.content[event.contentIndex] = .audio(.init(audio: audio.audio, transcript: event.transcript))
            }
        case let .responseAudioDelta(event):
            updateEvent(id: event.itemId) { message in
                guard case let .audio(audio) = message.content[event.contentIndex] else { return }

                if handlingVoice { queueAudioSample(event) }
                message.content[event.contentIndex] = .audio(.init(audio: audio.audio + event.delta, transcript: audio.transcript))
            }
        case let .responseFunctionCallArgumentsDelta(event):
            updateEvent(id: event.itemId) { functionCall in
                functionCall.arguments.append(event.delta)
            }
        case let .responseFunctionCallArgumentsDone(event):
            updateEvent(id: event.itemId) { functionCall in
                functionCall.arguments = event.arguments
            }
        case .inputAudioBufferSpeechStarted:
            isUserSpeaking = true
            if handlingVoice { interruptSpeech() }
        case .inputAudioBufferSpeechStopped:
            isUserSpeaking = false
        default:
            return
        }
    }

    @MainActor
    func updateEvent(id: String, modifying closure: (inout Item.Message) -> Void) {
        guard let index = entries.firstIndex(where: { $0.id == id }), case var .message(message) = entries[index] else {
            return
        }

        closure(&message)

        entries[index] = .message(message)
    }

    @MainActor
    func updateEvent(id: String, modifying closure: (inout Item.FunctionCall) -> Void) {
        guard let index = entries.firstIndex(where: { $0.id == id }), case var .functionCall(functionCall) = entries[index] else {
            return
        }

        closure(&functionCall)

        entries[index] = .functionCall(functionCall)
    }
}

// Audio processing private API
@available(iOS 17.0, *)
private extension RealtimeOpenAIConversation {
    private func queueAudioSample(_ event: ServerEvent.ResponseAudioDeltaEvent) {
        guard let buffer = AVAudioPCMBuffer.fromData(event.delta, format: desiredFormat) else {
            print("Failed to create audio buffer.")
            return
        }

        guard let converter = apiConverter.lazy({ AVAudioConverter(from: buffer.format, to: playerNode.outputFormat(forBus: 0)) }) else {
            print("Failed to create audio converter.")
            return
        }

        let outputFrameCapacity = AVAudioFrameCount(ceil(converter.outputFormat.sampleRate / buffer.format.sampleRate) * Double(buffer.frameLength))

        guard let sample = convertBuffer(buffer: buffer, using: converter, capacity: outputFrameCapacity) else {
            print("Failed to convert buffer.")
            return
        }

        // Calculate and update the returned audio volume
        let volume = calculateVolume(from: buffer)
        Task { @MainActor in
            self.returnedAudioVolume = volume
        }

        queuedSamples.push(event.itemId)

        playerNode.scheduleBuffer(sample, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let self else { return }

            self.queuedSamples.popFirst()
            if self.queuedSamples.isEmpty { playerNode.pause() }
        }

        playerNode.play()
    }

    private func processAudioBufferFromUser(buffer: AVAudioPCMBuffer) {
        let ratio = desiredFormat.sampleRate / buffer.format.sampleRate

        guard let converter = userConverter.get() else {
            print("User converter not initialized.")
            return
        }

        guard let convertedBuffer = convertBuffer(buffer: buffer, using: converter, capacity: AVAudioFrameCount(Double(buffer.frameLength) * ratio)) else {
            print("Buffer conversion failed.")
            return
        }

        guard let sampleBytes = convertedBuffer.audioBufferList.pointee.mBuffers.mData else { return }
        let audioData = Data(bytes: sampleBytes, count: Int(convertedBuffer.audioBufferList.pointee.mBuffers.mDataByteSize))

        // Calculate and update the user volume
        let volume = calculateVolume(from: convertedBuffer)
        Task { @MainActor in
            self.userVolume = volume
        }

        // Calculate and update the frequency-based user volumes
        if let frequencyVolumes = updateAudioLevels(from: convertedBuffer) {
            Task { @MainActor in
                self.userFrequencyVolumes = frequencyVolumes
            }
        }

        Task {
            try await send(audioDelta: audioData)
        }
    }

    private func convertBuffer(buffer: AVAudioPCMBuffer, using converter: AVAudioConverter, capacity: AVAudioFrameCount) -> AVAudioPCMBuffer? {
        if buffer.format == converter.outputFormat {
            return buffer
        }

        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else {
            print("Failed to create converted audio buffer.")
            return nil
        }

        var error: NSError?
        var allSamplesReceived = false

        let status = converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
            if allSamplesReceived {
                outStatus.pointee = .noDataNow
                return nil
            }

            allSamplesReceived = true
            outStatus.pointee = .haveData
            return buffer
        }

        if status == .error {
            if let error = error {
                print("Error during conversion: \(error.localizedDescription)")
            }
            return nil
        }

        return convertedBuffer
    }

    /// Calculates the RMS volume from an AVAudioPCMBuffer.
    private func calculateVolume(from buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData?[0] else { return 0.0 }
        let channelDataArray = Array(UnsafeBufferPointer(start: channelData, count: Int(buffer.frameLength)))

        // Calculate RMS
        let rms = sqrt(channelDataArray.map { $0 * $0 }.reduce(0, +) / Float(buffer.frameLength))

        // Normalize to 0.0 - 1.0
        return min(max(rms, 0.0), 1.0)
    }

    /// Calculates volume levels across four frequency bands from an AVAudioPCMBuffer.
    private func updateAudioLevels(from buffer: AVAudioPCMBuffer) -> [CGFloat]? {
        guard let channelData = buffer.floatChannelData else { return nil }
        
        var audioLevels: [CGFloat] = Array(repeating: 0.0, count: 4) // Four levels TODO: Make this dynamic

        let channelCount = Int(buffer.format.channelCount)
        let frameLength = Int(buffer.frameLength)
        let lowPassRange = 1000.0 // Low frequency up to 1000 Hz
        let midLowRange = 2000.0   // Mid-low frequency up to 2000 Hz
        let midHighRange = 3000.0  // Mid-high frequency up to 3000 Hz
        let highRange = 4000.0     // High frequency up to 4000 Hz

        var lowLevel: Float = 0.0
        var midLowLevel: Float = 0.0
        var midHighLevel: Float = 0.0
        var highLevel: Float = 0.0

        // Simple amplitude measurement
        for frame in 0..<frameLength {
            let sample = channelData[0][frame]

            // Categorize sample into frequency bands
            if frame < Int(lowPassRange) {
                lowLevel += abs(sample)
            } else if frame < Int(midLowRange) {
                midLowLevel += abs(sample)
            } else if frame < Int(midHighRange) {
                midHighLevel += abs(sample)
            } else if frame < Int(highRange) {
                highLevel += abs(sample)
            }
        }

        // Normalize and set levels
        let maxVolume = 80.0
        audioLevels[0] = max(min(CGFloat(lowLevel) / CGFloat(maxVolume), 1.0), 0.0)
        audioLevels[1] = max(min(CGFloat(midLowLevel) / CGFloat(maxVolume), 1.0), 0.0)
        audioLevels[2] = max(min(CGFloat(midHighLevel) / CGFloat(maxVolume), 1.0), 0.0)
        audioLevels[3] = max(min(CGFloat(highLevel) / CGFloat(maxVolume), 1.0), 0.0)
        
        return audioLevels
    }
}

// Other private methods
@available(iOS 17.0, *)
extension RealtimeOpenAIConversation {
    /// This hack is required because relying on `queuedSamples.isEmpty` directly crashes the app.
    /// This is because updating the `queuedSamples` array on a background thread will trigger a re-render of any views that depend on it on that thread.
    /// So, instead, we observe the property and update `isPlaying` on the main actor.
    private func _keepIsPlayingPropertyUpdated() {
        withObservationTracking { _ = queuedSamples.isEmpty } onChange: {
            Task { @MainActor in
                self.isPlaying = self.queuedSamples.isEmpty
            }

            self._keepIsPlayingPropertyUpdated()
        }
    }
}
