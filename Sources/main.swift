// copypaste — Finder에서 파일을 복사하면 tailnet 전용 공유 링크를 클립보드에 덧붙인다.
//
// 구성: (1) 클립보드 감시  (2) 공유 목록 저장소  (3) 127.0.0.1 HTTP 서버  (4) 메뉴 막대
// 외부 노출은 `tailscale serve`가 맡는다: https://<기기>.ts.net:8765 -> 127.0.0.1:48765

import AppKit
import Network
import ServiceManagement

// MARK: - 설정

// 바꾸려면: defaults write com.copypaste.agent port -int 9000  (그 뒤 앱을 다시 실행)
// 환경 변수(COPYPASTE_PORT 등)가 있으면 그것이 우선한다.
let env = ProcessInfo.processInfo.environment
func setting(_ key: String, _ envName: String, _ fallback: Double) -> Double {
    if let v = Double(env[envName] ?? "") { return v }
    if let v = UserDefaults.standard.object(forKey: key) as? NSNumber { return v.doubleValue }
    return fallback
}
func portSetting(_ key: String, _ envName: String, _ fallback: UInt16) -> UInt16 {
    let v = setting(key, envName, Double(fallback))
    return v >= 1024 && v <= 65535 ? UInt16(v) : fallback
}
let localPort = portSetting("localPort", "COPYPASTE_LOCAL_PORT", 48765)
let publicPort = portSetting("port", "COPYPASTE_PORT", 8765)
let shareTTL: TimeInterval = max(setting("ttlHours", "COPYPASTE_TTL_HOURS", 24), 0.1) * 3600
let logPath = NSHomeDirectory() + "/Library/Logs/copypaste.log"
let legacyAgentPlist = NSHomeDirectory() + "/Library/LaunchAgents/com.copypaste.agent.plist"
let legacyAppPath = NSHomeDirectory() + "/Applications/Copypaste.app"
let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
let markerType = NSPasteboard.PasteboardType("com.copypaste.marker")

/// 로그가 1MB를 넘으면 시작할 때 끝부분 200KB만 남긴다.
func trimLog() {
    let path = logPath
    guard let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue, size > 1_000_000,
          let fh = FileHandle(forUpdatingAtPath: path) else { return }
    try? fh.seek(toOffset: UInt64(size - 200_000))
    let tail = (try? fh.readToEnd()) ?? Data()
    try? fh.truncate(atOffset: 0)
    try? fh.seek(toOffset: 0)
    try? fh.write(contentsOf: tail)
    try? fh.close()
}

