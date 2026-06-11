// RecoveryKit GUI — discovers recovery methods in RecoveryKit/methods/,
// collects job parameters, runs the chosen method in Terminal (sudo +
// live ddrescue output belong there), and tails the job log.
import AppKit

struct Method {
    let path: String
    let name: String
    let desc: String
}

struct SourceDisk {
    let id: String      // whole-disk identifier, e.g. "disk4"
    let title: String   // "disk4 — 251.0 GB — APPLE SSD SM0256L"
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    let methodPopup = NSPopUpButton()
    let sourcePopup = NSPopUpButton()
    let destPopup = NSPopUpButton()
    let labelField = NSTextField()
    let argsField = NSTextField()
    let descLabel = NSTextField(wrappingLabelWithString: "")
    let statusLabel = NSTextField(labelWithString: "Ready.")
    var logView: NSTextView!
    var methods: [Method] = []
    var sources: [SourceDisk] = []
    var timer: Timer?
    var tick = 0

    // The kit root is wherever the .app lives; fall back to the standard spot.
    var kitDir: String {
        let parent = URL(fileURLWithPath: Bundle.main.bundlePath)
            .deletingLastPathComponent().path
        if FileManager.default.fileExists(atPath: parent + "/methods") {
            return parent
        }
        return NSHomeDirectory() + "/RecoveryKit"
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        buildMenu()
        buildWindow()
        reload()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.refreshLog()
            self.tick += 1
            if self.tick % 5 == 0 { self.rescanSources() }  // pick up disks as they appear
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }

