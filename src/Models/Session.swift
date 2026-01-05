/// Model enum for OpenAI Realtime API models
public enum Model: RawRepresentable, Equatable, Hashable, Codable, Sendable {
	/// The standard realtime model (replaces gpt-4o-realtime-preview)
	case gptRealtime
	/// The mini realtime model for faster, cheaper responses
	case gptRealtimeMini
	/// Legacy preview model (deprecated, use gptRealtime instead)
	case gpt4oRealtimePreview
	/// Custom model string
	case custom(String)

	public var rawValue: String {
		switch self {
			case .gptRealtime: return "gpt-realtime"
			case .gptRealtimeMini: return "gpt-realtime-mini"
			case .gpt4oRealtimePreview: return "gpt-4o-realtime-preview"
			case let .custom(value): return value
		}
	}

	public init?(rawValue: String) {
		switch rawValue {
			case "gpt-realtime": self = .gptRealtime
			case "gpt-realtime-mini": self = .gptRealtimeMini
			case "gpt-4o-realtime-preview": self = .gpt4oRealtimePreview
			default: self = .custom(rawValue)
		}
	}
}

/// Transcription model enum
public extension Model {
	enum Transcription: String, CaseIterable, Equatable, Hashable, Codable, Sendable {
		case whisper = "whisper-1"
		case gpt4o = "gpt-4o-transcribe-latest"
		case gpt4oMini = "gpt-4o-mini-transcribe"
		case gpt4oDiarize = "gpt-4o-transcribe-diarize"
	}
}

public struct Session: Codable, Equatable, Sendable {
	public enum Modality: String, Codable, Sendable {
		case text
		case audio
	}

	public enum Voice: String, Codable, CaseIterable, Sendable {
		case alloy
		case echo
		case shimmer
		case ash
		case ballad
		case coral
		case sage
		case verse
		// New voices added in 2025
		case marin
		case cedar
	}

	public enum AudioFormat: String, Codable, Sendable {
		case pcm16
		case g711_ulaw
		case g711_alaw
	}

	public struct InputAudioTranscription: Codable, Equatable, Sendable {
		/// The model to use for transcription. Can be a Model.Transcription value or a custom string.
		public var model: String
		/// The language of the input audio. Supplying the input language in ISO-639-1 (e.g. `en`) format will improve accuracy and latency.
		public var language: String?
		/// An optional text to guide the model's style or continue a previous audio segment.
		/// For `whisper`, the prompt is a list of keywords.
		/// For `gpt4o` models, the prompt is a free text string, for example "expect words related to technology".
		public var prompt: String?

		public init(model: String = "whisper-1", language: String? = nil, prompt: String? = nil) {
			self.model = model
			self.language = language
			self.prompt = prompt
		}

		public init(model: Model.Transcription, language: String? = nil, prompt: String? = nil) {
			self.model = model.rawValue
			self.language = language
			self.prompt = prompt
		}
	}

	/// Configuration for input audio noise reduction.
	public enum NoiseReduction: String, CaseIterable, Equatable, Hashable, Codable, Sendable {
		/// For close-talking microphones such as headphones
		case nearField = "near_field"
		/// For far-field microphones such as laptop or conference room microphones
		case farField = "far_field"
	}

	public struct TurnDetection: Codable, Equatable, Sendable {
		public enum TurnDetectionType: String, Codable, Sendable {
			/// Server-side Voice Activity Detection
			case serverVad = "server_vad"
			/// Semantic VAD - uses a turn detection model to understand conversation semantics
			case semanticVad = "semantic_vad"
			/// No turn detection
			case none
		}

		/// The eagerness of the model to respond (only for semantic VAD).
		public enum Eagerness: String, CaseIterable, Equatable, Hashable, Codable, Sendable {
			case auto
			case low
			case medium
			case high
		}

