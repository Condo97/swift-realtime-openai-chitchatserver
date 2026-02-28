import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public final class WebSocketConnector: NSObject, Connector, Sendable {
	@MainActor public private(set) var onDisconnect: (@Sendable () -> Void)? = nil
	public let events: AsyncThrowingStream<ServerEvent, Error>

	private let task: URLSessionWebSocketTask
	private let stream: AsyncThrowingStream<ServerEvent, Error>.Continuation

	private let encoder: JSONEncoder = {
		let encoder = JSONEncoder()
		encoder.keyEncodingStrategy = .convertToSnakeCase
		return encoder
	}()

	private let decoder: JSONDecoder = {
		let decoder = JSONDecoder()
		decoder.keyDecodingStrategy = .convertFromSnakeCase
		return decoder
	}()

	public init(connectingTo request: URLRequest) {
		(events, stream) = AsyncThrowingStream.makeStream(of: ServerEvent.self)
		task = URLSession.shared.webSocketTask(with: request)

		super.init()

		task.delegate = self
		receiveMessage()
		task.resume()
		print("[RealtimeSDK] WebSocket task resumed, connecting to: \(request.url?.absoluteString ?? "nil")")
	}

	deinit {
		task.cancel(with: .goingAway, reason: nil)
		stream.finish()
		onDisconnect?()
	}

	public func send(event: ClientEvent) async throws {
		let message = try URLSessionWebSocketTask.Message.string(String(data: encoder.encode(event), encoding: .utf8)!)
		try await task.send(message)
	}

	@MainActor public func onDisconnect(_ action: (@Sendable () -> Void)?) {
		onDisconnect = action
	}

	private func receiveMessage() {
		task.receive { [weak self] result in
			guard let self else { return }

			switch result {
			case let .failure(error):
				print("[RealtimeSDK] WebSocket transport error: \(error)")
				self.stream.finish(throwing: error)
				return

			case let .success(message):
				switch message {
				case let .string(text):
					do {
						let event = try self.decoder.decode(ServerEvent.self, from: text.data(using: .utf8)!)
						self.stream.yield(event)
					} catch {
						print("[RealtimeSDK] Decode error: \(error)")
						print("[RealtimeSDK] Raw message (first 1000 chars): \(String(text.prefix(1000)))")
					}

				case let .data(data):
					print("[RealtimeSDK] Received unexpected binary message (\(data.count) bytes), skipping")

				@unknown default:
					print("[RealtimeSDK] Received unknown message type, skipping")
				}
			}

			self.receiveMessage()
		}
	}
}

extension WebSocketConnector: URLSessionWebSocketDelegate {
	public func urlSession(_: URLSession, webSocketTask _: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
		let reasonString = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "none"
		print("[RealtimeSDK] WebSocket closed — code: \(closeCode.rawValue), reason: \(reasonString)")
		stream.finish()

		Task { @MainActor in
			onDisconnect?()
		}
	}

	public func urlSession(_: URLSession, webSocketTask _: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
		print("[RealtimeSDK] WebSocket opened — protocol: \(`protocol` ?? "none")")
	}
}