    func buildMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit RecoveryKit",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        NSApp.mainMenu = mainMenu
    }

    func row(_ title: String, _ control: NSView) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.widthAnchor.constraint(equalToConstant: 110).isActive = true
        let stack = NSStackView(views: [label, control])
        stack.orientation = .horizontal
        stack.spacing = 8
        return stack
    }

    func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 600),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "RecoveryKit"
        window.center()

        methodPopup.target = self
        methodPopup.action = #selector(methodChanged)
        destPopup.target = self
        destPopup.action = #selector(destChanged)

        labelField.stringValue = defaultLabel()
        labelField.placeholderString = "file basename for image/map/log"
        argsField.placeholderString = "extra args, e.g. --size-gb 251 --yes"

        descLabel.textColor = .secondaryLabelColor
        descLabel.font = NSFont.systemFont(ofSize: 11)

        let runBtn = NSButton(title: "Run in Terminal", target: self, action: #selector(runClicked))
        runBtn.bezelStyle = .rounded
        runBtn.keyEquivalent = "\r"
        let refreshBtn = NSButton(title: "Refresh", target: self, action: #selector(refreshClicked))
        refreshBtn.bezelStyle = .rounded
        let buttons = NSStackView(views: [runBtn, refreshBtn, statusLabel])
        buttons.orientation = .horizontal
        buttons.spacing = 12

        let scroll = NSTextView.scrollableTextView()
        logView = (scroll.documentView as! NSTextView)
        logView.isEditable = false
        logView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true

        let stack = NSStackView(views: [
            row("Method:", methodPopup),
            descLabel,
            row("Source disk:", sourcePopup),
            row("Destination:", destPopup),
            row("Job label:", labelField),
            row("Extra args:", argsField),
            buttons,
            NSTextField(labelWithString: "Job log:"),
            scroll,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = window.contentView!
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            methodPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 380),
            sourcePopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 380),
            destPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 380),
            labelField.widthAnchor.constraint(greaterThanOrEqualToConstant: 380),
            argsField.widthAnchor.constraint(greaterThanOrEqualToConstant: 380),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            descLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func defaultLabel() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd"
        return "rescue_" + f.string(from: Date())
    }

    // Methods are *.sh files with "# NAME:" / "# DESC:" headers.
    func scanMethods() -> [Method] {
        let dir = kitDir + "/methods"
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        return files.filter { $0.hasSuffix(".sh") }.sorted().compactMap { f in
            let path = dir + "/" + f
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
            var name = f, desc = ""
            for line in text.split(separator: "\n").prefix(12) {
                if line.hasPrefix("# NAME:") {
                    name = line.dropFirst(7).trimmingCharacters(in: .whitespaces)
                }
                if line.hasPrefix("# DESC:") {
                    desc = line.dropFirst(7).trimmingCharacters(in: .whitespaces)
                }
            }
            return Method(path: path, name: name, desc: desc)
        }
    }

    func diskutilPlist(_ args: [String]) -> [String: Any]? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil))
            as? [String: Any]
    }

    func wholeDisk(_ s: String) -> String {
        s.replacingOccurrences(of: #"(s\d+)+$"#, with: "", options: .regularExpression)
    }

    // Whole disks backing a mounted volume (its own disk + APFS physical stores),
    // so the destination drive never gets offered as a source.
    func backingDisks(of mount: String) -> Set<String> {
        guard let d = diskutilPlist(["info", "-plist", mount]) else { return [] }
        var ids: [String] = []
        if let pw = d["ParentWholeDisk"] as? String { ids.append(pw) }
        if let stores = d["APFSPhysicalStores"] as? [[String: Any]] {
            for e in stores {
                for v in e.values { if let s = v as? String { ids.append(s) } }
            }
        }
        return Set(ids.map { wholeDisk($0) })
    }

    func rescanSources() {
        var excl: Set<String> = []
        if let destName = destPopup.titleOfSelectedItem {
            excl = backingDisks(of: "/Volumes/" + destName)
        }
        var list: [SourceDisk] = []
        if let l = diskutilPlist(["list", "-plist", "external", "physical"]),
           let wd = l["WholeDisks"] as? [String] {
            for id in wd where !excl.contains(id) {
                guard let info = diskutilPlist(["info", "-plist", id]) else { continue }
                let size = (info["TotalSize"] as? NSNumber)?.doubleValue ?? 0
                let name = (info["MediaName"] as? String) ?? "?"
                list.append(SourceDisk(
                    id: id,
                    title: String(format: "%@ — %.1f GB — %@", id, size / 1e9, name)))
            }
        }
        let titles = ["Auto-detect (wait for disk to appear)"] + list.map { $0.title }
        guard titles != sourcePopup.itemTitles else { return }
        let keep = selectedSourceID()
        sources = list
        sourcePopup.removeAllItems()
        sourcePopup.addItems(withTitles: titles)
        if let keep = keep, let idx = sources.firstIndex(where: { $0.id == keep }) {
            sourcePopup.selectItem(at: idx + 1)
        }
    }

    func selectedSourceID() -> String? {
        let i = sourcePopup.indexOfSelectedItem
        guard i >= 1, i - 1 < sources.count else { return nil }  // 0 = auto-detect
        return sources[i - 1].id
    }

    @objc func destChanged() { rescanSources() }

    func scanDests() -> [String] {
        let vols = (try? FileManager.default.contentsOfDirectory(atPath: "/Volumes")) ?? []
        return vols.filter { !$0.hasPrefix(".") }.sorted()
    }

    @objc func refreshClicked() { reload() }

    func reload() {
        methods = scanMethods()
        methodPopup.removeAllItems()
        methodPopup.addItems(withTitles: methods.map { $0.name })
        let dests = scanDests()
        destPopup.removeAllItems()
        destPopup.addItems(withTitles: dests)
        // Preselect the first volume that is not part of the boot system.
        if let job = dests.firstIndex(where: { $0 != "Macintosh HD" && $0 != "Data" }) {
            destPopup.selectItem(at: job)
        }
        methodChanged()
        rescanSources()
        statusLabel.stringValue =
            "\(methods.count) methods, \(sources.count) source disks, \(dests.count) volumes."
    }

    @objc func methodChanged() {
        let i = methodPopup.indexOfSelectedItem
        descLabel.stringValue = (i >= 0 && i < methods.count) ? methods[i].desc : ""
    }

    func shq(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    @objc func runClicked() {
        let i = methodPopup.indexOfSelectedItem
        guard i >= 0, i < methods.count else { return }
        guard let destName = destPopup.titleOfSelectedItem else {
            statusLabel.stringValue = "Pick a destination volume."
            return
        }
        let dest = "/Volumes/" + destName
        let label = labelField.stringValue.isEmpty ? defaultLabel() : labelField.stringValue
        var cmd = "sudo bash \(shq(methods[i].path)) --dest \(shq(dest)) --label \(shq(label))"
        if let src = selectedSourceID() { cmd += " --device " + src }
        let extra = argsField.stringValue.trimmingCharacters(in: .whitespaces)
        if !extra.isEmpty { cmd += " " + extra }

        let asEscaped = cmd
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "tell application \"Terminal\"\nactivate\ndo script \"\(asEscaped)\"\nend tell"
        var err: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&err)
        if let err = err {
            statusLabel.stringValue = "Terminal launch failed: \(err["NSAppleScriptErrorBriefMessage"] ?? "?")"
        } else {
            statusLabel.stringValue = "Running '\(methods[i].name)' — enter password in Terminal."
        }
    }

    func refreshLog() {
        guard let destName = destPopup.titleOfSelectedItem else { return }
        let label = labelField.stringValue.isEmpty ? defaultLabel() : labelField.stringValue
        let base = "/Volumes/\(destName)/\(label)"
        var text = ""
        for suffix in [".log", ".extract.log"] {
            if let t = try? String(contentsOfFile: base + suffix, encoding: .utf8), !t.isEmpty {
                text += "──── \(label + suffix) ────\n" + String(t.suffix(5000)) + "\n"
            }
        }
        if text.isEmpty { return }
        if logView.string != text {
            logView.string = text
            logView.scrollToEndOfDocument(nil)
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
