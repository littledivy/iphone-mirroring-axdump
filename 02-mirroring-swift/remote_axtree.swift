// remote_axtree.swift — read and control the iPhone screen shown by iPhone
// Mirroring, through the live iOS accessibility tree. No VoiceOver.
//
// How it works: iPhone Mirroring loads Apple's AccessibilityPlatformTranslation
// bundle (the AXPTranslator) inside its own process, wired to the Continuity
// link to the phone. That translator only exposes the iOS elements once an
// assistive client with the private `remoteDeviceContent` entitlement turns it
// on. This binary is that client: it sets AXEnhancedUserInterface on the app +
// window + mirror hosting-view, waits for the tree to stream in, then reads it
// with the normal AXUIElement API and acts with synthesized clicks/keys.
//
// Build + sign:  ./build.sh   (see that script; needs the entitlement + a Mac
// with SIP disabled and amfi_get_out_of_my_way=1 so the self-signed entitlement
// is honored).
//
// Usage:
//   remote_axtree json                 full tree as JSON (id,role,label,frame,actions)
//   remote_axtree read                 compact text: one line per labeled node
//   remote_axtree tap "<label substr>" click the element whose label contains this
//   remote_axtree tapid <id>           click the element with this JSON id
//   remote_axtree xy <x> <y>           click at absolute screen coords
//   remote_axtree swipe <up|down|left|right>   scroll/swipe at window center
//   remote_axtree type "<text>"        type text into the focused field
//   remote_axtree home                 tap the Home Screen button
//   remote_axtree apps                 tap the App Switcher button
//
// All coordinates in JSON are absolute macOS screen points; tap/xy consume the
// same coordinate space.

import Cocoa
import ApplicationServices

// ---------- process ----------
func findPid() -> pid_t? {
    for a in NSWorkspace.shared.runningApplications
    where a.bundleIdentifier == "com.apple.ScreenContinuity" || a.localizedName == "iPhone Mirroring" {
        return a.processIdentifier
    }
    return nil
}
func die(_ m: String, _ code: Int32 = 1) -> Never {
    FileHandle.standardError.write((m + "\n").data(using: .utf8)!); exit(code)
}
guard AXIsProcessTrusted() else {
    die("Not trusted for Accessibility. Grant the terminal (or this binary) in System Settings > Privacy & Security > Accessibility.", 2)
}
guard let pid = findPid() else { die("iPhone Mirroring is not running.", 3) }

let app = AXUIElementCreateApplication(pid)
let sys = AXUIElementCreateSystemWide()

// ---------- AX helpers ----------
func attr(_ e: AXUIElement, _ n: String) -> AnyObject? {
    var v: AnyObject?; return AXUIElementCopyAttributeValue(e, n as CFString, &v) == .success ? v : nil
}
func kids(_ e: AXUIElement) -> [AXUIElement] { (attr(e, "AXChildren") as? [AXUIElement]) ?? [] }
func role(_ e: AXUIElement) -> String {
    let r = (attr(e, "AXRole") as? String) ?? "?"
    let s = (attr(e, "AXSubrole") as? String) ?? ""
    return s.isEmpty ? r : r + "/" + s
}
func label(_ e: AXUIElement) -> String {
    [(attr(e, "AXTitle") as? String) ?? "",
     (attr(e, "AXDescription") as? String) ?? "",
     (attr(e, "AXValue") as? String) ?? "",
     (attr(e, "AXHelp") as? String) ?? ""]
        .filter { !$0.isEmpty }
        .reduce(into: [String]()) { acc, s in if !acc.contains(s) { acc.append(s) } }  // dedup repeated title|desc
        .joined(separator: " | ")
}
func frame(_ e: AXUIElement) -> (CGFloat, CGFloat, CGFloat, CGFloat) {
    var p = CGPoint.zero, s = CGSize.zero
    if let v = attr(e, "AXPosition") { AXValueGetValue(v as! AXValue, .cgPoint, &p) }
    if let v = attr(e, "AXSize") { AXValueGetValue(v as! AXValue, .cgSize, &s) }
    return (p.x, p.y, s.width, s.height)
}
func actions(_ e: AXUIElement) -> [String] {
    var a: CFArray?; AXUIElementCopyActionNames(e, &a); return (a as? [String]) ?? []
}
func setTrue(_ e: AXUIElement, _ n: String) { AXUIElementSetAttributeValue(e, n as CFString, kCFBooleanTrue) }

