#if DEBUG
import AppKit
import Core

/// Debug builds only: answers `state` on /tmp/wa-debug.sock with JSON for scripts/m2-check.py (decision 0006).
@MainActor
enum DebugServer {
    static let path = "/tmp/wa-debug.sock"
    private static var server: LineSocketServer?

    static func start(controller: CheckController) {
        let server = LineSocketServer(path: path) { [weak controller] _ in
            await MainActor.run { controller.map(state) ?? "{}" }
        }
        do {
            try server.start()
            self.server = server
        } catch {
            NSLog("Debug socket failed: \(error)")
        }
    }

    private static func state(_ controller: CheckController) -> String {
        let element = controller.focusedElement
        let suggestions: [[String: Any]] = controller.drawn.map { item in
            let s = item.placed.suggestion
            return [
                "id": s.id, "original": s.original, "category": s.category.rawValue, "ruleId": s.ruleId ?? "",
                "replacements": s.replacements, "sentenceHash": s.sentenceHash,
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
        ]
        if let window = element?.window?.frame {
            state["window"] = [window.minX, window.minY, window.width, window.height]
        }
        let data = (try? JSONSerialization.data(withJSONObject: state)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}
#endif
