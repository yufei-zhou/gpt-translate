import Foundation

struct AIModel: Identifiable, Hashable {
    let id: String
    let name: String
}

enum Models {
    static let terra = AIModel(id: "gpt-6.1-terra", name: "GPT-6.1 Terra")
    static let sol = AIModel(id: "gpt-6.1-sol", name: "GPT-6.1 Sol")
    static let luna = AIModel(id: "gpt-6-luna", name: "GPT-6 Luna")
    static let translation = [sol, terra, luna]
    static let aligner = luna.id

    /// USD per million tokens (input, cached input, output). Unknown models are priced like the flagship GPT-6 Astra to err on the safe side.
    static func price(for model: String) -> (input: Double, cached: Double, output: Double) {
        let table: [(String, Double, Double, Double)] = [
            ("gpt-6.1-terra", 1, 0.05, 5), ("gpt-6.1-sol", 2, 0.10, 10),
            ("gpt-6-luna", 0.10, 0.01, 0.50),
        ]
        return table.first { model.hasPrefix($0.0) }.map { ($0.1, $0.2, $0.3) } ?? (10, 1, 50)
    }

    static func cost(model: String, usage: TokenUsage) -> Double {
        let p = price(for: model)
        let input = Double(usage.input + usage.cacheWrite) * p.input + Double(usage.cacheRead) * p.cached
        return (input + Double(usage.output) * p.output) / 1_000_000
    }

    /// Reasoning effort per model: none where the model allows it (the answer starts streaming at once),
    /// otherwise the lowest it accepts.
    static func effort(for model: String) -> String {
        model == terra.id || model == luna.id ? "none" : "low"
    }

    /// Request body tuned per model for short, low-latency answers. There are no betas; the slot stays so callers
    /// read the same as before.
    static func requestBody(model: String, system: String, user: String, maxTokens: Int) -> (body: [String: Any], betas: [String]) {
        requestBody(model: model, system: system, input: user, maxTokens: maxTokens)
    }

    /// `input` is the user's text, or a list of input items (an image and its instruction).
    static func requestBody(model: String, system: String, input: Any, maxTokens: Int) -> (body: [String: Any], betas: [String]) {
        let effort = effort(for: model)
        let body: [String: Any] = [
            "model": model,
            "instructions": system,
            "input": input,
            // Reasoning tokens count against the ceiling too, so leave them room.
            "max_output_tokens": max(16, maxTokens + (effort == "none" ? 0 : 4_000)),
            "reasoning": ["effort": effort],
            // Translations aren't kept on OpenAI's side.
            "store": false,
            // The instructions are identical on every request; a shared key keeps them in the same prompt cache.
            "prompt_cache_key": "gpt-translate",
        ]
        return (body, [])
    }
}

extension Models {
    /// A user message holding an image (as a base64 data URL) followed by `text`. Detail "auto" keeps the image's own
    /// resolution, which ImagePayload has already capped, so small print stays legible.
    static func imageInput(_ payload: (data: Data, mediaType: String), text: String) -> [[String: Any]] {
        [["role": "user", "content": [
            ["type": "input_image", "image_url": "data:\(payload.mediaType);base64,\(payload.data.base64EncodedString())",
             "detail": "auto"],
            ["type": "input_text", "text": text],
        ]]]
    }
}

struct TokenUsage {
    var input = 0
    var output = 0
    var cacheWrite = 0
    var cacheRead = 0
}

/// What a stream has received so far, readable even if the request is cancelled or fails part-way.
final class StreamProgress {
    var text = ""
    var model = ""
    var usage = TokenUsage()
}

struct StreamResult {
    var text = ""
    var model = ""
    var usage = TokenUsage()
    var stopReason: String?
}

enum APIError: LocalizedError {
    case http(Int, String)
    case api(String)

    var errorDescription: String? {
        switch self {
        case .http(let code, let message): return "HTTP \(code): \(message)"
        case .api(let message): return message
        }
    }
}

enum APIClient {
    static let endpoint = URL(string: "https://api.openai.com/v1/responses")!

    /// Streams a Responses request, calling `onUpdate` with the accumulated text after every delta.
    static func stream(key: String, body: [String: Any], betas: [String] = [], progress: StreamProgress? = nil,
                       onUpdate: @escaping @MainActor (String) -> Void) async throws -> StreamResult {
        let progress = progress ?? StreamProgress()
        var attempt = 0
        while true {
            do {
                return try await streamOnce(key: key, body: body, progress: progress, onUpdate: onUpdate)
            } catch APIError.http(let code, let message)
                        where attempt < 1 && (code == 429 || code >= 500) && !message.contains("quota") {
                // One quiet retry for rate limits and overload; a rate limit gets a longer pause.
                attempt += 1
                try await Task.sleep(nanoseconds: code == 429 ? 2_000_000_000 : 800_000_000)
            } catch APIError.api where attempt < 1 && progress.text.isEmpty {
                // A response can also fail after the request was accepted (a transient server error). Retry once
                // if nothing has been shown yet.
                attempt += 1
                try await Task.sleep(nanoseconds: 800_000_000)
            }
        }
    }