/// 로그는 본인만 읽을 수 있는 파일에 덧붙여 쓴다.
let logHandle: FileHandle? = {
    try? FileManager.default.createDirectory(atPath: (logPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    let fd = open(logPath, O_WRONLY | O_APPEND | O_CREAT, 0o600)
    if fd >= 0 { fchmod(fd, 0o600) }
    return fd >= 0 ? FileHandle(fileDescriptor: fd, closeOnDealloc: true) : nil
}()
let logLock = NSLock()

func log(_ s: String) {
    let line = Data("[\(ISO8601DateFormatter().string(from: Date()))] \(s)\n".utf8)
    logLock.lock(); defer { logLock.unlock() }
    try? logHandle?.write(contentsOf: line)
}

// MARK: - 공유 목록

struct Share: Codable {
    var token: String
    var paths: [String]
    var name: String
    var isArchive: Bool
    var created: Date
    var expires: Date { created.addingTimeInterval(shareTTL) }
}

final class Store {
    private let q = DispatchQueue(label: "copypaste.store")
    private var shares: [Share] = []
    private let file: URL

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("copypaste")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        file = dir.appendingPathComponent("shares.json")
        if let d = try? Data(contentsOf: file), let s = try? JSONDecoder().decode([Share].self, from: d) {
            shares = s
        }
    }

    private func pruneAndSave() {
        shares.removeAll { $0.expires < Date() }
        if let d = try? JSONEncoder().encode(shares) {
            try? d.write(to: file, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
    }

    /// 같은 파일을 다시 복사하면 같은 링크를 재사용하고 만료 시간만 갱신한다.
    func add(paths: [String]) -> Share {
        q.sync {
            if let i = shares.firstIndex(where: { $0.paths == paths }) {
                var s = shares.remove(at: i)
                s.created = Date()
                shares.append(s)
                pruneAndSave()
                return s
            }
            var isDir: ObjCBool = false
            let first = (paths[0] as NSString).lastPathComponent
            let name: String
            let archive: Bool
            if paths.count == 1 {
                FileManager.default.fileExists(atPath: paths[0], isDirectory: &isDir)
                archive = isDir.boolValue
                name = archive ? first + ".zip" : first
            } else {
                archive = true
                name = "\(first) 외 \(paths.count - 1)개.zip"
            }
            let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
            var rng = SystemRandomNumberGenerator()
            let token = String((0..<22).map { _ in alphabet.randomElement(using: &rng)! }) // 약 130비트
            let s = Share(token: token, paths: paths, name: name, isArchive: archive, created: Date())
            shares.append(s)
            pruneAndSave()
            return s
        }
    }

    func get(_ token: String) -> Share? {
        q.sync { shares.first { $0.token == token && $0.expires >= Date() } }
    }

    /// 최신순
    func all() -> [Share] {
        q.sync { pruneAndSave(); return Array(shares.reversed()) }
    }

    func clear() {
        q.sync { shares.removeAll(); pruneAndSave() }
    }
}

let store = Store()

/// tailscale serve만 아는 비밀 경로. 로컬 포트로 직접 들어오는 요청은 이 값을 모르므로
/// 헤더를 꾸며도 통과하지 못한다. (같은 Mac의 다른 사용자·샌드박스 앱 차단)
let upstreamSecret: String = {
    let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("copypaste")
    let file = dir.appendingPathComponent("secret")
    if let s = try? String(contentsOf: file, encoding: .utf8), s.count == 40, s.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) {
        return s
    }
    let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
    var rng = SystemRandomNumberGenerator()
    let s = String((0..<40).map { _ in alphabet.randomElement(using: &rng)! })
    FileManager.default.createFile(atPath: file.path, contents: Data(s.utf8), attributes: [.posixPermissions: 0o600])
    return s
}()

// MARK: - Tailscale

struct Identity {
    var host: String   // case-macmini-1.tailXXXX.ts.net
    var login: String  // 이 기기 소유 계정
}

final class Tailscale {
    private let lock = NSLock()
    private var _identity: Identity?
    var identity: Identity? { lock.lock(); defer { lock.unlock() }; return _identity }

    /// 링크를 만들 수 없는 이유. nil이면 정상. 메뉴 막대에 그대로 보여 준다.
    private var _problem: String? = "Tailscale 연결 확인 중…"
    var problem: String? { lock.lock(); defer { lock.unlock() }; return _problem }
    private func set(problem: String?) {
        lock.lock(); let changed = _problem != problem; _problem = problem; lock.unlock()
        if changed, let problem { log("사용 불가: \(problem)") }
        if changed { DispatchQueue.main.async { delegate.refreshIcon() } }
    }

    private var binary: String? {
        ["/Applications/Tailscale.app/Contents/MacOS/Tailscale",
         "/usr/local/bin/tailscale", "/opt/homebrew/bin/tailscale"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func run(_ args: [String]) -> (Int32, Data) {
        guard let bin = binary else { return (-1, Data()) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = args
        // Tailscale.app의 실행 파일은 터미널 밖에서 부르면 GUI로 뜨려다 실패한다. CLI로 동작하게 강제한다.
        var e = ProcessInfo.processInfo.environment
        e["TAILSCALE_BE_CLI"] = "1"
        p.environment = e
        p.standardInput = FileHandle.nullDevice
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        do { try p.run() } catch { return (-1, Data()) }
        // 사용자 입력을 기다리며 멈추는 경우(예: serve 사용 동의 대기)에 대비해 20초로 제한한다.
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: killer)
        let d = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        return (p.terminationStatus, d)
    }

    /// 이 포트에 이미 다른 serve 설정이 있으면 절대 덮어쓰지 않는다.
    private func ensureServe(host: String) -> String? {
        let base = "http://127.0.0.1:\(localPort)"
        let target = base + "/" + upstreamSecret
        let (sc, sd) = run(["serve", "status", "--json"])
        guard sc == 0 else { return "tailscale serve 상태를 읽지 못했습니다" }
        let cfg = (try? JSONSerialization.jsonObject(with: sd) as? [String: Any]) ?? [:]
        let tcp = cfg["TCP"] as? [String: Any] ?? [:]
        let web = cfg["Web"] as? [String: Any] ?? [:]
        if tcp["\(publicPort)"] != nil {
            let handlers = (web["\(host):\(publicPort)"] as? [String: Any])?["Handlers"] as? [String: Any] ?? [:]
            let proxy = handlers.count == 1 ? (handlers["/"] as? [String: Any])?["Proxy"] as? String : nil
            if proxy == target { return nil }
            // 우리 로컬 포트를 가리키는 예전 설정(비밀 경로 없음/바뀜)만 갱신하고, 남의 설정은 건드리지 않는다.
            guard let proxy, proxy == base || proxy.hasPrefix(base + "/") else {
                return "포트 \(publicPort)를 다른 tailscale serve 설정이 쓰고 있습니다 (COPYPASTE_PORT로 변경 후 재설치)"
            }
        }
        let (c, out) = run(["serve", "--bg", "--https=\(publicPort)", target])
        if c == 0 { return nil }
        let msg = String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        log("tailscale serve 실패: \(msg)")
        // 가장 흔한 원인: tailnet에서 HTTPS 인증서(또는 serve)가 아직 켜져 있지 않음
        if let url = msg.split(whereSeparator: { $0 == " " || $0 == "\n" }).first(where: { $0.hasPrefix("https://login.tailscale.com") }) {
            return "Tailscale에서 HTTPS/Serve를 켜야 합니다: \(url)"
        }
        return "tailscale serve 설정 실패 (로그 확인)"
    }

    /// 제거할 때: 이 포트의 serve 설정이 우리 것일 때만 끈다.
    func removeServe() {
        var host = identity?.host
        if host == nil, let j = try? JSONSerialization.jsonObject(with: run(["status", "--json"]).1) as? [String: Any],
           var dns = (j["Self"] as? [String: Any])?["DNSName"] as? String {
            if dns.hasSuffix(".") { dns.removeLast() }
            host = dns
        }
        guard let host, !host.isEmpty else { return }
        let (sc, sd) = run(["serve", "status", "--json"])
        guard sc == 0, let cfg = try? JSONSerialization.jsonObject(with: sd) as? [String: Any],
              let web = cfg["Web"] as? [String: Any],
              let handlers = (web["\(host):\(publicPort)"] as? [String: Any])?["Handlers"] as? [String: Any],
              let proxy = (handlers["/"] as? [String: Any])?["Proxy"] as? String,
              proxy.hasPrefix("http://127.0.0.1:\(localPort)") else { return }
        _ = run(["serve", "--https=\(publicPort)", "off"])
    }

    /// 기기 이름과 계정을 읽고 tailscale serve를 켠다. 실패하면 30초 뒤 다시 시도한다.
    func setup() {
        DispatchQueue.global().async {
            let (code, data) = self.run(["status", "--json"])
            if code == 0,
               let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let me = j["Self"] as? [String: Any],
               var dns = me["DNSName"] as? String, !dns.isEmpty {
                if dns.hasSuffix(".") { dns.removeLast() }
                var login = ""
                if let uid = me["UserID"] as? NSNumber,
                   let users = j["User"] as? [String: Any],
                   let u = users[uid.stringValue] as? [String: Any] {
                    login = u["LoginName"] as? String ?? ""
                }
                self.lock.lock()
                let first = self._identity == nil
                self._identity = Identity(host: dns, login: login)
                self.lock.unlock()
                if first { log("tailscale: \(dns) (\(login))") }
                if login.isEmpty || login == "tagged-devices" {
                    // 계정이 없는 기기는 "같은 계정" 확인을 할 수 없으므로 서비스하지 않는다.
                    self.set(problem: "태그된 기기에서는 사용할 수 없습니다 (소유 계정 없음)")
                } else {
                    let problem = self.ensureServe(host: dns)
                    if problem == nil && self.problem != nil { log("준비 완료: https://\(dns):\(publicPort)/") }
                    self.set(problem: problem)
                }
                // 기기 이름이 바뀌거나 serve 설정이 지워진 경우를 위해 10분마다 다시 확인한다.
                DispatchQueue.global().asyncAfter(deadline: .now() + (self.problem == nil ? 600 : 30)) { self.setup() }
            } else {
                var why = self.binary == nil ? "Tailscale 앱을 찾을 수 없습니다" : "Tailscale에 로그인되어 있지 않거나 꺼져 있습니다"
                if code == 0, let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let st = j["BackendState"] as? String, st != "Running" { why += " (\(st))" }
                self.lock.lock(); self._identity = nil; self.lock.unlock()
                self.set(problem: why)
                DispatchQueue.global().asyncAfter(deadline: .now() + 30) { self.setup() }
            }
        }
    }
}

let tailscale = Tailscale()

func pctEncode(_ s: String) -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
}

func link(for s: Share) -> String? {
    guard tailscale.problem == nil, let id = tailscale.identity else { return nil }
    return "https://\(id.host):\(publicPort)/s/\(s.token)/\(pctEncode(s.name))"
}

// MARK: - HTTP 서버

func htmlEscape(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
}

func indexPage() -> String {
    let fmt = ByteCountFormatter()
    var rows = ""
    for s in store.all() {
        var detail: String
        if s.isArchive {
            detail = s.paths.count == 1 ? "폴더" : "\(s.paths.count)개 항목"
        } else {
            let size = (try? FileManager.default.attributesOfItem(atPath: s.paths[0])[.size] as? NSNumber)?.int64Value
            detail = size.map { fmt.string(fromByteCount: $0) } ?? "파일 없음"
        }
        let left = Int(s.expires.timeIntervalSinceNow)
        detail += " · " + (left >= 3600 ? "\(left / 3600)시간 남음" : "\(max(left / 60, 1))분 남음")
        rows += "<li><a href=\"/s/\(s.token)/\(pctEncode(s.name))\">\(htmlEscape(s.name))</a><span>\(detail)</span></li>\n"
    }
    if rows.isEmpty { rows = "<li class=\"empty\">아직 공유한 파일이 없습니다. 이 Mac의 Finder에서 파일을 복사해 보세요.</li>" }
    let host = htmlEscape(tailscale.identity?.host ?? Host.current().localizedName ?? "")
    return """
    <!doctype html><html lang="ko"><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width,initial-scale=1">
    <title>copypaste</title>
    <style>
    :root{color-scheme:light dark}
    body{font:16px/1.5 -apple-system,system-ui,sans-serif;max-width:640px;margin:48px auto;padding:0 16px}
    h1{font-size:20px;margin:0}p{margin:4px 0 24px;opacity:.6;font-size:14px}
    ul{list-style:none;padding:0;margin:0}
    li{display:flex;justify-content:space-between;gap:16px;padding:12px 0;border-top:1px solid color-mix(in srgb,currentColor 15%,transparent)}
    a{word-break:break-all;text-decoration:none;color:#0a84ff}a:hover{text-decoration:underline}
    span{flex:none;opacity:.6;font-size:14px}.empty{opacity:.6}
    </style></head><body>
    <h1>copypaste</h1><p>\(host)에서 최근 복사한 파일</p>
    <ul>
    \(rows)</ul></body></html>
    """
}

final class Conn {
    let c: NWConnection
    let q: DispatchQueue
    var buf = Data()
    var what = ""  // 로그용: "파일명 <- 요청 기기 주소"
    var gotRequest = false
    static let lock = NSLock()
    static var active = 0
    static let maxActive = 32

    init(_ c: NWConnection) {
        self.c = c
        q = DispatchQueue(label: "copypaste.conn")
    }

    func start() {
        Conn.lock.lock()
        let tooMany = Conn.active >= Conn.maxActive
        if !tooMany { Conn.active += 1 }
        Conn.lock.unlock()
        if tooMany { return c.cancel() }
        var released = false
        c.stateUpdateHandler = { state in
            switch state {
            case .cancelled, .failed:
                if !released { released = true; Conn.lock.lock(); Conn.active -= 1; Conn.lock.unlock() }
                if case .failed = state { self.c.cancel() }
            default: break
            }
        }
        c.start(queue: q)
        // 요청 헤더를 10초 안에 보내지 않는 연결은 끊는다.
        q.asyncAfter(deadline: .now() + 10) { if !self.gotRequest { self.c.cancel() } }
        read()
    }

    private func read() {
        c.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, done, err in
            if let data { self.buf.append(data) }
            if let r = self.buf.range(of: Data("\r\n\r\n".utf8)) {
                self.gotRequest = true
                self.handle(String(decoding: self.buf[..<r.lowerBound], as: UTF8.self))
            } else if done || err != nil || self.buf.count > 65536 {
                self.c.cancel()
            } else {
                self.read()
            }
        }
    }

    private func send(_ d: Data, then: @escaping () -> Void) {
        c.send(content: d, completion: .contentProcessed { err in
            if err != nil { self.c.cancel() } else { then() }
        })
    }

    private func close() {
        c.send(content: nil, contentContext: .finalMessage, isComplete: true,
               completion: .contentProcessed { _ in self.c.cancel() })
    }

    private func header(_ status: String, _ fields: [(String, String)]) -> Data {
        var s = "HTTP/1.1 \(status)\r\n"
        for (k, v) in fields + [("Connection", "close"), ("X-Content-Type-Options", "nosniff"), ("Cache-Control", "private, no-store"),
                                     ("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'"),
                                     ("Referrer-Policy", "no-referrer")] {
            s += "\(k): \(v)\r\n"
        }
        return Data((s + "\r\n").utf8)
    }

    private func text(_ status: String, _ body: String, type: String = "text/plain; charset=utf-8", headOnly: Bool = false) {
        let b = Data(body.utf8)
        var d = header(status, [("Content-Type", type), ("Content-Length", "\(b.count)")])
        if !headOnly { d.append(b) }
        send(d) { self.close() }
    }

    private func handle(_ raw: String) {
        let lines = raw.components(separatedBy: "\r\n")
        let parts = lines[0].split(separator: " ")
        guard parts.count >= 2 else { return text("400 Bad Request", "bad request\n") }
        let method = String(parts[0])
        var headers: [String: String] = [:]
        for l in lines.dropFirst() {
            guard let i = l.firstIndex(of: ":") else { continue }
            headers[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces)
        }
        guard method == "GET" || method == "HEAD" else { return text("405 Method Not Allowed", "method not allowed\n") }
        let headOnly = method == "HEAD"

        // 접근 통제 (모두 통과해야 함, 확인할 수 없으면 거부):
        // 1) Host가 이 기기의 tailnet 주소여야 한다 -> 웹페이지의 DNS 리바인딩/로컬 포트 직접 접근 차단
        // 2) tailscale serve가 붙여 주는 Tailscale-User-Login이 이 기기 소유 계정과 같아야 한다
        //    -> 같은 tailnet의 다른 사용자, 공유받은 기기, 태그 기기 차단
        guard let id = tailscale.identity, !id.login.isEmpty else {
            return text("503 Service Unavailable", "Tailscale 계정을 아직 확인하지 못했습니다.\n", headOnly: headOnly)
        }
        guard headers["host"]?.lowercased() == "\(id.host):\(publicPort)".lowercased(),
              headers["tailscale-user-login"]?.lowercased() == id.login.lowercased() else {
            return text("403 Forbidden", "이 기기의 소유 계정으로 Tailscale을 통해서만 접근할 수 있습니다.\n", headOnly: headOnly)
        }

        let path = String(parts[1].split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0])
        var comps = path.split(separator: "/").map(String.init)
        // 3) tailscale serve가 붙이는 비밀 경로로 들어온 요청만 받는다 -> 로컬 포트로 직접 온 요청 차단
        guard comps.first == upstreamSecret else {
            return text("404 Not Found", "not found\n", headOnly: headOnly)
        }
        comps.removeFirst()
        if comps.isEmpty {
            return text("200 OK", indexPage(), type: "text/html; charset=utf-8", headOnly: headOnly)
        }
        guard comps.count >= 2, comps[0] == "s", let share = store.get(comps[1]) else {
            return text("404 Not Found", "링크가 없거나 만료되었습니다.\n", headOnly: headOnly)
        }
        // 복사한 뒤에 경로가 민감한 곳을 가리키도록 바뀌었을 수 있으므로(심볼릭 링크 등) 보낼 때 다시 확인한다.
        guard !share.paths.contains(where: isSensitive) else {
            return text("404 Not Found", "링크가 없거나 만료되었습니다.\n", headOnly: headOnly)
        }
        guard share.paths.allSatisfy({ FileManager.default.fileExists(atPath: $0) }) else {
            return text("404 Not Found", "원본 파일이 이동되었거나 삭제되었습니다.\n", headOnly: headOnly)
        }
        let peer = (headers["x-forwarded-for"] ?? "?").filter { $0.isHexDigit || ".:, ".contains($0) }.prefix(64)
        what = "\(share.name) <- \(peer)"
        if !headOnly { log("다운로드 시작: \(what)") }
        let disposition = ("Content-Disposition", "attachment; filename*=UTF-8''\(pctEncode(share.name))")
        if share.isArchive {
            sendArchive(share, disposition, headOnly)
        } else {
            sendFile(share.paths[0], disposition, headers["range"], headOnly)
        }
    }

    private func sendFile(_ path: String, _ disposition: (String, String), _ range: String?, _ headOnly: Bool) {
        guard let fh = FileHandle(forReadingAtPath: path),
              let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.uint64Value else {
            return text("403 Forbidden", "파일을 읽을 수 없습니다. 이 Mac에서 copypaste의 폴더 접근 권한을 확인하세요.\n", headOnly: headOnly)
        }
        var start: UInt64 = 0
        var end: UInt64 = size == 0 ? 0 : size - 1
        var partial = false
        if let range, range.hasPrefix("bytes="), !range.contains(","), size > 0 {
            let r = range.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
            if r.count == 2 {
                if r[0].isEmpty, let n = UInt64(r[1]), n > 0 {
                    start = size > n ? size - n : 0
                    partial = true
                } else if let a = UInt64(r[0]) {
                    start = a
                    if let b = UInt64(r[1]) { end = min(b, size - 1) }
                    partial = true
                }
            }
            if partial && (start > end || start >= size) {
                try? fh.close()
                send(header("416 Range Not Satisfiable", [("Content-Range", "bytes */\(size)"), ("Content-Length", "0")])) { self.close() }
                return
            }
        }
        let length = size == 0 ? 0 : end - start + 1
        var fields = [("Content-Type", "application/octet-stream"), ("Content-Length", "\(length)"),
                      ("Accept-Ranges", "bytes"), disposition]
        if partial { fields.append(("Content-Range", "bytes \(start)-\(end)/\(size)")) }
        send(header(partial ? "206 Partial Content" : "200 OK", fields)) {
            if headOnly || length == 0 { try? fh.close(); return self.close() }
            try? fh.seek(toOffset: start)
            self.pump(fh, length)
        }
    }

    private func pump(_ fh: FileHandle, _ remaining: UInt64) {
        let n = Int(min(remaining, 1 << 20))
        guard n > 0, let chunk = try? fh.read(upToCount: n), !chunk.isEmpty else {
            try? fh.close()
            log(remaining == 0 ? "다운로드 완료: \(what)" : "다운로드 중단(파일 읽기 실패): \(what)")
            return close()
        }
        c.send(content: chunk, completion: .contentProcessed { err in
            if err != nil {
                try? fh.close()
                log("다운로드 중단(연결 끊김): \(self.what)")
                self.c.cancel()
            } else { self.pump(fh, remaining - UInt64(chunk.count)) }
        })
    }

    /// 폴더나 여러 파일은 받는 순간 zip으로 묶어 흘려보낸다 (디스크에 임시 파일을 만들지 않음).
    private func sendArchive(_ share: Share, _ disposition: (String, String), _ headOnly: Bool) {
        let fields = [("Content-Type", "application/zip"), ("Transfer-Encoding", "chunked"), disposition]
        if headOnly { return send(header("200 OK", fields)) { self.close() } }

        let parents = Set(share.paths.map { ($0 as NSString).deletingLastPathComponent })
        let cwd: String
        let names: [String]
        if parents.count == 1 {
            cwd = parents.first!
            names = share.paths.map { "./" + ($0 as NSString).lastPathComponent }
        } else {
            cwd = "/"
            names = share.paths.map { "." + $0 }
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        // 이름은 모두 "./"로 시작하므로 옵션으로 해석되지 않는다. 폴더 안의 민감한 파일은 제외한다.
        p.arguments = ["-r", "-q", "-y", "-"] + names + ["-x"] + zipExcludes
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return text("500 Internal Server Error", "zip 실행 실패\n") }
        send(header("200 OK", fields)) { self.pumpZip(p, out.fileHandleForReading) }
    }

    private func pumpZip(_ p: Process, _ fh: FileHandle) {
        let chunk = fh.availableData
        if chunk.isEmpty {
            p.waitUntilExit()
            log(p.terminationStatus == 0 ? "다운로드 완료: \(what)" : "다운로드 중단(zip 오류 \(p.terminationStatus)): \(what)")
            return send(Data("0\r\n\r\n".utf8)) { self.close() }
        }
        var framed = Data("\(String(chunk.count, radix: 16))\r\n".utf8)
        framed.append(chunk)
        framed.append(Data("\r\n".utf8))
        c.send(content: framed, completion: .contentProcessed { err in
            if err != nil { p.terminate(); self.c.cancel() } else { self.pumpZip(p, fh) }
        })
    }
}

func startServer() throws -> NWListener {
    let params = NWParameters.tcp
    params.allowLocalEndpointReuse = true
    params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: localPort)!)
    let l = try NWListener(using: params)
    l.newConnectionHandler = { Conn($0).start() }
    l.stateUpdateHandler = { state in
        if case .failed(let e) = state {
            log("서버 실패: \(e)")
            exit(1)
        }
    }
    l.start(queue: .global())
    return l
}