func windowRect() -> CGRect {
    if let w = (attr(app, "AXWindows") as? [AXUIElement])?.first {
        let (x, y, ww, hh) = frame(w); return CGRect(x: x, y: y, width: ww, height: hh)
    }
    return .zero
}

// ---------- turn the remote translator on, wait for the iOS tree ----------
func nodeCount() -> Int { var c = 0; func w(_ e: AXUIElement, _ d: Int) { if d > 70 { return }; c += 1; for k in kids(e) { w(k, d + 1) } }; w(app, 0); return c }

func enable() {
    var g: AXUIElement?
    let r = windowRect()
    if r != .zero { AXUIElementCopyElementAtPosition(sys, Float(r.midX), Float(r.midY), &g) }
    var targets = [app]
    targets += (attr(app, "AXWindows") as? [AXUIElement]) ?? []
    if let g = g { targets.append(g) }
    for t in targets { setTrue(t, "AXManualAccessibility"); setTrue(t, "AXEnhancedUserInterface") }
    // wait until the tree stops growing (translator finished streaming) or 4s.
    var last = -1, stable = 0
    let deadline = Date(timeIntervalSinceNow: 4.0)
    while Date() < deadline {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
        let n = nodeCount()
        if n == last { stable += 1; if stable >= 2 && n > 190 { break } } else { stable = 0 }
        last = n
    }
}

// ---------- find ----------
func findByLabel(_ needle: String) -> AXUIElement? {
    var hit: AXUIElement?
    func w(_ e: AXUIElement, _ d: Int) {
        if hit != nil || d > 70 { return }
        if label(e).localizedCaseInsensitiveContains(needle) { hit = e; return }
        for k in kids(e) { w(k, d + 1) }
    }
    w(app, 0); return hit
}
func findById(_ id: String) -> AXUIElement? {
    func w(_ e: AXUIElement, _ path: String) -> AXUIElement? {
        if path == id { return e }
        for (i, k) in kids(e).enumerated() { if let r = w(k, "\(path)/\(i)") { return r } }
        return nil
    }
    return w(app, "0")
}

// ---------- input ----------
func raise() { AXUIElementPerformAction(app, "AXRaise" as CFString); usleep(150_000) }
func click(_ x: CGFloat, _ y: CGFloat) {
    raise()
    let src = CGEventSource(stateID: .hidSystemState)
    let p = CGPoint(x: x, y: y)
    CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
    usleep(120_000)
    CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
    usleep(60_000)
    CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
}
// Prefer AXPress: it routes through the translator to the phone and works even
// when the mirror window is backgrounded (video paused). Fall back to a real
// click only for elements that expose no press action.
func activate(_ e: AXUIElement) {
    if actions(e).contains("AXPress") {
        raise()
        if AXUIElementPerformAction(e, "AXPress" as CFString) == .success { return }
    }
    let (x, y, w, h) = frame(e); click(x + w / 2, y + h / 2)
}
func swipe(_ dir: String) {
    raise()
    let r = windowRect(); let cx = r.midX, cy = r.midY
    var dx: CGFloat = 0, dy: CGFloat = 0; let d: CGFloat = 220
    switch dir { case "up": dy = -d; case "down": dy = d; case "left": dx = -d; case "right": dx = d; default: break }
    let src = CGEventSource(stateID: .hidSystemState)
    let start = CGPoint(x: cx - dx / 2, y: cy - dy / 2), end = CGPoint(x: cx + dx / 2, y: cy + dy / 2)
    CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: start, mouseButton: .left)?.post(tap: .cghidEventTap)
    let steps = 14
    for i in 1...steps {
        let t = CGFloat(i) / CGFloat(steps)
        let p = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
        CGEvent(mouseEventSource: src, mouseType: .leftMouseDragged, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
        usleep(12_000)
    }
    CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: end, mouseButton: .left)?.post(tap: .cghidEventTap)
}
func typeText(_ s: String) {
    raise()
    let src = CGEventSource(stateID: .hidSystemState)
    for u in s.unicodeScalars {
        var ch = UniChar(u.value)
        let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true)
        down?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &ch); down?.post(tap: .cghidEventTap)
        let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false)
        up?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &ch); up?.post(tap: .cghidEventTap)
        usleep(8_000)
    }
}

