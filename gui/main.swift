// RecoveryKit GUI — discovers recovery methods in RecoveryKit/methods/,
// collects job parameters, runs the chosen method in Terminal (sudo +
// live ddrescue output belong there), and tails the job log.
import AppKit

struct Method {
    let path: String
    let name: String
    let desc: String
    let acceptsImage: Bool   // declared via "# ACCEPTS: image" header
}

struct SourceDisk {
    let id: String      // whole-disk identifier, e.g. "disk4"
    let title: String   // "disk4 — 251.0 GB — APPLE SSD SM0256L"
    let size: Int64     // bytes at scan time, revalidated before Run
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    let methodPopup = NSPopUpButton()
    let sourcePopup = NSPopUpButton()
    let destPopup = NSPopUpButton()
    let jobPopup = NSPopUpButton()
    let labelField = NSTextField()
    let imageField = NSTextField()
    let browseBtn = NSButton()
    let argsField = NSTextField()
    let descLabel = NSTextField(wrappingLabelWithString: "")
    let statusLabel = NSTextField(labelWithString: "Ready.")
    let stateLabel = NSTextField(labelWithString: "Job state: —")
    let suggestLabel = NSTextField(wrappingLabelWithString: "")
    let suggestBtn = NSButton()
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
            if self.tick % 3 == 0 { self.refreshJobState() }
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
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 700),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "RecoveryKit"
        window.center()

        methodPopup.target = self
        methodPopup.action = #selector(methodChanged)
        destPopup.target = self
        destPopup.action = #selector(destChanged)
        sourcePopup.target = self
        sourcePopup.action = #selector(sourceChanged)
        jobPopup.target = self
        jobPopup.action = #selector(jobChanged)

        methodPopup.toolTip = "Recovery methods, numbered in workflow order"
        sourcePopup.toolTip = "The failing drive. Leave on Auto-detect if it isn't enumerated yet"
        destPopup.toolTip = "The job drive that receives images and recovered files — never the patient"
        jobPopup.toolTip = "Continue an existing job on this drive, or start a new one"
        labelField.toolTip = "Basename for this job's image/map/log files"
        imageField.toolTip = "Only for extract/carve/verify: a specific .img to work on"
        argsField.toolTip = "Extra flags passed to the method, e.g. --size-gb 251"

        labelField.stringValue = defaultLabel()
        labelField.placeholderString = "file basename for image/map/log"
        imageField.placeholderString = "optional .img for Extract/Carve — blank uses <label>.img"
        argsField.placeholderString = "extra args, e.g. --size-gb 251 --yes"

        browseBtn.title = "Browse…"
        browseBtn.target = self
        browseBtn.action = #selector(browseImage)
        browseBtn.bezelStyle = .rounded
        let imageRow = NSStackView(views: [imageField, browseBtn])
        imageRow.orientation = .horizontal
        imageRow.spacing = 8

        descLabel.textColor = .secondaryLabelColor
        descLabel.font = NSFont.systemFont(ofSize: 11)

        let runBtn = NSButton(title: "Run in Terminal", target: self, action: #selector(runClicked))
        runBtn.bezelStyle = .rounded
        runBtn.keyEquivalent = "\r"
        runBtn.toolTip = "Shows a pre-flight summary with warnings before anything runs"
        let refreshBtn = NSButton(title: "Refresh", target: self, action: #selector(refreshClicked))
        refreshBtn.bezelStyle = .rounded
        let buttons = NSStackView(views: [runBtn, refreshBtn, statusLabel])
        buttons.orientation = .horizontal
        buttons.spacing = 12

        stateLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        stateLabel.textColor = .secondaryLabelColor
        suggestLabel.font = NSFont.boldSystemFont(ofSize: 12)
        suggestBtn.title = "Select suggested"
        suggestBtn.target = self
        suggestBtn.action = #selector(useSuggested)
        suggestBtn.bezelStyle = .rounded
        suggestBtn.toolTip = "Pick the suggested method in the Method menu"
        let suggestRow = NSStackView(views: [suggestLabel, suggestBtn])
        suggestRow.orientation = .horizontal
        suggestRow.spacing = 8

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
            row("Job:", jobPopup),
            row("Job label:", labelField),
            row("Image file:", imageRow),
            row("Extra args:", argsField),
            buttons,
            stateLabel,
            suggestRow,
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
            jobPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 380),
            stateLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            suggestLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 460),
            labelField.widthAnchor.constraint(greaterThanOrEqualToConstant: 380),
            imageField.widthAnchor.constraint(greaterThanOrEqualToConstant: 300),
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
            var accepts = false
            for line in text.split(separator: "\n").prefix(12) {
                if line.hasPrefix("# NAME:") {
                    name = line.dropFirst(7).trimmingCharacters(in: .whitespaces)
                }
                if line.hasPrefix("# DESC:") {
                    desc = line.dropFirst(7).trimmingCharacters(in: .whitespaces)
                }
                if line.hasPrefix("# ACCEPTS:"), line.contains("image") {
                    accepts = true
                }
            }
            return Method(path: path, name: name, desc: desc, acceptsImage: accepts)
        }
    }

    func diskutilPlist(_ args: [String]) -> [String: Any]? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice   // an unread Pipe can fill and deadlock
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
                    title: String(format: "%@ — %.1f GB — %@", id, size / 1e9, name),
                    size: Int64(size)))
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

    @objc func destChanged() { rescanSources(); rescanJobs() }
    @objc func sourceChanged() { rescanDests() }

    // ---- Job awareness: existing jobs, pipeline state, suggested next step ----

    var destPath: String? {
        destPopup.titleOfSelectedItem.map { "/Volumes/" + $0 }
    }
    var currentLabel: String {
        labelField.stringValue.isEmpty ? defaultLabel() : labelField.stringValue
    }

    // Jobs already on the job drive, newest first (from their .img/.map/.target).
    func scanJobs() -> [String] {
        guard let dir = destPath else { return [] }
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: dir) else { return [] }
        var seen = Set<String>()
        var jobs: [(String, Date)] = []
        for f in files {
            for suf in [".img", ".map", ".target"] where f.hasSuffix(suf) {
                let label = String(f.dropLast(suf.count))
                guard !label.isEmpty, !seen.contains(label) else { continue }
                seen.insert(label)
                let m = (try? fm.attributesOfItem(atPath: dir + "/" + f))?[.modificationDate] as? Date
                jobs.append((label, m ?? .distantPast))
            }
        }
        return jobs.sorted { $0.1 > $1.1 }.map { $0.0 }
    }

    func uniqueNewLabel() -> String {
        guard let dir = destPath else { return defaultLabel() }
        let fm = FileManager.default
        let base = defaultLabel()
        var label = base
        var i = 1
        while fm.fileExists(atPath: "\(dir)/\(label).img")
            || fm.fileExists(atPath: "\(dir)/\(label).target")
            || fm.fileExists(atPath: "\(dir)/\(label).log") {
            i += 1
            label = "\(base)_\(i)"
        }
        return label
    }

    func rescanJobs() {
        let jobs = scanJobs()
        jobPopup.removeAllItems()
        jobPopup.addItem(withTitle: "— new job —")
        jobPopup.addItems(withTitles: jobs)
        if !jobs.isEmpty {
            jobPopup.selectItem(at: 1)          // continue the most recent job
            labelField.stringValue = jobs[0]
        } else {
            labelField.stringValue = uniqueNewLabel()
        }
        refreshJobState()
    }

    @objc func jobChanged() {
        if jobPopup.indexOfSelectedItem <= 0 {
            labelField.stringValue = uniqueNewLabel()
        } else if let t = jobPopup.titleOfSelectedItem {
            labelField.stringValue = t
        }
        refreshJobState()
    }

    struct JobState {
        var img = false, sha = false, map = false
        var imgBytes: Int64 = 0
        var carved = false, extracted = false, triage = false
        var delivery = false, report = false, active = false
    }

    func jobState() -> JobState {
        var s = JobState()
        guard let dir = destPath else { return s }
        let fm = FileManager.default
        let base = "\(dir)/\(currentLabel)"
        s.img = fm.fileExists(atPath: base + ".img")
        if s.img {
            s.imgBytes = ((try? fm.attributesOfItem(atPath: base + ".img"))?[.size] as? NSNumber)?.int64Value ?? 0
        }
        s.sha = fm.fileExists(atPath: base + ".img.sha256")
        s.map = fm.fileExists(atPath: base + ".map")
        s.carved = fm.fileExists(atPath: dir + "/carved")
        s.extracted = fm.fileExists(atPath: dir + "/extracted") || fm.fileExists(atPath: dir + "/tsk_extracted")
        s.triage = fm.fileExists(atPath: dir + "/triage")
        s.delivery = fm.fileExists(atPath: dir + "/delivery_" + currentLabel)
        s.report = fm.fileExists(atPath: base + ".report.txt")
        s.active = fm.fileExists(atPath: base + ".lock") || fm.fileExists(atPath: base + ".triage.lock")
        return s
    }

    func suggestion(for s: JobState) -> (prefix: String, why: String) {
        if s.active { return ("", "a run for this job is ACTIVE — watch the log below") }
        if !s.img { return ("10", "no image yet — image the failing disk (run 05 Probe first if the drive is in doubt)") }
        if !s.sha { return ("15", "image has no recorded hash — verify it before working from it") }
        if !s.extracted && !s.carved { return ("25", "recover files from the image — no-mount extraction is the safe default") }
        if s.carved && !s.triage { return ("40", "carve output exists — triage it into user data vs junk") }
        if !s.delivery { return ("60", "package the customer delivery (45 photo-sort / 35 dedupe are optional before this)") }
        if !s.report { return ("70", "generate the final job report") }
        return ("80", "job looks complete — archive the image and artifacts off the bench")
    }

    func refreshJobState() {
        let s = jobState()
        var bits: [String] = []
        bits.append(s.img
            ? String(format: "image ✓ %.1f GB%@", Double(s.imgBytes) / 1e9, s.sha ? " (hash ✓)" : "")
            : "image —")
        bits.append(s.extracted ? "extracted ✓" : (s.carved ? "carved ✓" : "files —"))
        bits.append(s.triage ? "triage ✓" : "triage —")
        bits.append(s.delivery ? "delivery ✓" : "delivery —")
        if s.active { bits.append("⚙️ RUN ACTIVE") }
        stateLabel.stringValue = "Job state: " + bits.joined(separator: "  ·  ")
        let sug = suggestion(for: s)
        suggestLabel.stringValue = "Next: " + sug.why
        suggestBtn.isEnabled = !sug.prefix.isEmpty
    }

    @objc func useSuggested() {
        let sug = suggestion(for: jobState())
        guard !sug.prefix.isEmpty else { return }
        if let idx = methods.firstIndex(where: {
            URL(fileURLWithPath: $0.path).lastPathComponent.hasPrefix(sug.prefix + "_")
        }) {
            methodPopup.selectItem(at: idx)
            methodChanged()
        }
    }

    // Destinations are writable volumes only (patient mounts are read-only by
    // doctrine) and never a volume backed by the selected source disk — the
    // image must not land on the patient.
    func scanDests() -> [String] {
        let fm = FileManager.default
        let vols = (try? fm.contentsOfDirectory(atPath: "/Volumes")) ?? []
        let src = selectedSourceID()
        return vols.filter { v in
            guard !v.hasPrefix(".") else { return false }
            let p = "/Volumes/" + v
            guard fm.isWritableFile(atPath: p) else { return false }
            if let src = src, backingDisks(of: p).contains(src) { return false }
            return true
        }.sorted()
    }

    func rescanDests() {
        let keep = destPopup.titleOfSelectedItem
        let dests = scanDests()
        destPopup.removeAllItems()
        destPopup.addItems(withTitles: dests)
        if let keep = keep, dests.contains(keep) {
            destPopup.selectItem(withTitle: keep)
        } else if let job = dests.firstIndex(where: { $0 != "Macintosh HD" && $0 != "Data" }) {
            destPopup.selectItem(at: job)
        }
    }

    @objc func browseImage() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a recovered disk image (.img) to extract or carve"
        // Start in the selected destination volume, where images are written.
        if let destName = destPopup.titleOfSelectedItem {
            panel.directoryURL = URL(fileURLWithPath: "/Volumes/" + destName)
        }
        if panel.runModal() == .OK, let url = panel.url {
            imageField.stringValue = url.path
        }
    }

    @objc func refreshClicked() { reload() }

    func reload() {
        methods = scanMethods()
        methodPopup.removeAllItems()
        // NSPopUpButton silently DROPS duplicate titles, desyncing index from
        // the methods array — disambiguate before adding.
        var seen: [String: Int] = [:]
        for m in methods {
            // Lead with the workflow number so the menu reads as a pipeline.
            let nn = String(URL(fileURLWithPath: m.path).lastPathComponent.prefix(2))
            let base = nn.allSatisfy({ $0.isNumber }) ? "\(nn) · \(m.name)" : m.name
            let c = (seen[base] ?? 0) + 1
            seen[base] = c
            methodPopup.addItem(withTitle: c == 1 ? base : "\(base) (\(c))")
        }
        rescanDests()
        rescanJobs()
        methodChanged()
        rescanSources()
        statusLabel.stringValue =
            "\(methods.count) methods, \(sources.count) source disks, \(destPopup.numberOfItems) volumes."
    }

    @objc func methodChanged() {
        let i = methodPopup.indexOfSelectedItem
        let m = (i >= 0 && i < methods.count) ? methods[i] : nil
        descLabel.stringValue = m?.desc ?? ""
        let wantsImage = m?.acceptsImage ?? false
        imageField.isEnabled = wantsImage
        browseBtn.isEnabled = wantsImage
        if !wantsImage { imageField.stringValue = "" }
    }

    func shq(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    func cleaned(_ s: String) -> String {
        s.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    func setStatus(_ s: String, error: Bool = false) {
        statusLabel.stringValue = s
        statusLabel.textColor = error ? .systemRed : .labelColor
    }

    func freeBytes(at path: String) -> Int64 {
        ((try? FileManager.default.attributesOfFileSystem(forPath: path))?[.systemFreeSize]
            as? NSNumber)?.int64Value ?? -1
    }

    func gb(_ b: Int64) -> String { String(format: "%.1f GB", Double(b) / 1e9) }

    // Pre-flight: a human-readable plan plus computed warnings. Returns false
    // to abort, and shows blocking problems instead of letting them run.
    func preflight(_ m: Method, dest: String, label: String,
                   srcID: String?, srcSize: Int64, image: String) -> Bool {
        let mfile = URL(fileURLWithPath: m.path).lastPathComponent
        let state = jobState()
        var lines = ["Method:  \(m.name)",
                     "Job:     \(label)",
                     "Dest:    \(dest)  (\(gb(freeBytes(at: dest))) free)"]
        var warns: [String] = []

        if state.active {
            warns.append("A run for this job appears ACTIVE (lock present). Two runs on one job corrupt it.")
        }

        if mfile.hasPrefix("10_") {
            lines.append("Source:  " + (srcID.map { "\($0) (\(gb(srcSize)))" } ?? "auto-detect (waits for a new disk)"))
            if let _ = srcID {
                if srcSize < 50_000_000 {
                    warns.append("Source is \(gb(srcSize)) — that is a vendor PLACEHOLDER size, almost certainly not the real disk. Imaging it recovers nothing.")
                }
                let free = freeBytes(at: dest)
                if free >= 0 && free < srcSize && !state.img {
                    warns.append("Destination free space (\(gb(free))) is smaller than the source (\(gb(srcSize))). The image will not fit.")
                }
            }
            if state.img && state.map {
                lines.append("Resume:  existing image+map found — this run CONTINUES the job (it never restarts).")
            }
        }

        if m.acceptsImage {
            let eff = image.isEmpty ? "\(dest)/\(label).img" : image
            lines.append("Image:   \(eff)")
            if !FileManager.default.fileExists(atPath: eff) {
                let alert = NSAlert()
                alert.alertStyle = .critical
                alert.messageText = "No image to work on"
                alert.informativeText = "\(eff) does not exist. Run '10 · Image failing disk' first, or pick a .img with Browse."
                alert.runModal()
                setStatus("Blocked: image not found.", error: true)
                return false
            }
        }

        if mfile.hasPrefix("90_") {
            let fstab = (try? String(contentsOfFile: "/etc/fstab", encoding: .utf8)) ?? ""
            let guards = fstab.split(separator: "\n").filter { $0.contains("# rescuekit:") }
            if guards.isEmpty {
                lines.append("Guards:  none present — nothing to remove.")
            } else {
                lines.append("Guards on file:")
                for g in guards.prefix(8) { lines.append("  " + g) }
                let other = guards.filter { !$0.hasSuffix("# rescuekit:" + label) }.count
                if other > 0 {
                    warns.append("\(other) guard line(s) belong to OTHER jobs. Only this job's guards are removed; leave the rest until those patients are off the bench.")
                }
            }
        }

        let alert = NSAlert()
        alert.messageText = warns.isEmpty ? "Ready to run" : "Check before running"
        alert.alertStyle = warns.isEmpty ? .informational : .warning
        var info = lines.joined(separator: "\n")
        if !warns.isEmpty {
            info += "\n\n" + warns.map { "⚠️ " + $0 }.joined(separator: "\n")
        }
        alert.informativeText = info
        alert.addButton(withTitle: warns.isEmpty ? "Run" : "Run anyway")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() != .alertFirstButtonReturn {
            setStatus("Cancelled.")
            return false
        }
        return true
    }

    @objc func runClicked() {
        let i = methodPopup.indexOfSelectedItem
        guard i >= 0, i < methods.count else { return }
        guard let destName = destPopup.titleOfSelectedItem else {
            statusLabel.stringValue = "Pick a destination volume."
            return
        }
        let dest = "/Volumes/" + destName
        // Label becomes file paths: no '/', no leading '-', no newlines.
        var label = cleaned(labelField.stringValue).replacingOccurrences(of: "/", with: "_")
        while label.hasPrefix("-") { label.removeFirst() }
        if label.isEmpty { label = defaultLabel() }

        var srcID: String? = nil
        var srcSize: Int64 = -1
        if let src = selectedSourceID() {
            // Disk numbers are recycled: re-check the device still matches what
            // was scanned before passing it to a sudo imaging run.
            let idx = sourcePopup.indexOfSelectedItem - 1
            let expected = (idx >= 0 && idx < sources.count) ? sources[idx].size : -1
            let now = (diskutilPlist(["info", "-plist", src])?["TotalSize"] as? NSNumber)?.int64Value ?? -2
            guard now == expected else {
                setStatus("Source \(src) changed since the scan — hit Refresh and re-pick.", error: true)
                return
            }
            srcID = src
            srcSize = expected
        }
        let image = cleaned(imageField.stringValue)

        guard preflight(methods[i], dest: dest, label: label,
                        srcID: srcID, srcSize: srcSize, image: image) else { return }

        var cmd = "sudo bash \(shq(methods[i].path)) --dest \(shq(dest)) --label \(shq(label))"
        if let src = srcID { cmd += " --device " + src }
        if !image.isEmpty { cmd += " --image " + shq(image) }
        let extra = cleaned(argsField.stringValue)
        if !extra.isEmpty { cmd += " " + extra }

        let asEscaped = cmd
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "tell application \"Terminal\"\nactivate\ndo script \"\(asEscaped)\"\nend tell"
        guard let runner = NSAppleScript(source: script) else {
            setStatus("Internal error: could not build the Terminal command.", error: true)
            return
        }
        var err: NSDictionary?
        runner.executeAndReturnError(&err)
        if let err = err {
            setStatus("Terminal launch failed: \(err["NSAppleScriptErrorBriefMessage"] ?? "?")", error: true)
        } else {
            setStatus("Running '\(methods[i].name)' — enter password in Terminal.")
            refreshJobState()
        }
    }

    // Read only the tail of each log: job logs reach hundreds of MB and this
    // runs on the main thread every 2 s.
    func tailOfFile(_ path: String, bytes: UInt64 = 5000) -> String? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { fh.closeFile() }
        let size = fh.seekToEndOfFile()
        fh.seek(toFileOffset: size > bytes ? size - bytes : 0)
        let data = fh.readDataToEndOfFile()
        guard !data.isEmpty else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    func refreshLog() {
        guard let destName = destPopup.titleOfSelectedItem else { return }
        let label = labelField.stringValue.isEmpty ? defaultLabel() : labelField.stringValue
        let base = "/Volumes/\(destName)/\(label)"
        var text = ""
        for suffix in [".log", ".extract.log", ".carve.log", ".triage.log"] {
            if let t = tailOfFile(base + suffix) {
                text += "──── \(label + suffix) ────\n" + t + "\n"
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