		/// The type of turn detection.
		public var type: TurnDetectionType
		/// Activation threshold for VAD (0.0 to 1.0). Only for server VAD.
		public var threshold: Double?
		/// Amount of audio to include before speech starts (in milliseconds). Only for server VAD.
		public var prefixPaddingMs: Int?
		/// Duration of silence to detect speech stop (in milliseconds). Only for server VAD.
		public var silenceDurationMs: Int?
		/// Whether or not to automatically generate a response when VAD is enabled.
		public var createResponse: Bool
		/// The eagerness of the model to respond. Only for semantic VAD.
		/// `low` will wait longer for the user to continue speaking, `high` will respond more quickly.
		public var eagerness: Eagerness?
		/// Optional idle timeout after which turn detection will auto-timeout when no additional audio is received.
		public var idleTimeout: Int?
		/// Whether or not to automatically interrupt any ongoing response when a VAD start event occurs.
		public var interruptResponse: Bool?

		public init(
			type: TurnDetectionType = .serverVad,
			threshold: Double? = 0.5,
			prefixPaddingMs: Int? = 300,
			silenceDurationMs: Int? = 500,
			createResponse: Bool = true,
			eagerness: Eagerness? = nil,
			idleTimeout: Int? = nil,
			interruptResponse: Bool? = nil
		) {
			self.type = type
			self.threshold = threshold
			self.createResponse = createResponse
			self.prefixPaddingMs = prefixPaddingMs
			self.silenceDurationMs = silenceDurationMs
			self.eagerness = eagerness
			self.idleTimeout = idleTimeout
			self.interruptResponse = interruptResponse
		}

		/// Creates a new `TurnDetection` configuration for Server VAD.
		public static func serverVad(
			createResponse: Bool = true,
			threshold: Double? = 0.5,
			prefixPaddingMs: Int? = 300,
			silenceDurationMs: Int? = 500,
			idleTimeout: Int? = nil,
			interruptResponse: Bool? = nil
		) -> TurnDetection {
			.init(
				type: .serverVad,
				threshold: threshold,
				prefixPaddingMs: prefixPaddingMs,
				silenceDurationMs: silenceDurationMs,
				createResponse: createResponse,
				eagerness: nil,
				idleTimeout: idleTimeout,
				interruptResponse: interruptResponse
			)
		}

		/// Creates a new `TurnDetection` configuration for Semantic VAD.
		/// Semantic VAD uses a turn detection model to understand conversation semantics
		/// and dynamically sets a timeout based on the probability that the user has finished speaking.
		public static func semanticVad(
			createResponse: Bool = true,
			eagerness: Eagerness? = .auto,
			idleTimeout: Int? = nil,
			interruptResponse: Bool? = nil
		) -> TurnDetection {
			.init(
				type: .semanticVad,
				threshold: nil,
				prefixPaddingMs: nil,
				silenceDurationMs: nil,
				createResponse: createResponse,
				eagerness: eagerness,
				idleTimeout: idleTimeout,
				interruptResponse: interruptResponse
			)
		}
	}

	public struct Tool: Codable, Equatable, Sendable {
		public struct FunctionParameters: Codable, Equatable, Sendable {
			public var type: JSONType
			public var properties: [String: Property]?
			public var required: [String]?
			public var pattern: String?
			public var const: String?
			public var `enum`: [String]?
			public var multipleOf: Int?
			public var minimum: Int?
			public var maximum: Int?

			public init(
				type: JSONType,
				properties: [String: Property]? = nil,
				required: [String]? = nil,
				pattern: String? = nil,
				const: String? = nil,
				enum: [String]? = nil,
				multipleOf: Int? = nil,
				minimum: Int? = nil,
				maximum: Int? = nil
			) {
				self.type = type
				self.properties = properties
				self.required = required
				self.pattern = pattern
				self.const = const
				self.enum = `enum`
				self.multipleOf = multipleOf
				self.minimum = minimum
				self.maximum = maximum
			}