// MARK: - 클립보드 감시 + 메뉴 막대

/// 복사만으로 공유되면 곤란한 것들. 이런 파일은 복사해도 링크를 만들지 않는다.
/// 심볼릭 링크는 실제 위치로 풀어서 판단하고, 대소문자를 구분하지 않는다.
let sensitiveDirs = [".ssh", ".gnupg", ".aws", ".azure", ".kube", ".docker", ".config/gcloud", ".config/gh",
                     ".password-store", "Library/Keychains", "Library/Cookies",
                     "Library/Application Support/copypaste"]
let sensitiveNames: Set<String> = [".env", ".netrc", ".npmrc", ".pypirc", ".git-credentials", ".pgpass", "credentials.json"]
let sensitivePrefixes = [".env.", "id_rsa", "id_dsa", "id_ecdsa", "id_ed25519"]
let sensitiveExtensions: Set<String> = ["pem", "p12", "pfx", "keychain", "keychain-db", "kdbx", "ovpn"]

func isSensitive(_ rawPath: String) -> Bool {
    let path = URL(fileURLWithPath: rawPath).resolvingSymlinksInPath().path.lowercased()
    let home = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().path.lowercased()
    func contains(_ outer: String, _ inner: String) -> Bool {
        outer == inner || inner.hasPrefix(outer == "/" ? "/" : outer + "/")
    }
    // 홈 폴더 자체나 그 상위 폴더 전체
    if contains(path, home) { return true }
    for d in sensitiveDirs {
        let full = home + "/" + d.lowercased()
        // 민감한 폴더 안이거나, 민감한 폴더를 통째로 품은 상위 폴더(~/Library, ~/.config 등)
        if contains(full, path) || contains(path, full) { return true }
    }
    let name = (path as NSString).lastPathComponent
    // .key 는 개인 키일 수도, Keynote 문서일 수도 있다. Keynote(zip 형식 또는 폴더)만 통과시킨다.
    if (name as NSString).pathExtension == "key" {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        let magic = isDir.boolValue ? nil : FileHandle(forReadingAtPath: path).flatMap { try? $0.read(upToCount: 2) }
        if !isDir.boolValue && magic != Data("PK".utf8) { return true }
    }
    return sensitiveNames.contains(name) || sensitivePrefixes.contains(where: name.hasPrefix)
        || sensitiveExtensions.contains((name as NSString).pathExtension)
}

