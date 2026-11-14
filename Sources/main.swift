// copypaste — Finder에서 파일을 복사하면 tailnet 전용 공유 링크를 클립보드에 덧붙인다.
//
// 구성: (1) 클립보드 감시  (2) 공유 목록 저장소  (3) 127.0.0.1 HTTP 서버  (4) 메뉴 막대
// 외부 노출은 `tailscale serve`가 맡는다: https://<기기>.ts.net:8765 -> 127.0.0.1:48765

import AppKit
import Network

// MARK: - 설정

let env = ProcessInfo.processInfo.environment
let localPort = UInt16(env["COPYPASTE_LOCAL_PORT"] ?? "") ?? 48765
let publicPort = UInt16(env["COPYPASTE_PORT"] ?? "") ?? 8765
let shareTTL: TimeInterval = (Double(env["COPYPASTE_TTL_HOURS"] ?? "") ?? 24) * 3600
let markerType = NSPasteboard.PasteboardType("com.copypaste.marker")

func log(_ s: String) {
    FileHandle.standardError.write("[\(ISO8601DateFormatter().string(from: Date()))] \(s)\n".data(using: .utf8)!)
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
        let d = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, d)
    }

    /// 이 포트에 이미 다른 serve 설정이 있으면 절대 덮어쓰지 않는다.
    private func ensureServe(host: String) {
        let base = "http://127.0.0.1:\(localPort)"
        let target = base + "/" + upstreamSecret
        let (sc, sd) = run(["serve", "status", "--json"])
        guard sc == 0 else { return log("tailscale serve 상태를 읽지 못해 설정을 건드리지 않음") }
        let cfg = (try? JSONSerialization.jsonObject(with: sd) as? [String: Any]) ?? [:]
        let tcp = cfg["TCP"] as? [String: Any] ?? [:]
        let web = cfg["Web"] as? [String: Any] ?? [:]
        if tcp["\(publicPort)"] != nil {
            let handlers = (web["\(host):\(publicPort)"] as? [String: Any])?["Handlers"] as? [String: Any] ?? [:]
            let proxy = handlers.count == 1 ? (handlers["/"] as? [String: Any])?["Proxy"] as? String : nil
            if proxy == target { return }
            // 우리 로컬 포트를 가리키는 예전 설정(비밀 경로 없음/바뀜)만 갱신하고, 남의 설정은 건드리지 않는다.
            guard let proxy, proxy == base || proxy.hasPrefix(base + "/") else {
                return log("포트 \(publicPort)에 이미 다른 tailscale serve 설정이 있어 건드리지 않음. COPYPASTE_PORT로 다른 포트를 지정하세요.")
            }
        }
        let (c, out) = run(["serve", "--bg", "--https=\(publicPort)", target])
        if c != 0 { log("tailscale serve 실패: \(String(data: out, encoding: .utf8) ?? "")") }
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
                self.lock.lock(); self._identity = Identity(host: dns, login: login); self.lock.unlock()
                log("tailscale: \(dns) (\(login))")
                self.ensureServe(host: dns)
            } else {
                let msg = String(decoding: data.prefix(200), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                log("tailscale 상태를 읽지 못함(\(self.binary ?? "실행 파일 없음"), 종료 코드 \(code)): \(msg) — 30초 뒤 재시도")
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
    guard let id = tailscale.identity else { return nil }
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
            exit(1) // launchd가 다시 띄운다
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
        do { listener = try startServer() } catch {
            log("포트 \(localPort)를 열 수 없음: \(error)")
            exit(1)
        }
        tailscale.setup()
        if #available(macOS 15.4, *) {
            // 시스템 설정 > 개인정보 보호 및 보안 > "다른 앱에서 붙여넣기"의 현재 값
            let names: [NSPasteboard.AccessBehavior: String] = [.default: "default", .ask: "ask", .alwaysAllow: "alwaysAllow", .alwaysDeny: "alwaysDeny"]
            log("클립보드 접근 설정: \(names[NSPasteboard.general.accessBehavior] ?? "unknown")")
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setIcon("link")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        let t = Timer(timeInterval: 0.4, repeats: true) { _ in self.checkPasteboard() }
        RunLoop.main.add(t, forMode: .common)
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
        guard tailscale.identity != nil else { return log("Tailscale 기기 이름을 아직 몰라 링크를 만들지 않음") }

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
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { self.setIcon(self.paused ? "pause.circle" : "link") }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let host = tailscale.identity?.host ?? "Tailscale 연결 확인 중…"
        menu.addItem(withTitle: host, action: nil, keyEquivalent: "")
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
        setIcon(paused ? "pause.circle" : "link")
    }

    @objc func openIndex() {
        guard let id = tailscale.identity, let u = URL(string: "https://\(id.host):\(publicPort)/") else { return }
        NSWorkspace.shared.open(u)
    }

    @objc func clearAll() { store.clear() }

    @objc func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
