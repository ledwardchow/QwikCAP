import Foundation

enum WebSocketFrameOpcode: UInt8 {
    case continuation = 0x0
    case text = 0x1
    case binary = 0x2
    case close = 0x8
    case ping = 0x9
    case pong = 0xA

    var isControl: Bool {
        rawValue >= 0x8
    }

    var displayName: String {
        switch self {
        case .continuation: return "Continuation"
        case .text: return "Text"
        case .binary: return "Binary"
        case .close: return "Close"
        case .ping: return "Ping"
        case .pong: return "Pong"
        }
    }
}

struct WebSocketFrame {
    let fin: Bool
    let opcode: WebSocketFrameOpcode
    let masked: Bool
    let maskKey: Data?
    let payload: Data

    var payloadString: String? {
        String(data: payload, encoding: .utf8)
    }

    var payloadLength: Int {
        payload.count
    }
}

class WebSocketParser {

    // MARK: - Frame Parsing

    static func parseFrame(_ data: Data) -> (frame: WebSocketFrame, bytesConsumed: Int)? {
        guard data.count >= 2 else { return nil }

        var offset = 0

        // First byte: FIN + RSV + Opcode
        let firstByte = data[offset]
        let fin = (firstByte & 0x80) != 0
        guard let opcode = WebSocketFrameOpcode(rawValue: firstByte & 0x0F) else { return nil }
        offset += 1

        // Second byte: Mask + Payload length
        let secondByte = data[offset]
        let masked = (secondByte & 0x80) != 0
        var payloadLength = UInt64(secondByte & 0x7F)
        offset += 1

        // Extended payload length
        if payloadLength == 126 {
            guard data.count >= offset + 2 else { return nil }
            payloadLength = UInt64(data[offset]) << 8 | UInt64(data[offset + 1])
            offset += 2
        } else if payloadLength == 127 {
            guard data.count >= offset + 8 else { return nil }
            payloadLength = 0
            for i in 0..<8 {
                payloadLength = payloadLength << 8 | UInt64(data[offset + i])
            }
            offset += 8
        }

        // Mask key
        var maskKey: Data? = nil
        if masked {
            guard data.count >= offset + 4 else { return nil }
            maskKey = data.subdata(in: offset..<(offset + 4))
            offset += 4
        }

        // Payload
        guard data.count >= offset + Int(payloadLength) else { return nil }
        var payload = data.subdata(in: offset..<(offset + Int(payloadLength)))

        // Unmask payload if needed
        if masked, let key = maskKey {
            payload = unmaskPayload(payload, maskKey: key)
        }

        let frame = WebSocketFrame(
            fin: fin,
            opcode: opcode,
            masked: masked,
            maskKey: maskKey,
            payload: payload
        )

        return (frame, offset + Int(payloadLength))
    }

    static func parseAllFrames(_ data: Data) -> [WebSocketFrame] {
        var frames: [WebSocketFrame] = []
        var remaining = data

        while !remaining.isEmpty {
            guard let (frame, consumed) = parseFrame(remaining) else { break }
            frames.append(frame)
            remaining = remaining.suffix(from: remaining.startIndex.advanced(by: consumed))
        }

        return frames
    }

    // MARK: - Frame Building