    private static func streamOnce(key: String, body: [String: Any], progress: StreamProgress,
                                   onUpdate: @escaping @MainActor (String) -> Void) async throws -> StreamResult {
        var body = body
        body["stream"] = true
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            var data = Data()
            for try await byte in bytes { data.append(byte) }
            throw APIError.http(status, errorMessage(from: data))
        }

        var result = StreamResult()
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:"),
                  let object = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(5).utf8)) as? [String: Any],
                  let type = object["type"] as? String else { continue }
            switch type {
            case "response.created":
                result.model = (object["response"] as? [String: Any])?["model"] as? String ?? ""
                progress.model = result.model
            case "response.output_text.delta":
                if let text = object["delta"] as? String {
                    result.text += text
                    progress.text = result.text
                    await onUpdate(result.text)
                }
            case "response.refusal.delta":
                result.stopReason = "refusal"
            case "response.completed", "response.incomplete":
                let response = object["response"] as? [String: Any]
                if let model = response?["model"] as? String, !model.isEmpty { result.model = model }
                if let usage = response?["usage"] as? [String: Any] { merge(usage, into: &result.usage) }
                progress.usage = result.usage
                // Same stop reasons as before, so the panes mark a cut-off reply the same way.
                switch (response?["incomplete_details"] as? [String: Any])?["reason"] as? String {
                case "max_output_tokens": result.stopReason = "max_tokens"
                case "content_filter": result.stopReason = "refusal"
                default: break
                }
            case "response.failed":
                let response = object["response"] as? [String: Any]
                if let usage = response?["usage"] as? [String: Any] { merge(usage, into: &result.usage) }
                progress.usage = result.usage
                throw APIError.api(streamError(response?["error"] as? [String: Any] ?? [:]))
            case "error":
                throw APIError.api(streamError(object["error"] as? [String: Any] ?? object))
            default:
                break
            }
        }
        return result
    }

    /// The message of an error reported inside the stream, else its code.
    private static func streamError(_ error: [String: Any]) -> String {
        if let message = error["message"] as? String, !message.isEmpty { return message }
        if let code = error["code"] as? String, !code.isEmpty { return code }
        return "未知错误"
    }

    private static var lastWarmUp = Date.distantPast

    /// Opens the TLS connection to the API ahead of a request (an unauthenticated GET, no tokens), so the first
    /// translation after a quiet spell doesn't pay for the handshake. At most once a minute.
    static func warmUp() {
        guard Date().timeIntervalSince(lastWarmUp) > 60, let url = URL(string: "https://api.openai.com/v1/models") else { return }
        lastWarmUp = Date()
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        URLSession.shared.dataTask(with: request).resume()
    }

    /// OpenAI counts cached and cache-written tokens inside input_tokens; split them out so each is priced on its own.
    private static func merge(_ json: [String: Any], into usage: inout TokenUsage) {
        let details = json["input_tokens_details"] as? [String: Any]
        usage.cacheRead = details?["cached_tokens"] as? Int ?? 0
        usage.cacheWrite = details?["cache_write_tokens"] as? Int ?? 0
        if let v = json["input_tokens"] as? Int { usage.input = max(0, v - usage.cacheRead - usage.cacheWrite) }
        if let v = json["output_tokens"] as? Int { usage.output = v }
    }

    private static func errorMessage(from data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = object["error"] as? [String: Any], let message = error["message"] as? String {
            return message
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Turns an error into a short Chinese message, and whether the fix lives in Settings.
    static func describe(_ error: Error) -> (message: String, needsSettings: Bool) {
        if let error = error as? APIError {
            switch error {
            case .http(401, _):
                return ("API Key 无效，请在设置里更新。", true)
            case .http(403, let m):
                return ("没有权限：\(m)", true)
            case .http(429, let m) where m.contains("quota"):
                return ("OpenAI 账户余额不足，请到 OpenAI 后台充值。", false)
            case .http(429, _):
                return ("请求太频繁或触发了速率限制，请稍后再试。", false)
            case .http(500..., _):
                return ("OpenAI 服务繁忙，请稍后再试。", false)
            case .http(let code, let m):
                return ("请求失败（\(code)）：\(m)", false)
            case .api(let m):
                return ("出错了：\(m)", false)
            }
        }
        if let error = error as? URLError {
            return ("网络连接失败：\(error.localizedDescription)", false)
        }
        return (error.localizedDescription, false)
    }
}
