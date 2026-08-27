import AppKit
import ApplicationServices

/// 窗口内部可选区域。只保留控件角色与矩形，不读取标题、输入值或正文。
struct UIElementCandidate: Sendable {
    let cgFrame: CGRect
    let role: String
}

enum UIElementDetector {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// 只在用户从设置页主动点击时调用；截图过程绝不自行弹权限框。
    @MainActor
    static func requestAccess() {
        // 使用系统定义的稳定键值，避开 Swift 6 对旧 C 可变全局量的并发检查。
        let options = ["AXTrustedCheckOptionPrompt": true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    static func detect(
        at point: CGPoint,
        processID: pid_t,
        inside windowFrame: CGRect
    ) async -> UIElementCandidate? {
        await Task.detached(priority: .userInitiated) {
            detectSynchronously(at: point, processID: processID, inside: windowFrame)
        }.value
    }

    nonisolated private static func detectSynchronously(
        at point: CGPoint,
        processID: pid_t,
        inside windowFrame: CGRect
    ) -> UIElementCandidate? {
        guard AXIsProcessTrusted() else { return nil }

        let app = AXUIElementCreateApplication(processID)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(
            app,
            Float(point.x),
            Float(point.y),
            &hit
        ) == .success else { return nil }

        let eligibleRoles: Set<String> = [
            kAXGroupRole as String,
            kAXScrollAreaRole as String,
            kAXSplitGroupRole as String,
            kAXToolbarRole as String,
            kAXListRole as String,
            kAXTableRole as String,
            kAXOutlineRole as String,
            "AXWebArea",
            "AXDialog",
            "AXPopover",
            "AXSheet",
        ]

        var matches: [UIElementCandidate] = []
        var current = hit
        for _ in 0..<14 {
            guard let element = current else { break }
            let role = stringAttribute(kAXRoleAttribute, of: element) ?? ""
            if eligibleRoles.contains(role),
               let frame = frame(of: element),
               frame.contains(point),
               frame.width >= 120,
               frame.height >= 60,
               frame.width * frame.height >= 10_000,
               frame.width * frame.height < windowFrame.width * windowFrame.height * 0.92,
               frame.intersection(windowFrame).width >= frame.width * 0.8,
               frame.intersection(windowFrame).height >= frame.height * 0.8 {
                matches.append(UIElementCandidate(cgFrame: frame, role: role))
            }

            if role == (kAXWindowRole as String) || role == (kAXApplicationRole as String) {
                break
            }
            current = parent(of: element)
        }

        // 点中的最小有意义容器最接近用户眼中的“窗内卡片/面板”。
        return matches.min {
            $0.cgFrame.width * $0.cgFrame.height < $1.cgFrame.width * $1.cgFrame.height
        }
    }

    nonisolated private static func stringAttribute(
        _ key: String,
        of element: AXUIElement
    ) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    nonisolated private static func frame(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXPositionAttribute as CFString,
            &positionValue
        ) == .success,
        AXUIElementCopyAttributeValue(
            element,
            kAXSizeAttribute as CFString,
            &sizeValue
        ) == .success,
        let positionValue,
        let sizeValue,
        CFGetTypeID(positionValue) == AXValueGetTypeID(),
        CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }

        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }

    nonisolated private static func parent(of element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXParentAttribute as CFString,
            &value
        ) == .success,
        let value else { return nil }
        return (value as! AXUIElement)
    }
}