    static func buildFrame(
        opcode: WebSocketFrameOpcode,
        payload: Data,
        masked: Bool = false,
        fin: Bool = true
    ) -> Data {
        var frame = Data()

        // First byte: FIN + Opcode
        var firstByte: UInt8 = opcode.rawValue
        if fin {
            firstByte |= 0x80
        }
        frame.append(firstByte)

        // Second byte: Mask + Payload length
        var secondByte: UInt8 = masked ? 0x80 : 0x00
        let length = payload.count

        if length < 126 {
            secondByte |= UInt8(length)
            frame.append(secondByte)
        } else if length < 65536 {
            secondByte |= 126
            frame.append(secondByte)
            frame.append(UInt8((length >> 8) & 0xFF))
            frame.append(UInt8(length & 0xFF))
        } else {
            secondByte |= 127
            frame.append(secondByte)
            for i in (0..<8).reversed() {
                frame.append(UInt8((length >> (i * 8)) & 0xFF))
            }
        }

        // Mask key + masked payload
        if masked {
            var maskKey = Data(count: 4)
            _ = maskKey.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 4, $0.baseAddress!) }
            frame.append(maskKey)
            frame.append(maskPayload(payload, maskKey: maskKey))
        } else {
            frame.append(payload)
        }

        return frame
    }

    static func buildTextFrame(_ text: String, masked: Bool = false) -> Data {
        let payload = text.data(using: .utf8) ?? Data()
        return buildFrame(opcode: .text, payload: payload, masked: masked)
    }

    static func buildBinaryFrame(_ data: Data, masked: Bool = false) -> Data {
        return buildFrame(opcode: .binary, payload: data, masked: masked)
    }

    static func buildCloseFrame(statusCode: UInt16? = nil, reason: String? = nil, masked: Bool = false) -> Data {
        var payload = Data()

        if let code = statusCode {
            payload.append(UInt8((code >> 8) & 0xFF))
            payload.append(UInt8(code & 0xFF))

            if let reason = reason {
                payload.append(reason.data(using: .utf8) ?? Data())
            }
        }

        return buildFrame(opcode: .close, payload: payload, masked: masked)
    }

    static func buildPingFrame(payload: Data = Data(), masked: Bool = false) -> Data {
        return buildFrame(opcode: .ping, payload: payload, masked: masked)
    }

    static func buildPongFrame(payload: Data = Data(), masked: Bool = false) -> Data {
        return buildFrame(opcode: .pong, payload: payload, masked: masked)
    }

    // MARK: - Masking

    private static func maskPayload(_ payload: Data, maskKey: Data) -> Data {
        var masked = Data(count: payload.count)
        for i in 0..<payload.count {
            masked[i] = payload[i] ^ maskKey[i % 4]
        }
        return masked
    }

    private static func unmaskPayload(_ payload: Data, maskKey: Data) -> Data {
        return maskPayload(payload, maskKey: maskKey) // XOR is symmetric
    }

    // MARK: - WebSocket Handshake

    static func generateSecWebSocketKey() -> String {
        var keyBytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, keyBytes.count, &keyBytes)
        return Data(keyBytes).base64EncodedString()
    }

    static func generateSecWebSocketAccept(key: String) -> String {
        let magicString = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let combined = key + magicString

        guard let data = combined.data(using: .utf8) else { return "" }

        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        data.withUnsafeBytes { buffer in
            _ = CC_SHA1(buffer.baseAddress, CC_LONG(data.count), &digest)
        }

        return Data(digest).base64EncodedString()
    }

    static func isValidUpgradeResponse(_ response: ParsedHTTPResponse, expectedKey: String) -> Bool {
        guard response.statusCode == 101 else { return false }

        let upgrade = response.headers["Upgrade"] ?? response.headers["upgrade"] ?? ""
        let connection = response.headers["Connection"] ?? response.headers["connection"] ?? ""
        let accept = response.headers["Sec-WebSocket-Accept"] ?? response.headers["sec-websocket-accept"] ?? ""

        guard upgrade.lowercased() == "websocket" else { return false }
        guard connection.lowercased().contains("upgrade") else { return false }

        let expectedAccept = generateSecWebSocketAccept(key: expectedKey)
        return accept == expectedAccept
    }
}

// Import CommonCrypto for SHA1
import CommonCrypto

// MARK: - WebSocket Connection State

enum WebSocketState {
    case connecting
    case open
    case closing
    case closed
}

class WebSocketConnection {
    var state: WebSocketState = .connecting
    var fragmentBuffer: Data = Data()
    var fragmentOpcode: WebSocketFrameOpcode?

    func processFrame(_ frame: WebSocketFrame) -> (opcode: WebSocketFrameOpcode, payload: Data)? {
        if frame.opcode == .continuation {
            guard let opcode = fragmentOpcode else { return nil }
            fragmentBuffer.append(frame.payload)

            if frame.fin {
                let result = (opcode, fragmentBuffer)
                fragmentBuffer = Data()
                fragmentOpcode = nil
                return result
            }
            return nil
        }

        if frame.opcode.isControl {
            // Control frames can be interspersed, return immediately
            return (frame.opcode, frame.payload)
        }

        if frame.fin {
            return (frame.opcode, frame.payload)
        } else {
            // Start of fragmented message
            fragmentOpcode = frame.opcode
            fragmentBuffer = frame.payload
            return nil
        }
    }
}
