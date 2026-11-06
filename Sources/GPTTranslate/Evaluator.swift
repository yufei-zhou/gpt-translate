import Foundation

/// Debug benchmark (gpttranslate://debug-eval): runs every text in debug/evalset.json through each
/// translation model with the production prompt, recording latency, tokens, cost and output.
@MainActor
enum Evaluator {
    struct Item: Codable {
        let id: String
        let text: String
    }

    struct Run: Codable {
        let id: String
        let model: String
        var mode = "seq"
        var firstText: Double?
        /// When both panes were showing text — the moment the second language starts appearing.
        var bothText: Double?
        var total: Double
        var inputTokens = 0
        var outputTokens = 0
        var cacheRead = 0
        var cacheWrite = 0
        var cost = 0.0
        var source: String?
        var targets: [TargetText] = []
        var raw = ""
        var error: String?
    }

    private final class Clock {
        let start = Date()
        var firstText: Double?
        var bothText: Double?
        var partFirst: [Double?] = [nil, nil]
        var elapsed: Double { Date().timeIntervalSince(start) }
    }

    private static var dir: URL { AppPaths.support.appendingPathComponent("debug", isDirectory: true) }

    static func run(models: [String]) async {
        let progress = dir.appendingPathComponent("eval-progress.txt")
        func report(_ text: String) { try? text.write(to: progress, atomically: true, encoding: .utf8) }
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("evalset.json")),
              let items = try? JSONDecoder().decode([Item].self, from: data) else { return report("error: evalset.json") }
        guard let key = Keychain.apiKey else { return report("error: no key") }

        var runs: [Run] = []
        for (n, item) in items.enumerated() {
            // Alternate which model goes first so neither always benefits from a warm connection.
            for model in n % 2 == 0 ? models : models.reversed() {
                runs.append(await runOne(item, model: model, key: key))
                report("\(runs.count)/\(items.count * models.count)")
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
        try? encoder.encode(runs).write(to: dir.appendingPathComponent("eval-results.json"))
        report("done")
    }

    /// Same items through one model, alternating the single-request (seq) and two-request (par) designs.
    static func compareModes(model: String) async {
        let progress = dir.appendingPathComponent("eval-progress.txt")
        func report(_ text: String) { try? text.write(to: progress, atomically: true, encoding: .utf8) }
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("evalset.json")),
              let items = try? JSONDecoder().decode([Item].self, from: data) else { return report("error: evalset.json") }
        guard let key = Keychain.apiKey else { return report("error: no key") }
        var runs: [Run] = []
        for (n, item) in items.enumerated() {
            for parallel in n % 2 == 0 ? [false, true] : [true, false] {
                runs.append(parallel ? await runParallel(item, model: model, key: key) : await runOne(item, model: model, key: key))
                report("\(runs.count)/\(items.count * 2)")
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
        try? encoder.encode(runs).write(to: dir.appendingPathComponent("eval-compare.json"))
        report("done")
    }

    private static func runParallel(_ item: Item, model: String, key: String) async -> Run {
        let clock = Clock()
        do {
            async let a = streamPart(0, item: item, model: model, key: key, clock: clock)
            async let b = streamPart(1, item: item, model: model, key: key, clock: clock)
            let results = try await [a, b]
            var run = Run(id: item.id, model: model, total: clock.elapsed)
            run.mode = "par"
            let firsts = clock.partFirst.compactMap { $0 }
            run.firstText = firsts.min()
            run.bothText = firsts.count == 2 ? firsts.max() : nil
            for result in results {
                UsageTracker.shared.record(model: result.model.isEmpty ? model : result.model, usage: result.usage)
                run.inputTokens += result.usage.input
                run.outputTokens += result.usage.output
                run.cacheRead += result.usage.cacheRead
                run.cacheWrite += result.usage.cacheWrite
                run.cost += Models.cost(model: model, usage: result.usage)
            }
            let outputs = results.map { Translator.parse($0.text) }
            run.source = outputs[0].source
            run.targets = outputs.compactMap { $0.targets.first }.map { TargetText(lang: $0.lang, text: $0.text) }
            run.raw = results.map(\.text).joined(separator: "\n---\n")
            return run
        } catch {
            var run = Run(id: item.id, model: model, total: clock.elapsed, error: "\(error)")
            run.mode = "par"
            return run
        }
    }

    private static func streamPart(_ index: Int, item: Item, model: String, key: String, clock: Clock) async throws -> StreamResult {
        let (body, betas) = Models.requestBody(model: model, system: Translator.instructions(part: index),
                                               user: Translator.userMessage(item.text, part: index), maxTokens: 16000)
        return try await APIClient.stream(key: key, body: body, betas: betas) { raw in
            if clock.partFirst[index] == nil, let first = Translator.parse(raw).targets.first, !first.text.isEmpty {
                clock.partFirst[index] = clock.elapsed
            }
        }
    }

    private static func runOne(_ item: Item, model: String, key: String) async -> Run {
        let (body, betas) = Models.requestBody(model: model, system: Translator.systemPrompt,
                                               user: Translator.userMessage(item.text), maxTokens: 16000)
        let clock = Clock()
        do {
            let result = try await APIClient.stream(key: key, body: body, betas: betas) { raw in
                let targets = Translator.parse(raw).targets
                if clock.firstText == nil, let first = targets.first, !first.text.isEmpty {
                    clock.firstText = clock.elapsed
                }
                if clock.bothText == nil, targets.count > 1, !targets[1].text.isEmpty {
                    clock.bothText = clock.elapsed
                }
            }
            UsageTracker.shared.record(model: result.model.isEmpty ? model : result.model, usage: result.usage)
            let output = Translator.parse(result.text)
            return Run(id: item.id, model: result.model.isEmpty ? model : result.model,
                       firstText: clock.firstText, bothText: clock.bothText, total: clock.elapsed,
                       inputTokens: result.usage.input, outputTokens: result.usage.output,
                       cacheRead: result.usage.cacheRead, cacheWrite: result.usage.cacheWrite,
                       cost: Models.cost(model: model, usage: result.usage), source: output.source,
                       targets: output.targets.map { TargetText(lang: $0.lang, text: $0.text) }, raw: result.text)
        } catch {
            return Run(id: item.id, model: model, total: clock.elapsed, error: "\(error)")
        }
    }
}