// ---------- output ----------
func esc(_ v: String) -> String {
    var o = ""; for c in v { switch c { case "\"": o += "\\\""; case "\\": o += "\\\\"; case "\n": o += "\\n"; case "\t": o += " "; default: o.append(c) } }; return o
}
func dumpJSON() {
    var out = "["; var first = true
    func w(_ e: AXUIElement, _ path: String, _ d: Int) {
        if d > 70 { return }
        let (x, y, ww, hh) = frame(e); let acts = actions(e)
        if !first { out += "," }; first = false
        out += "{\"id\":\"\(path)\",\"role\":\"\(esc(role(e)))\",\"label\":\"\(esc(label(e)))\","
        out += "\"x\":\(Int(x)),\"y\":\(Int(y)),\"w\":\(Int(ww)),\"h\":\(Int(hh)),"
        out += "\"tappable\":\(acts.contains("AXPress")),\"actions\":[\(acts.map { "\"\($0)\"" }.joined(separator: ","))]}"
        for (i, k) in kids(e).enumerated() { w(k, "\(path)/\(i)", d + 1) }
    }
    w(app, "0", 0); out += "]"; print(out)
}
func dumpRead() {
    func w(_ e: AXUIElement, _ d: Int) {
        let l = label(e)
        if !l.isEmpty { print("\(String(repeating: "  ", count: min(d, 10)))\(role(e))  \(l)") }
        for k in kids(e) { w(k, d + 1) }
    }
    w(app, 0)
}

// ---------- dispatch ----------
let a = Array(CommandLine.arguments.dropFirst())
let cmd = a.first ?? "read"
enable()
switch cmd {
case "json": dumpJSON()
case "read", "dump": dumpRead()
case "tap":
    guard a.count > 1 else { die("usage: tap \"<label substring>\"") }
    guard let e = findByLabel(a[1]) else { die("no element matching \"\(a[1])\"", 4) }
    activate(e); print("tapped: \(label(e))")
case "tapid":
    guard a.count > 1, let e = findById(a[1]) else { die("no element id \(a.count>1 ? a[1] : "")", 4) }
    activate(e); print("tapped id \(a[1]): \(label(e))")
case "xy":
    guard a.count > 2, let x = Double(a[1]), let y = Double(a[2]) else { die("usage: xy <x> <y>") }
    click(CGFloat(x), CGFloat(y)); print("clicked \(x),\(y)")
case "swipe":
    guard a.count > 1 else { die("usage: swipe <up|down|left|right>") }
    swipe(a[1]); print("swiped \(a[1])")
case "type":
    guard a.count > 1 else { die("usage: type \"<text>\"") }
    typeText(a[1]); print("typed")
case "home":
    // native Mac toolbar control: AXPress is reliable, unlike iOS proxies.
    if let e = findByLabel("Home Screen") { raise(); AXUIElementPerformAction(e, "AXPress" as CFString); print("home") } else { die("Home Screen button not found", 4) }
case "apps":
    if let e = findByLabel("App Switcher") { raise(); AXUIElementPerformAction(e, "AXPress" as CFString); print("app switcher") } else { die("App Switcher button not found", 4) }
default:
    die("unknown command: \(cmd)\nvalid: json read tap tapid xy swipe type home apps")
}