/// 폴더를 zip으로 묶을 때 안에 들어 있는 민감한 파일을 빼는 패턴.
let zipExcludes: [String] = sensitiveNames.sorted().map { "*/" + $0 }
    + sensitivePrefixes.map { "*/" + $0 + "*" }
    + sensitiveExtensions.sorted().map { "*." + $0 }
    + ["*/.ssh/*", "*/.gnupg/*", "*/.aws/*", "*/.kube/*"]

final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var listener: NWListener?
    var lastChange = NSPasteboard.general.changeCount
    var paused = false

    func applicationDidFinishLaunching(_ n: Notification) {
        guard checkLocation() else { return }
        migrateLegacyInstall()
        guard ensureSingleInstance() else { return }

        do { listener = try startServer() } catch {
            log("포트 \(localPort)를 열 수 없음: \(error)")
            alert("Copypaste를 시작할 수 없습니다",
                  "로컬 포트 \(localPort)를 다른 프로그램이 쓰고 있습니다.\n터미널에서 다음을 실행한 뒤 다시 여세요:\n\ndefaults write com.copypaste.agent localPort -int 48800")
            return NSApp.terminate(nil)
        }
        log("시작: Copypaste \(appVersion)")
        if #available(macOS 15.4, *) {
            // 시스템 설정 > 개인정보 보호 및 보안 > "다른 앱에서 붙여넣기"의 현재 값
            let names: [NSPasteboard.AccessBehavior: String] = [.default: "default", .ask: "ask", .alwaysAllow: "alwaysAllow", .alwaysDeny: "alwaysDeny"]
            log("클립보드 접근 설정: \(names[NSPasteboard.general.accessBehavior] ?? "unknown")")
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        refreshIcon()
        tailscale.setup()
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        let t = Timer(timeInterval: 0.4, repeats: true) { _ in self.checkPasteboard() }
        t.tolerance = 0.2 // 시스템이 깨우는 시점을 다른 작업과 묶을 수 있게 해 전력 소모를 줄인다
        RunLoop.main.add(t, forMode: .common)

        firstRunSetup()
    }

    func alert(_ title: String, _ text: String, buttons: [String] = ["확인"]) -> NSApplication.ModalResponse {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        buttons.forEach { a.addButton(withTitle: $0) }
        NSApp.activate(ignoringOtherApps: true)
        return a.runModal()
    }

    /// 디스크 이미지 안이나 임시 격리 위치에서 실행하면 자동 실행 등록이 깨지므로 먼저 옮기게 한다.
    func checkLocation() -> Bool {
        let path = Bundle.main.bundlePath
        guard path.hasPrefix("/Volumes/") || path.contains("/AppTranslocation/") else { return true }
        _ = alert("먼저 응용 프로그램 폴더로 옮겨 주세요",
                  "Copypaste 아이콘을 응용 프로그램(Applications) 폴더로 끌어다 놓은 뒤, 그곳에서 열어 주세요.")
        NSApp.terminate(nil)
        return false
    }

    /// 예전 방식(install.sh가 만든 LaunchAgent와 ~/Applications 사본)을 정리한다.
    func migrateLegacyInstall() {
        let fm = FileManager.default
        guard Bundle.main.bundlePath != legacyAppPath else { return }
        if fm.fileExists(atPath: legacyAgentPlist) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            p.arguments = ["bootout", "gui/\(getuid())/com.copypaste.agent"]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
            try? fm.removeItem(atPath: legacyAgentPlist)
            log("예전 자동 실행 설정을 정리함")
        }
        if fm.fileExists(atPath: legacyAppPath) { try? fm.removeItem(atPath: legacyAppPath) }
    }

    /// 이미 실행 중이면 조용히 끝낸다.
    func ensureSingleInstance() -> Bool {
        let me = ProcessInfo.processInfo.processIdentifier
        func others() -> [NSRunningApplication] {
            NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "com.copypaste.agent")
                .filter { $0.processIdentifier != me }
        }
        for _ in 0..<15 where !others().isEmpty { usleep(200_000) } // 방금 내린 예전 버전이 끝나길 잠깐 기다림
        guard others().isEmpty else {
            NSApp.terminate(nil)
            return false
        }
        return true
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do { if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
            catch { log("로그인 시 자동 실행 설정 실패: \(error.localizedDescription)") }
        }
    }

    /// 처음 실행할 때: 로그인 시 자동 실행을 켜고, 창이 없는 앱이라 어디 있는지 알려 준다.
    func firstRunSetup() {
        guard !UserDefaults.standard.bool(forKey: "didFirstRun") else { return }
        UserDefaults.standard.set(true, forKey: "didFirstRun")
        launchAtLogin = true
        _ = alert("Copypaste가 메뉴 막대에서 실행 중입니다",
                  "Finder에서 파일을 복사(⌘C)하면 같은 Tailscale 계정의 기기에서만 열리는 다운로드 링크가 클립보드에 함께 들어갑니다.\n\n화면 위쪽 메뉴 막대의 링크 아이콘에서 일시 정지, 자동 실행, 제거를 할 수 있습니다.")
    }

    func refreshIcon() {
        guard statusItem != nil else { return }
        setIcon(tailscale.problem != nil ? "exclamationmark.triangle" : paused ? "pause.circle" : "link")
    }

    func setIcon(_ symbol: String) {
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "copypaste")
    }

    func checkPasteboard() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChange else { return }
        lastChange = pb.changeCount
        let seen = pb.changeCount
        guard !paused, let items = pb.pasteboardItems, !items.isEmpty else { return }
        let allTypes = Set(items.flatMap { $0.types.map(\.rawValue) })
        // 우리가 이미 처리한 것, 비밀번호 관리자 등이 "기록하지 말라"고 표시한 것은 건드리지 않는다.
        if allTypes.contains(markerType.rawValue) || allTypes.contains(where: { $0.hasPrefix("org.nspasteboard.") }) { return }

        // 모든 항목이 파일일 때만(= 순수한 파일 복사) 처리한다. 텍스트·이미지 복사는 그대로 둔다.
        var paths: [String] = []
        for it in items {
            guard let s = it.string(forType: .fileURL), let u = URL(string: s), u.isFileURL,
                  let p = (u as NSURL).filePathURL?.standardizedFileURL.path else { return }
            paths.append(p)
        }
        log("파일 복사 감지: \(paths.count)개")
        if let blocked = paths.first(where: isSensitive) {
            return log("민감한 경로라 공유하지 않음: \((blocked as NSString).lastPathComponent)")
        }
        if let problem = tailscale.problem { return log("링크를 만들지 않음: \(problem)") }

        // 파일 정보는 그대로 두고 텍스트만 링크로 바꾼다.
        // -> Finder에 붙여넣으면 파일, 텍스트 칸에 붙여넣으면 링크.
        // 원본 데이터를 하나라도 읽지 못하면 클립보드를 건드리지 않는다.
        let textTypes: Set<String> = ["public.utf8-plain-text", "public.utf16-plain-text",
                                      "public.utf16-external-plain-text", "NSStringPboardType"]
        var copied: [[(NSPasteboard.PasteboardType, Data)]] = []
        for it in items {
            var one: [(NSPasteboard.PasteboardType, Data)] = []
            for t in it.types where !textTypes.contains(t.rawValue) {
                guard let d = it.data(forType: t) else { return log("클립보드 형식 \(t.rawValue)을 읽지 못해 그대로 둠") }
                one.append((t, d))
            }
            copied.append(one)
        }
        // 읽는 사이에 사용자가 다른 것을 복사했다면 덮어쓰지 않는다.
        guard pb.changeCount == seen else { return log("읽는 사이 클립보드가 바뀌어 건드리지 않음") }

        let share = store.add(paths: paths)
        guard let url = link(for: share) else { return }
        var rebuilt: [NSPasteboardItem] = []
        for (i, one) in copied.enumerated() {
            let n = NSPasteboardItem()
            for (t, d) in one { n.setData(d, forType: t) }
            if i == 0 {
                n.setString(url, forType: .string)
                n.setString("1", forType: markerType)
            }
            rebuilt.append(n)
        }
        pb.clearContents()
        pb.writeObjects(rebuilt)
        lastChange = pb.changeCount
        log("공유: \(share.name)")

        setIcon("checkmark.circle.fill")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { self.refreshIcon() }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if let problem = tailscale.problem {
            menu.addItem(withTitle: "⚠︎ " + problem, action: nil, keyEquivalent: "")
            menu.addItem(withTitle: "로그 보기", action: #selector(openLog), keyEquivalent: "").target = self
        } else {
            menu.addItem(withTitle: tailscale.identity?.host ?? "", action: nil, keyEquivalent: "")
        }
        menu.addItem(.separator())
        let shares = store.all().prefix(8)
        if shares.isEmpty {
            menu.addItem(withTitle: "Finder에서 파일을 복사하면 링크가 만들어집니다", action: nil, keyEquivalent: "")
        } else {
            menu.addItem(withTitle: "최근 공유 (누르면 링크만 복사)", action: nil, keyEquivalent: "")
            for s in shares {
                let it = menu.addItem(withTitle: s.name, action: #selector(copyLink(_:)), keyEquivalent: "")
                it.target = self
                it.representedObject = s.token
            }
        }
        menu.addItem(.separator())
        let pause = menu.addItem(withTitle: "일시 정지", action: #selector(togglePause), keyEquivalent: "")
        pause.target = self
        pause.state = paused ? .on : .off
        menu.addItem(withTitle: "공유 목록 페이지 열기", action: #selector(openIndex), keyEquivalent: "").target = self
        menu.addItem(withTitle: "모든 공유 링크 끊기", action: #selector(clearAll), keyEquivalent: "").target = self
        menu.addItem(.separator())
        let login = menu.addItem(withTitle: "로그인 시 자동 실행", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = launchAtLogin ? .on : .off
        menu.addItem(withTitle: "Copypaste 제거…", action: #selector(uninstall), keyEquivalent: "").target = self
        menu.addItem(withTitle: "버전 \(appVersion)", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "종료", action: #selector(quit), keyEquivalent: "q").target = self
    }

    @objc func copyLink(_ sender: NSMenuItem) {
        guard let token = sender.representedObject as? String, let s = store.get(token), let url = link(for: s) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(url, forType: .string)
        lastChange = pb.changeCount
    }

    @objc func togglePause() {
        paused.toggle()
        refreshIcon()
    }

    @objc func openIndex() {
        guard let id = tailscale.identity, let u = URL(string: "https://\(id.host):\(publicPort)/") else { return }
        NSWorkspace.shared.open(u)
    }

    @objc func toggleLogin() { launchAtLogin.toggle() }

    /// 남기는 것 없이 지운다: 자동 실행, tailscale serve 설정, 공유 목록·비밀 값, 설정, 앱 자체(휴지통으로).
    @objc func uninstall() {
        let r = alert("Copypaste를 제거할까요?",
                      "자동 실행 등록, Tailscale 공유 설정, 공유 목록을 지우고 앱을 휴지통으로 옮깁니다. 만들어 둔 링크는 모두 끊깁니다.",
                      buttons: ["제거", "취소"])
        guard r == .alertFirstButtonReturn else { return }
        listener?.cancel()
        App.removeEverything()
        NSApp.terminate(nil)
    }

    /// 메뉴의 "제거"와 `copypaste --uninstall` 이 함께 쓴다.
    static func removeEverything() {
        try? SMAppService.mainApp.unregister()
        tailscale.removeServe()
        let fm = FileManager.default
        try? fm.removeItem(at: fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("copypaste"))
        if let id = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: id) }
        try? fm.removeItem(atPath: logPath)
        try? fm.trashItem(at: Bundle.main.bundleURL, resultingItemURL: nil)
    }

    @objc func openLog() {
        NSWorkspace.shared.open(URL(fileURLWithPath: logPath))
    }

    @objc func clearAll() { store.clear() }

    @objc func quit() { NSApp.terminate(nil) }
}

// 터미널에서 확인 없이 제거: /Applications/Copypaste.app/Contents/MacOS/copypaste --uninstall
if CommandLine.arguments.contains("--uninstall") {
    let me = ProcessInfo.processInfo.processIdentifier
    NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "com.copypaste.agent")
        .filter { $0.processIdentifier != me }.forEach { $0.terminate() }
    usleep(800_000)
    App.removeEverything()
    print("Copypaste를 제거했습니다.")
    exit(0)
}

trimLog()
let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
