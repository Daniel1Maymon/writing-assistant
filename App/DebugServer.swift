#if DEBUG
import AppKit
import Core

/// Debug builds only: answers on /tmp/wa-debug.sock for scripts/m2-check.py and m3-check.py (decision 0006).
/// A plain `state` line returns the state; a JSON line runs a command, the same code the card buttons call.
@MainActor
enum DebugServer {
    static let path = "/tmp/wa-debug.sock"
    private static var server: LineSocketServer?

    static func start(controller: CheckController) {
        let server = LineSocketServer(path: path) { [weak controller] line in
            guard let controller = await controller else { return "{}" }
            return await run(line, on: controller)
        }
        do {
            try server.start()
            self.server = server
        } catch {
            NSLog("Debug socket failed: \(error)")
        }
    }

    private static func run(_ line: String, on controller: CheckController) async -> String {
        guard let command = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
              let name = command["cmd"] as? String else { return state(controller) }
        let id = command["id"] as? String ?? ""
        func found(_ act: (Suggestion) -> Void) -> String {
            guard let s = controller.suggestion(id: id) else { return reply(["ok": false, "result": "notFound"]) }
            act(s)
            return reply(["ok": true])
        }
        switch name {
        case "state":
            return state(controller)
        case "accept":
            let result = await controller.acceptNow(id: id, replacementIndex: command["index"] as? Int ?? 0,
                                                    forcePaste: command["paste"] as? Bool ?? false)
            return reply(["ok": true, "result": result.rawValue])
        case "replaceSpan":
            let range = NSRange(location: command["location"] as? Int ?? 0, length: command["length"] as? Int ?? 0)
            let result = await controller.replace(
                range: range, original: command["original"] as? String ?? "",
                with: command["replacement"] as? String ?? "", category: .grammar, message: "Sentence fix",
                ruleId: nil, source: .llm, forcePaste: command["paste"] as? Bool ?? false)
            return reply(["ok": true, "result": result.rawValue])
        case "dismiss": return found(controller.dismiss)
        case "ignoreRule": return found(controller.ignoreRule)
        case "addWord": return found(controller.addToDictionary)
        case "click":
            // A real mouse click, posted like hardware input, for the manual-check path (PLAN.md → M3).
            let point = CGPoint(x: command["x"] as? Double ?? 0, y: command["y"] as? Double ?? 0)
            for type in [CGEventType.leftMouseDown, .leftMouseUp] {
                CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?
                    .post(tap: .cghidEventTap)
                try? await Task.sleep(for: .milliseconds(30))
            }
            return reply(["ok": true])
        case "optionReturn":
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: down)
                event?.flags = .maskAlternate
                event?.post(tap: .cghidEventTap)
            }
            return reply(["ok": true])
        case "type":
            // Real key presses, one per character, so tier 2 sees the user's own input (decision 0014).
            for character in (command["text"] as? String ?? "").utf16 {
                for down in [true, false] {
                    let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down)
                    event?.keyboardSetUnicodeString(stringLength: 1, unicodeString: [character])
                    event?.post(tap: .cghidEventTap)
                }
                try? await Task.sleep(for: .milliseconds(20))
            }
            return reply(["ok": true])
        case "axdump":
            // What the focused element exposes, for adding support for new kinds of fields.
            guard let element = controller.focusedElement else { return reply(["ok": false]) }
            return reply(["ok": true, "tree": dump(element, depth: command["depth"] as? Int ?? 3)])
        case "setTierTwo":
            // Lets m2/m3 checks run without model calls; on again restores the configured key.
            AppState.shared?.setTierTwo(enabled: command["enabled"] as? Bool ?? true)
            return reply(["ok": true, "enabled": controller.tierTwo != nil])
        case "keychainSelfTest":
            // A dummy item under its own account: never the real key.
            let account = "selftest"
            let value = "dummy-\(Int.random(in: 1000...9999))"
            let saved = KeychainStore.save(value, account: account)
            let readBack = KeychainStore.read(account) == value
            let deleted = KeychainStore.delete(account) && KeychainStore.read(account) == nil
            return reply(["ok": saved && readBack && deleted, "saved": saved, "readBack": readBack, "deleted": deleted])
        case "snapshot":
            // Renders the overlay and the card to PNG files, since screen capture is blocked on this Mac.
            let dir = command["dir"] as? String ?? NSTemporaryDirectory()
            return reply(["ok": true, "files": controller.snapshot(to: URL(fileURLWithPath: dir))])
        case "resetIgnore":
            controller.resetIgnore()
            return reply(["ok": true])
        case "mistakes":
            // The "My mistakes" window (decision 0015). Optional: search, category ("" = all), view, delete [ids],
            // export path, snapshot dir, close. Replies with what the window shows.
            guard let window = AppState.shared?.mistakesWindow else { return reply(["ok": false]) }
            let model = window.model
            if let search = command["search"] as? String { model.search = search }
            if let category = command["category"] as? String { model.category = SuggestionCategory(rawValue: category) }
            if let view = command["view"] as? String, let v = MistakesModel.View(rawValue: view) { model.view = v }
            if let ids = command["delete"] as? [Int] { model.delete(Set(ids.map { Int64($0) })) }
            var extra: [String: Any] = [:]
            if let path = command["export"] as? String {
                extra["exported"] = (try? model.exportCSV(to: URL(fileURLWithPath: path))) != nil
            }
            if let dir = command["snapshot"] as? String, let png = window.snapshotPNG {
                let file = URL(fileURLWithPath: dir).appendingPathComponent("mistakes.png")
                extra["snapshot"] = (try? png.write(to: file)) != nil ? file.path : nil
            }
            if command["close"] as? Bool == true { window.close() }
            return reply(extra.merging([
                "ok": true, "visible": window.isVisible, "total": model.total, "error": model.error ?? NSNull(),
                "view": model.view.rawValue, "search": model.search, "category": model.category?.rawValue ?? "",
                "rows": model.rows.map { ["id": $0.id ?? -1, "original": $0.original, "replacement": $0.replacement,
                                          "category": $0.category.rawValue, "sentence": $0.sentence, "app": $0.appName] },
                "repeated": model.repeated.map { ["original": $0.original, "replacement": $0.replacement, "count": $0.count] },
            ]) { a, _ in a })
        case "compose":
            // The Writing window (decision 0016). Optional: text (sets the draft), close. Replies with its state.
            let compose = controller.compose
            if let text = command["text"] as? String { compose.text = text }
            if command["close"] as? Bool == true { compose.close() }
            return reply(["ok": true, "visible": compose.isVisible, "key": compose.isKey, "text": compose.text,
                          "previousApp": compose.previousApp?.bundleIdentifier ?? "",
                          "aboveFront": compose.isAbove(NSWorkspace.shared.frontmostApplication)])
        case "manual":
            let card = controller.manualCard
            var phase = "hidden"
            var extra: [String: Any] = [:]
            switch card.phase {
            case .checking: phase = "checking"
            case .failed(let message): phase = "failed"; extra["message"] = message
            case .result(let result): phase = "result"; extra["looksGood"] = result.looksGood; extra["reason"] = result.reason
            case nil: break
            }
            var reply: [String: Any] = extra.merging([
                "ok": true, "visible": card.isVisible, "phase": phase,
                "choices": card.choices.map { ["text": $0.text, "correction": $0.correction] },
            ]) { a, _ in a }
            if let b = controller.selectionButtonFrame { reply["button"] = [b.minX, b.minY, b.width, b.height] }
            if let dir = command["snapshot"] as? String, let png = card.snapshotPNG {
                let file = URL(fileURLWithPath: dir).appendingPathComponent("manual-card.png")
                reply["snapshot"] = (try? png.write(to: file)) != nil ? file.path : nil
            }
            return Self.reply(reply)
        case "setLog":
            if let enabled = command["enabled"] as? Bool {
                UserDefaults.standard.set(enabled, forKey: CheckController.saveFixesKey)
            }
            if let path = command["path"] as? String {
                controller.mistakeLogURL = path.isEmpty ? MistakeLog.defaultURL : URL(fileURLWithPath: path)
            }
            return reply(["ok": true])
        default:
            return reply(["ok": false, "result": "unknown command"])
        }
    }

    private static func dump(_ element: AXElement, depth: Int) -> [String: Any] {
        var names: CFArray?
        AXUIElementCopyAttributeNames(element.ref, &names)
        var params: CFArray?
        AXUIElementCopyParameterizedAttributeNames(element.ref, &params)
        var node: [String: Any] = [
            "role": element.role ?? "", "subrole": element.subrole ?? "",
            "attributes": (names as? [String]) ?? [], "parameterized": (params as? [String]) ?? [],
            "valueLength": element.value.map { ($0 as NSString).length } ?? -1,
        ]
        if let range = element.selectedRange { node["selection"] = [range.location, range.length] }
        var children: CFTypeRef?
        if depth > 0, AXUIElementCopyAttributeValue(element.ref, "AXChildren" as CFString, &children) == .success,
           let list = children as? [AXUIElement] {
            node["children"] = list.prefix(8).map { dump(AXElement(ref: $0), depth: depth - 1) }
        }
        return node
    }

    private static func reply(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    private static func state(_ controller: CheckController) -> String {
        let element = controller.focusedElement
        let suggestions: [[String: Any]] = controller.drawn.map { item in
            let s = item.placed.suggestion
            return [
                "id": s.id, "original": s.original, "category": s.category.rawValue, "ruleId": s.ruleId ?? "",
                "replacements": s.replacements, "sentenceHash": s.sentenceHash, "rewrite": s.rewrite?.rawValue ?? "",
                "source": s.source.rawValue, "message": s.message,
                "range": [item.placed.range.location, item.placed.range.length],
                "rect": [item.rect.minX, item.rect.minY, item.rect.width, item.rect.height],
            ]
        }
        let counters = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(controller.counters))) ?? [:]
        var state: [String: Any] = [
            "app": controller.focusedApp?.bundleIdentifier ?? "",
            "role": element?.role ?? "",
            "secure": element?.isSecure ?? false,
            "suggestions": suggestions,
            "counters": counters,
            "ignore": ["rules": controller.ignore.rules.sorted(), "dismissed": controller.ignore.dismissed.sorted(),
                       "dictionary": controller.ignore.dictionary.sorted()],
            "atCaret": controller.suggestionAtCaret()?.suggestion.id ?? "",
            "card": controller.cardSuggestionId ?? "",
            // Debug builds only, over a user-only socket; never logged (CLAUDE.md).
            "text": (element?.isSecure ?? true) ? "" : (element?.value ?? ""),
        ]
        if let tierTwo = controller.tierTwo {
            let counters = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(tierTwo.counters))) ?? [:]
            state["tier2"] = ["counters": counters, "inFlight": tierTwo.inFlightCount, "capReached": tierTwo.capReached,
                              "requestsToday": tierTwo.ledger.requests, "costToday": tierTwo.ledger.cost]
        }
        if let caret = element?.selectedRange {
            state["selection"] = [caret.location, caret.length]
        }
        if let window = element?.window?.frame {
            state["window"] = [window.minX, window.minY, window.width, window.height]
        }
        return reply(state)
    }
}
#endif
