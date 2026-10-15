//
//  ChatAPIDTOsTests.swift
//  AstrologieTests
//
//  Pins the DTOs to the backend contract in
//  `supabase/functions/chat/handler.ts`.
//

import Foundation
import Testing

@testable import Astrologie

struct ChatRequestDTOTests {

    @Test func encodesExactlySessionIdAndMessage() throws {
        let request = ChatRequestDTO(sessionId: "session-1", message: "Hello, stars")

        let data = try JSONEncoder().encode(request)
        let json = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        #expect(Set(json.keys) == ["sessionId", "message"])
        #expect(json["sessionId"] as? String == "session-1")
        #expect(json["message"] as? String == "Hello, stars")
    }

    @Test func roundTripsThroughJSON() throws {
        let request = ChatRequestDTO(sessionId: "abc", message: "What's my chart?")

        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(ChatRequestDTO.self, from: data)

        #expect(decoded == request)
    }

    @Test func messageCeilingMatchesBackend() {
        #expect(ChatRequestDTO.maxMessageLength == 2000)
    }
}

struct ChatErrorResponseDTOTests {

    @Test func decodesWithoutDebugField() throws {
        let json = Data(#"{"error":"Payload too large."}"#.utf8)

        let decoded = try JSONDecoder().decode(ChatErrorResponseDTO.self, from: json)

        #expect(decoded.error == "Payload too large.")
        #expect(decoded.debug == nil)
    }

    @Test func decodesRetryAfterFromRateLimitDebug() throws {
        let json = Data(
            #"{"error":"Rate limit exceeded. Try again later.","debug":{"retryAfterMs":1500}}"#.utf8
        )

        let decoded = try JSONDecoder().decode(ChatErrorResponseDTO.self, from: json)

        #expect(decoded.debug?.retryAfterMs == 1500)
    }

    @Test func toleratesUnrecognizedDebugPayloads() throws {
        // Upstream failures attach a debug object with a different shape, and the
        // field is documented as arbitrary. `error` still has to come through.
        let json = Data(
            #"{"error":"Failed to get response from AI service.","debug":{"stage":"fetch","name":"TypeError"}}"#.utf8
        )

        let decoded = try JSONDecoder().decode(ChatErrorResponseDTO.self, from: json)

        #expect(decoded.error == "Failed to get response from AI service.")
        #expect(decoded.debug?.retryAfterMs == nil)
    }

    @Test func failsWhenErrorIsMissing() {
        let json = Data(#"{"debug":{"retryAfterMs":10}}"#.utf8)

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ChatErrorResponseDTO.self, from: json)
        }
    }
}

struct ChatStreamEventTests {

    @Test func classifiesDoneSentinel() {
        #expect(ChatStreamEvent(dataPayload: "[DONE]") == .done)
    }

    @Test func classifiesReplyChunk() {
        #expect(ChatStreamEvent(dataPayload: "Mercury is retrograde") == .chunk("Mercury is retrograde"))
    }

    @Test func treatsFilteredPlaceholderAsChunk() {
        #expect(ChatStreamEvent(dataPayload: "[Content filtered]") == .chunk("[Content filtered]"))
    }
}