			public struct Property: Codable, Equatable, Sendable {
				public var type: JSONType
				public var description: String?
				public var format: String?
				public var items: Items?
				public var required: [String]?
				public var pattern: String?
				public var const: String?
				public var `enum`: [String]?
				public var multipleOf: Int?
				public var minimum: Double?
				public var maximum: Double?
				public var minItems: Int?
				public var maxItems: Int?
				public var uniqueItems: Bool?

				public init(
					type: JSONType,
					description: String? = nil,
					format: String? = nil,
					items: Self.Items? = nil,
					required: [String]? = nil,
					pattern: String? = nil,
					const: String? = nil,
					enum: [String]? = nil,
					multipleOf: Int? = nil,
					minimum: Double? = nil,
					maximum: Double? = nil,
					minItems: Int? = nil,
					maxItems: Int? = nil,
					uniqueItems: Bool? = nil
				) {
					self.type = type
					self.description = description
					self.format = format
					self.items = items
					self.required = required
					self.pattern = pattern
					self.const = const
					self.enum = `enum`
					self.multipleOf = multipleOf
					self.minimum = minimum
					self.maximum = maximum
					self.minItems = minItems
					self.maxItems = maxItems
					self.uniqueItems = uniqueItems
				}

				public struct Items: Codable, Equatable, Sendable {
					public var type: JSONType
					public var properties: [String: Property]?
					public var pattern: String?
					public var const: String?
					public var `enum`: [String]?
					public var multipleOf: Int?
					public var minimum: Double?
					public var maximum: Double?
					public var minItems: Int?
					public var maxItems: Int?
					public var uniqueItems: Bool?

					public init(
						type: JSONType,
						properties: [String: Property]? = nil,
						pattern: String? = nil,
						const: String? = nil,
						enum: [String]? = nil,
						multipleOf: Int? = nil,
						minimum: Double? = nil,
						maximum: Double? = nil,
						minItems: Int? = nil,
						maxItems: Int? = nil,
						uniqueItems: Bool? = nil
					) {
						self.type = type
						self.properties = properties
						self.pattern = pattern
						self.const = const
						self.enum = `enum`
						self.multipleOf = multipleOf
						self.minimum = minimum
						self.maximum = maximum
						self.minItems = minItems
						self.maxItems = maxItems
						self.uniqueItems = uniqueItems
					}
				}
			}

			public enum JSONType: String, Codable, Sendable {
				case integer
				case string
				case boolean
				case array
				case object
				case number
				case null
			}
		}

		/// The type of the tool.
		public var type: String = "function"
		/// The name of the function.
		public var name: String
		/// The description of the function.
		public var description: String
		/// Parameters of the function in JSON Schema.
		public var parameters: FunctionParameters

		public init(type: String = "function", name: String, description: String, parameters: FunctionParameters) {
			self.type = type
			self.name = name
			self.description = description
			self.parameters = parameters
		}
	}

	public enum ToolChoice: Equatable, Sendable {
		case auto
		case none
		case required
		case function(String)

		public init(function name: String) {
			self = .function(name)
		}
	}

	/// The unique ID of the session.
	public var id: String?
	/// The default model used for this session.
	public var model: String
	/// The set of modalities the model can respond with.
	public var modalities: [Modality]
	/// The default system instructions.
	public var instructions: String
	/// The voice the model uses to respond.
	public var voice: Voice
	/// The format of input audio.
	public var inputAudioFormat: AudioFormat
	/// The format of output audio.
	public var outputAudioFormat: AudioFormat
	/// Configuration for input audio transcription.
	public var inputAudioTranscription: InputAudioTranscription?
	/// Configuration for turn detection.
	public var turnDetection: TurnDetection?
	/// Configuration for input audio noise reduction.
	/// Noise reduction filters audio added to the input audio buffer before it is sent to VAD and the model.
	/// Filtering the audio can improve VAD and turn detection accuracy (reducing false positives)
	/// and model performance by improving perception of the input audio.
	public var noiseReduction: NoiseReduction?
	/// Tools (functions) available to the model.
	public var tools: [Tool]
	/// How the model chooses tools.
	public var toolChoice: ToolChoice
	/// Sampling temperature. For audio models, 0.8 is recommended.
	public var temperature: Double
	/// Maximum number of output tokens.
	public var maxOutputTokens: Int?

	public init(
		id: String? = nil,
		model: String,
		tools: [Tool] = [],
		instructions: String,
		voice: Voice = .alloy,
		temperature: Double = 1,
		maxOutputTokens: Int? = nil,
		toolChoice: ToolChoice = .auto,
		turnDetection: TurnDetection? = nil,
		inputAudioFormat: AudioFormat = .pcm16,
		outputAudioFormat: AudioFormat = .pcm16,
		modalities: [Modality] = [.text, .audio],
		inputAudioTranscription: InputAudioTranscription? = nil,
		noiseReduction: NoiseReduction? = nil
	) {
		self.id = id
		self.model = model
		self.tools = tools
		self.voice = voice
		self.toolChoice = toolChoice
		self.modalities = modalities
		self.temperature = temperature
		self.instructions = instructions
		self.turnDetection = turnDetection
		self.maxOutputTokens = maxOutputTokens
		self.inputAudioFormat = inputAudioFormat
		self.outputAudioFormat = outputAudioFormat
		self.inputAudioTranscription = inputAudioTranscription
		self.noiseReduction = noiseReduction
	}

	/// Convenience initializer using Model enum instead of String
	public init(
		id: String? = nil,
		model: Model,
		tools: [Tool] = [],
		instructions: String,
		voice: Voice = .alloy,
		temperature: Double = 1,
		maxOutputTokens: Int? = nil,
		toolChoice: ToolChoice = .auto,
		turnDetection: TurnDetection? = nil,
		inputAudioFormat: AudioFormat = .pcm16,
		outputAudioFormat: AudioFormat = .pcm16,
		modalities: [Modality] = [.text, .audio],
		inputAudioTranscription: InputAudioTranscription? = nil,
		noiseReduction: NoiseReduction? = nil
	) {
		self.init(
			id: id,
			model: model.rawValue,
			tools: tools,
			instructions: instructions,
			voice: voice,
			temperature: temperature,
			maxOutputTokens: maxOutputTokens,
			toolChoice: toolChoice,
			turnDetection: turnDetection,
			inputAudioFormat: inputAudioFormat,
			outputAudioFormat: outputAudioFormat,
			modalities: modalities,
			inputAudioTranscription: inputAudioTranscription,
			noiseReduction: noiseReduction
		)
	}
}

extension Session.ToolChoice: Codable {
	private enum FunctionCall: Codable {
		case type
		case function

		enum CodingKeys: CodingKey {
			case type
			case function
		}
	}

	public init(from decoder: any Decoder) throws {
		let container = try decoder.singleValueContainer()

		if let stringValue = try? container.decode(String.self) {
			switch stringValue {
				case "none":
					self = .none
				case "auto":
					self = .auto
				case "required":
					self = .required
				default:
					throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid value for enum.")
			}
		} else {
			let container = try decoder.container(keyedBy: FunctionCall.CodingKeys.self)
			let functionContainer = try container.decode([String: String].self, forKey: .function)

			guard let name = functionContainer["name"] else {
				throw DecodingError.dataCorruptedError(forKey: .function, in: container, debugDescription: "Missing function name.")
			}

			self = .function(name)
		}
	}

	public func encode(to encoder: Encoder) throws {
		switch self {
			case .none:
				var container = encoder.singleValueContainer()
				try container.encode("none")
			case .auto:
				var container = encoder.singleValueContainer()
				try container.encode("auto")
			case .required:
				var container = encoder.singleValueContainer()
				try container.encode("required")
			case let .function(name):
				var container = encoder.container(keyedBy: FunctionCall.CodingKeys.self)
				try container.encode("function", forKey: .type)
				try container.encode(["name": name], forKey: .function)
		}
	}
}
