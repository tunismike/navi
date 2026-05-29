import Cocoa
import QuartzCore
import Carbon

// MARK: - App State
private enum NaviState {
    case wandering
    case listening
    case thinking
    case speaking
}

private enum InputMode {
    case gemini   // Cmd+Shift+Space — ask Navi (Gemini)
    case mini     // Cmd+Shift+M     — ask the Mac mini (remote shell over Tailscale)
}


private func degrees(_ value: CGFloat) -> CGFloat {
    value * .pi / 180
}

private enum WingTag: Int, CaseIterable {
    case backLeft = 1
    case frontLeft = 2
    case frontRight = 3
    case backRight = 4

    var isLeft: Bool {
        self == .backLeft || self == .frontLeft
    }

    var isFront: Bool {
        self == .frontLeft || self == .frontRight
    }

    var size: CGSize {
        switch self {
        case .backLeft:
            return CGSize(width: 34, height: 22)
        case .frontLeft:
            return CGSize(width: 46, height: 30)
        case .frontRight:
            return CGSize(width: 46, height: 30)
        case .backRight:
            return CGSize(width: 34, height: 22)
        }
    }

    var anchorPoint: CGPoint {
        switch self {
        case .backLeft:
            return CGPoint(x: 1.0, y: 0.12)
        case .frontLeft:
            return CGPoint(x: 1.0, y: 0.12)
        case .frontRight:
            return CGPoint(x: 0.0, y: 0.12)
        case .backRight:
            return CGPoint(x: 0.0, y: 0.12)
        }
    }

    var rootOffset: CGPoint {
        switch self {
        case .backLeft:
            return .zero
        case .frontLeft:
            return .zero
        case .frontRight:
            return .zero
        case .backRight:
            return .zero
        }
    }

    var restAngle: CGFloat {
        switch self {
        case .backLeft:
            return degrees(52)
        case .frontLeft:
            return degrees(-20.5)
        case .frontRight:
            return degrees(20.5)
        case .backRight:
            return degrees(-52)
        }
    }

    var phaseOffset: CFTimeInterval {
        isFront ? 0.0 : 0.03
    }

    var durationScale: Double {
        isFront ? 1.0 : 1.12
    }

    var flapAmplitude: CGFloat {
        isFront ? degrees(24) : degrees(19)
    }

    var flapDirection: CGFloat {
        let sideSign: CGFloat = isLeft ? 1.0 : -1.0
        return sideSign * (isFront ? -1.0 : 1.0)
    }

    var fillAlpha: CGFloat {
        isFront ? 0.46 : 0.26
    }

    var strokeAlpha: CGFloat {
        isFront ? 0.24 : 0.14
    }

    var zPosition: CGFloat {
        isFront ? 2.0 : 1.0
    }
}

final class InputWindow: NSWindow {
    override var canBecomeKey: Bool {
        return true
    }
    override var canBecomeMain: Bool {
        return true
    }
}

final class NonVibrantTextField: NSTextField {
    override var allowsVibrancy: Bool {
        return false
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let fairySize: CGFloat = 130
    private let edgeInset: CGFloat = 48
    private let wanderSpeed: CGFloat = 130
    private let idleFlapSpeed: TimeInterval = 0.12
    private let excitedFlapSpeed: TimeInterval = 0.05

    private var window: NSWindow!
    private var fairyView: NSView!
    private var glowView: NSImageView!
    private var bodyView: NSImageView!
    private var wingLayers: [WingTag: CALayer] = [:]
    private var sparkleViews: [NSView] = []
    
    // Custom transparent field editor to avoid grey bounding box
    private var customFieldEditor: NSTextView?
    
    // Carbon HotKey refs
    private var hotKeyRef: EventHotKeyRef?      // Cmd+Shift+Space (Gemini)
    private var hotKeyRef2: EventHotKeyRef?     // Cmd+Shift+M (Mac mini)
    private var eventHandlerRef: EventHandlerRef?
    
    // Static reference for the Carbon C-callback
    static weak var shared: AppDelegate?
    
    private var currentState: NaviState = .wandering
    private var inputWindow: NSWindow?
    private var inputField: NSTextField?
    private var outputWindow: NSWindow?
    private var outputField: NSTextField?
    private var typewriterTimer: Timer?
    
    // Sounds
    private var inSound: NSSound?
    private var outSound: NSSound?
    private var heySound: NSSound?   // "Hey! Listen!" — plays when remote jobs finish

    // Gemini AI Service
    private let geminiService = GeminiService()

    // Remote (Mac mini) terminal monitor
    private let remoteMonitor = RemoteMonitor()
    private var remoteShells = 0
    private var remoteBusy = 0
    private var remoteReachable = false
    private var ambientBusy = false   // currently showing the calm "remote is working" glow
    private var inputMode: InputMode = .gemini

    // Per-terminal diffing for attention events
    private var prevTerminals: [String: String] = [:]
    private var hadFirstPoll = false
    private var attentionTimer: Timer?   // non-nil while a fast-flap attention burst is active

    // System-pressure adaptivity
    private let systemLoad = SystemLoad()
    private var loadTimer: Timer?
    private var calmMode = false        // machine is busy -> hover in place, stop flying
    private var displayAsleep = false   // display off / screen locked -> fully idle

    private var fairyCenter: CGPoint {
        CGPoint(x: fairySize / 2, y: fairySize / 2)
    }

    // MARK: - Fairy positioning (window-local coordinates)

    /// Size of the full-screen overlay's content area.
    private var contentSize: CGSize {
        window.contentView?.bounds.size ?? .zero
    }

    /// Window-local origin that centers the fairy.
    private func centeredLocalOrigin() -> CGPoint {
        let cs = contentSize
        return CGPoint(x: (cs.width - fairySize) / 2, y: (cs.height - fairySize) / 2)
    }

    /// Convert a window-local origin to a screen point (for the input/output popovers).
    private func screenOrigin(forLocal local: CGPoint) -> CGPoint {
        CGPoint(x: window.frame.minX + local.x, y: window.frame.minY + local.y)
    }

    /// The fairy's current frame in screen coordinates.
    private func fairyScreenFrame() -> NSRect {
        NSRect(origin: screenOrigin(forLocal: fairyView.frame.origin),
               size: CGSize(width: fairySize, height: fairySize))
    }

    /// Animate the fairy to a window-local origin by moving the view (not the window).
    private func moveFairy(toLocal origin: CGPoint,
                           duration: TimeInterval,
                           timing: CAMediaTimingFunctionName,
                           completion: (() -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: timing)
            self.fairyView.animator().setFrameOrigin(origin)
        }, completionHandler: completion)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        
        loadSounds()
        
        let visibleFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)

        // One full-screen, transparent, click-through overlay. The fairy moves as a
        // view *inside* this window (cheap GPU compositing) instead of the whole window
        // being repositioned each leg (which goes through WindowServer and stutters
        // under graphics load).
        window = NSWindow(
            contentRect: visibleFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .floating
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

        let contentView = NSView(frame: NSRect(origin: .zero, size: visibleFrame.size))
        contentView.wantsLayer = true
        contentView.layer?.masksToBounds = false

        // Fairy starts centered, in window-local coordinates.
        let startLocal = CGPoint(x: (visibleFrame.width - fairySize) / 2,
                                 y: (visibleFrame.height - fairySize) / 2)
        fairyView = NSView(frame: NSRect(origin: startLocal,
                                         size: CGSize(width: fairySize, height: fairySize)))
        fairyView.wantsLayer = true
        fairyView.layer?.masksToBounds = false
        contentView.addSubview(fairyView)

        buildFairy()

        window.contentView = contentView
        window.setFrame(visibleFrame, display: true)
        window.orderFrontRegardless()

        startAmbientAnimations()
        updateSparkleVisibility(count: 2)
        startWandering()


        setupGlobalHotkey()

        // Begin reflecting the Mac mini's terminals over Tailscale.
        remoteMonitor.onUpdate = { [weak self] status in
            self?.handleRemoteStatus(status)
        }
        remoteMonitor.start()

        startLoadMonitoring()
    }

    // MARK: - System-pressure adaptivity
    //
    // The fairy animates by physically moving its window, which leans on WindowServer.
    // When the Mac is busy (or the screen is off) we stop flying and just hover in place
    // so Navi never adds compositing pressure at the worst moment.

    private func startLoadMonitoring() {
        _ = systemLoad.cpuBusyFraction()   // prime the delta baseline
        loadTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: true) { [weak self] _ in
            self?.evaluateSystemPressure()
        }

        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(displayDidSleep),
                       name: NSWorkspace.screensDidSleepNotification, object: nil)
        ws.addObserver(self, selector: #selector(displayDidWake),
                       name: NSWorkspace.screensDidWakeNotification, object: nil)

        // Screen lock/unlock isn't a screensaver-sleep event, so watch it separately.
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(self, selector: #selector(displayDidSleep),
                        name: NSNotification.Name("com.apple.screenIsLocked"), object: nil)
        dnc.addObserver(self, selector: #selector(displayDidWake),
                        name: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil)
    }

    private func evaluateSystemPressure() {
        let busy = systemLoad.cpuBusyFraction()
        let perCore = systemLoad.loadPerCore()
        // Hysteresis so we don't flip-flop around a single threshold.
        let pressured = busy > 0.80 || perCore > 1.0
        let relaxed   = busy < 0.60 && perCore < 0.7

        if !calmMode && pressured {
            calmMode = true                 // current wander leg finishes, then she hovers
        } else if calmMode && relaxed {
            calmMode = false
            if currentState == .wandering && !displayAsleep {
                startWandering()            // resume flying
            }
        }
    }

    @objc private func displayDidSleep() {
        displayAsleep = true
        remoteMonitor.pause()               // stop SSH churn while nobody's watching
    }

    @objc private func displayDidWake() {
        displayAsleep = false
        remoteMonitor.resume()
        if currentState == .wandering && !calmMode {
            startWandering()
        }
    }
    
    private func loadSounds() {
        let naviDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".navi")
        
        let inURL = naviDir.appendingPathComponent("In.m4a")
        if FileManager.default.fileExists(atPath: inURL.path) {
            inSound = NSSound(contentsOf: inURL, byReference: true)
        }
        
        let outURL = naviDir.appendingPathComponent("Out.m4a")
        if FileManager.default.fileExists(atPath: outURL.path) {
            outSound = NSSound(contentsOf: outURL, byReference: true)
        }

        let heyURL = naviDir.appendingPathComponent("Listen.m4a")
        if FileManager.default.fileExists(atPath: heyURL.path) {
            heySound = NSSound(contentsOf: heyURL, byReference: true)
        }
    }

    // MARK: - Input & Hotkey Logic

    private func setupGlobalHotkey() {
        let opts = NSDictionary(object: kCFBooleanTrue, forKey: kAXTrustedCheckOptionPrompt.takeUnretainedValue() as NSString) as CFDictionary
        let accessEnabled = AXIsProcessTrustedWithOptions(opts)
        
        if !accessEnabled {
            print("WARNING: Accessibility access not granted. Global hotkey (Cmd+Shift+Space) will not work.")
        } else {
            print("Listening for Cmd+Shift+Space via Carbon...")
        }
        
        // Command (cmdKey = 256), Shift (shiftKey = 512)
        var hotKeyID = EventHotKeyID()
        hotKeyID.signature = OSType(1337)
        hotKeyID.id = UInt32(1)

        // Key code for Space is 49.
        var err = RegisterEventHotKey(UInt32(kVK_Space),
                                      UInt32(cmdKey | shiftKey),
                                      hotKeyID,
                                      GetApplicationEventTarget(),
                                      0,
                                      &hotKeyRef)
                                      
        if err != noErr {
            print("Error registering Carbon hot key: \(err)")
        }

        // Second hotkey: Cmd+Shift+M -> ask the Mac mini. Key code for 'M' is 46.
        var hotKeyID2 = EventHotKeyID()
        hotKeyID2.signature = OSType(1337)
        hotKeyID2.id = UInt32(2)
        err = RegisterEventHotKey(UInt32(kVK_ANSI_M),
                                  UInt32(cmdKey | shiftKey),
                                  hotKeyID2,
                                  GetApplicationEventTarget(),
                                  0,
                                  &hotKeyRef2)
        if err != noErr {
            print("Error registering mini hot key: \(err)")
        }

        // Install event handler for the pressed hotkeys, dispatching on the hotkey id.
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        err = InstallEventHandler(GetApplicationEventTarget(),
                                  { (nextHandler, theEvent, userData) -> OSStatus in
                                      var firedID = EventHotKeyID()
                                      GetEventParameter(theEvent,
                                                        EventParamName(kEventParamDirectObject),
                                                        EventParamType(typeEventHotKeyID),
                                                        nil,
                                                        MemoryLayout<EventHotKeyID>.size,
                                                        nil,
                                                        &firedID)
                                      if firedID.id == 2 {
                                          AppDelegate.shared?.toggleMiniState()
                                      } else {
                                          AppDelegate.shared?.toggleListeningState()
                                      }
                                      return noErr
                                  },
                                  1,
                                  &eventType,
                                  nil,
                                  &eventHandlerRef)

        if err != noErr {
            print("Error installing event handler: \(err)")
        }
    }

    private func toggleListeningState() {
        if currentState == .listening {
            cancelListening()
        } else {
            startListening(mode: .gemini)
        }
    }

    private func toggleMiniState() {
        if currentState == .listening {
            cancelListening()
        } else {
            startListening(mode: .mini)
        }
    }

    private func startListening(mode: InputMode) {
        guard currentState == .wandering else { return }
        inputMode = mode
        currentState = .listening

        // Drop any ambient "remote busy" styling so it doesn't fight the input glow.
        ambientBusy = false

        inSound?.play()
        setFlapSpeed(excitedFlapSpeed) // Flap fast while traveling to center

        // Stop wandering and glide to center.
        moveFairy(toLocal: centeredLocalOrigin(), duration: 0.6, timing: .easeOut) {
            self.setFlapSpeed(self.idleFlapSpeed) // Back to regular speed once there
            self.showInputWindow(below: self.fairyScreenFrame())
            self.glowView.layer?.shadowColor = NSColor.systemPurple.cgColor
            self.glowView.layer?.shadowRadius = 20
            self.glowView.layer?.shadowOpacity = 1.0
        }
    }

    private func cancelListening() {
        guard currentState == .listening else { return }
        hideInputWindow()
        outSound?.play()
        
        self.glowView.layer?.shadowOpacity = 0.0 // reset glow
        setFlapSpeed(idleFlapSpeed)
        
        currentState = .wandering
        startWandering()
    }

    private func showInputWindow(below fairyFrame: NSRect) {
        if inputWindow == nil {
            let width: CGFloat = 400
            let height: CGFloat = 50
            let inputFrame = NSRect(
                x: fairyFrame.midX - (width / 2),
                y: fairyFrame.minY - height - 20, // 20px below fairy
                width: width,
                height: height
            )
            
            let win = InputWindow(
                contentRect: inputFrame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            win.isOpaque = false
            win.backgroundColor = .clear
            win.level = .floating
            win.hasShadow = true
            win.delegate = self
            
            // Dark translucent background (no border)
            let bgView = NSView(frame: NSRect(origin: .zero, size: inputFrame.size))
            bgView.wantsLayer = true
            bgView.layer?.backgroundColor = NSColor(calibratedWhite: 0.15, alpha: 0.85).cgColor
            bgView.layer?.cornerRadius = 25
            bgView.layer?.masksToBounds = true
            
            // Text Field
            let tf = NonVibrantTextField(frame: NSRect(x: 20, y: 10, width: width - 40, height: 30))
            tf.isBordered = false
            tf.isBezeled = false
            tf.drawsBackground = false
            tf.backgroundColor = .clear
            tf.focusRingType = .none
            tf.font = NSFont.systemFont(ofSize: 18, weight: .regular)
            tf.textColor = .white
            tf.placeholderString = "Ask Navi..."
            tf.delegate = self
            
            bgView.addSubview(tf)
            win.contentView = bgView
            
            self.inputWindow = win
            self.inputField = tf
        } else {
            let width: CGFloat = 400
            let height: CGFloat = 50
            let inputFrame = NSRect(
                x: fairyFrame.midX - (width / 2),
                y: fairyFrame.minY - height - 20,
                width: width,
                height: height
            )
            inputWindow?.setFrame(inputFrame, display: true)
        }
        
        inputField?.placeholderString = (inputMode == .mini)
            ? "Ask the mini…  (Enter = status)"
            : "Ask Navi…"

        NSApp.activate(ignoringOtherApps: true)
        inputWindow?.makeKeyAndOrderFront(nil)
        inputWindow?.makeFirstResponder(inputField)
        
        // Ensure navi is above the input
        window.orderFrontRegardless()
    }

    private func hideInputWindow() {
        inputWindow?.orderOut(nil)
        inputField?.stringValue = ""
    }

    // MARK: - Agent Communication (Gemini API)

    private func sendPromptToAgent(_ prompt: String) {
        currentState = .thinking
        hideInputWindow()
        
        // Fast flap to show thinking
        setFlapSpeed(excitedFlapSpeed)
        
        // Check if API key is configured
        if !geminiService.isAuthenticated {
            print("No API key configured")
            showResponse("Add your Gemini API key: echo 'KEY' > ~/.navi/.api_key")
            return
        }
        
        sendToGemini(prompt)
    }
    
    private func sendToGemini(_ prompt: String) {
        // Set a timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 30.0) { [weak self] in
            guard let self = self else { return }
            if self.currentState == .thinking {
                self.agentDidTimeout()
            }
        }
        
        geminiService.generateContent(prompt: prompt) { [weak self] result in
            guard let self = self else { return }
            guard self.currentState == .thinking else { return } // timed out already
            
            switch result {
            case .success(let text):
                self.triggerExcitement()
                self.showResponse(text)
            case .failure(let error):
                print("Gemini error: \(error.localizedDescription)")
                self.showResponse("Hmm... \(error.localizedDescription)")
            }
        }
    }
    
    private func agentDidTimeout() {
        print("Agent response timed out.")
        outSound?.play()
        currentState = .wandering
        setFlapSpeed(idleFlapSpeed)
        startWandering()
    }

    // MARK: - Remote (Mac mini) command + ambient status

    /// Run whatever the user typed in the "Ask the mini…" box on the Mac mini.
    /// An empty prompt (or a status-y phrase) maps to a friendly terminal summary.
    private func sendCommandToMini(_ raw: String) {
        currentState = .thinking
        hideInputWindow()
        setFlapSpeed(excitedFlapSpeed)

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        let isStatusQuery = trimmed.isEmpty
            || lower == "status"
            || lower.contains("what's running")
            || lower.contains("whats running")
            || lower.contains("what is running")
            || lower.contains("terminals")
        let command = isStatusQuery ? "__status__" : trimmed

        DispatchQueue.main.asyncAfter(deadline: .now() + 15.0) { [weak self] in
            guard let self = self else { return }
            if self.currentState == .thinking { self.agentDidTimeout() }
        }

        remoteMonitor.runRemote(command) { [weak self] output in
            guard let self = self else { return }
            guard self.currentState == .thinking else { return } // timed out already
            self.triggerExcitement()
            var text = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if text == "__NAVI_OFFLINE__" || text.isEmpty {
                text = "🌙 The mini isn't reachable right now."
            }
            if text.count > 280 { text = String(text.prefix(280)) + "…" }
            self.showResponse(text)
        }
    }

    /// Reflect the mini's live terminal state in Navi's body language.
    private func handleRemoteStatus(_ status: RemoteStatus) {
        let prevReachable = remoteReachable
        let prevTerms = prevTerminals
        remoteShells = status.shells
        remoteBusy = status.busy
        remoteReachable = status.reachable
        prevTerminals = status.terminals

        // Sparkle count == number of live terminals on the mini (1 when offline/idle).
        let sparkleCount = status.reachable ? max(1, min(6, status.shells)) : 1
        updateSparkleVisibility(count: sparkleCount)

        // Calm, persistent "something's running over there" glow — only refreshed when
        // an attention burst isn't currently overriding the glow, and only while wandering.
        if currentState == .wandering && attentionTimer == nil {
            if status.busy > 0 && !ambientBusy {
                ambientBusy = true
                glowView.layer?.shadowColor = NSColor.systemPurple.cgColor
                glowView.layer?.shadowRadius = 14
                glowView.layer?.shadowOpacity = 0.45
            } else if status.busy == 0 && ambientBusy {
                ambientBusy = false
                glowView.layer?.shadowOpacity = 0.0
            }
        } else {
            ambientBusy = status.busy > 0   // keep flag in sync for endAttention()
        }

        // Establish a baseline on the first sample so we don't alert on startup.
        if !hadFirstPoll {
            hadFirstPoll = true
            return
        }

        // --- Attention events: a transient fast-flap burst to catch the eye ---

        // 1) Mini came back / dropped off the network.
        if prevReachable != status.reachable {
            drawAttention(status.reachable ? heySound : outSound)
            return
        }

        // 2) A command finished on some terminal (a busy tty returned to its prompt).
        //    codex/claude staying busy won't transition, so they don't spam.
        if status.reachable {
            for (tty, prevCmd) in prevTerms where prevCmd != "-" {
                let nowCmd = status.terminals[tty] ?? "-"
                if nowCmd == "-" {
                    drawAttention(heySound)
                    break
                }
            }
        }
    }

    /// A short fast-flap "Hey! Listen!" burst to draw the eye, then auto-settle.
    /// Flapping is cheap (layer animation), so we run it even under CPU load — just
    /// not while the screen is off.
    private func drawAttention(_ sound: NSSound?) {
        guard !displayAsleep else { return }
        setFlapSpeed(excitedFlapSpeed)
        glowView.layer?.shadowColor = NSColor.systemPurple.cgColor
        glowView.layer?.shadowRadius = 22
        glowView.layer?.shadowOpacity = 1.0
        sound?.play()

        attentionTimer?.invalidate()
        attentionTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
            self?.endAttention()
        }
    }

    private func endAttention() {
        attentionTimer = nil
        // Only settle if a user interaction hasn't taken over in the meantime.
        guard currentState == .wandering else { return }
        setFlapSpeed(idleFlapSpeed)
        if ambientBusy {
            glowView.layer?.shadowRadius = 14
            glowView.layer?.shadowOpacity = 0.45
        } else {
            glowView.layer?.shadowOpacity = 0.0
        }
    }

    private func updateSparkleVisibility(count: Int) {
        for (index, sparkle) in sparkleViews.enumerated() {
            sparkle.isHidden = index >= count
        }
    }

    private func showResponse(_ text: String) {
        currentState = .speaking
        outSound?.play()
        
        guard let visibleFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame else { return }
        
        if outputWindow == nil {
            let width: CGFloat = 350
            let height: CGFloat = 120
            
            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: width, height: height), // Will position below
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            win.isOpaque = false
            win.backgroundColor = .clear
            win.level = .floating
            win.hasShadow = true
            
            let visualEffect = NSVisualEffectView(frame: NSRect(origin: .zero, size: win.frame.size))
            visualEffect.material = .hudWindow
            visualEffect.blendingMode = .behindWindow
            visualEffect.state = .active
            visualEffect.wantsLayer = true
            visualEffect.layer?.cornerRadius = 20
            visualEffect.layer?.masksToBounds = true
            visualEffect.layer?.borderWidth = 0
            visualEffect.layer?.borderColor = NSColor.clear.cgColor
            
            let tf = NonVibrantTextField(frame: NSRect(x: 20, y: 20, width: width - 40, height: height - 40))
            tf.isBordered = false
            tf.isBezeled = false
            tf.drawsBackground = false
            tf.backgroundColor = .clear
            tf.isEditable = false
            tf.isSelectable = false
            tf.lineBreakMode = .byWordWrapping
            tf.font = NSFont.systemFont(ofSize: 16, weight: .regular)
            tf.textColor = .white
            tf.stringValue = ""
            
            visualEffect.addSubview(tf)
            win.contentView = visualEffect
            
            self.outputWindow = win
            self.outputField = tf
        }
        
        // Position window to the right of Navi
        let fairyFrame = fairyScreenFrame()
        let outX = min(fairyFrame.maxX + 20, visibleFrame.maxX - 350 - edgeInset)
        let outY = fairyFrame.midY - 60
        outputWindow?.setFrameOrigin(NSPoint(x: outX, y: outY))
        
        outputWindow?.orderFront(nil)
        
        // Typewriter effect
        outputField?.stringValue = ""
        typewriterTimer?.invalidate()
        
        var charIndex = 0
        let chars = Array(text)

        // Speed the typewriter up for longer payloads (e.g. mini command output).
        let typeInterval: TimeInterval = chars.count > 120 ? 0.012 : 0.03
        typewriterTimer = Timer.scheduledTimer(withTimeInterval: typeInterval, repeats: true) { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }
            if charIndex < chars.count {
                self.outputField?.stringValue.append(chars[charIndex])
                charIndex += 1
            } else {
                timer.invalidate()
                // Wait a few seconds, then hide and return to wandering
                DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                    self.hideOutputWindow()
                    if self.currentState == .speaking {
                        self.currentState = .wandering
                        self.startWandering()
                    }
                }
            }
        }
    }

    private func hideOutputWindow() {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.5
            self.outputWindow?.animator().alphaValue = 0.0
        }) {
            self.outputWindow?.orderOut(nil)
            self.outputWindow?.alphaValue = 1.0 // reset for next time
        }
    }


    private func buildFairy() {
        glowView = createGlowView()
        fairyView.addSubview(glowView)

        for wing in [WingTag.backLeft, .backRight, .frontLeft, .frontRight] {
            let layer = createWing(for: wing)
            wingLayers[wing] = layer
            fairyView.layer?.addSublayer(layer)
        }

        bodyView = createBodyView()
        fairyView.addSubview(bodyView)

        // Up to 6 sparkles; how many are shown reflects the mini's live terminal count.
        let sparkleSizes: [CGFloat] = [5, 4, 5, 4, 3, 4]
        sparkleViews = sparkleSizes.map { createSparkleView(size: $0) }

        for sparkle in sparkleViews {
            fairyView.addSubview(sparkle)
        }
    }

    private func createGlowView() -> NSImageView {
        let size: CGFloat = 70
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        NSColor.clear.set()
        NSRect(x: 0, y: 0, width: size, height: size).fill()

        let outer = NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: size, height: size))
        NSColor(calibratedRed: 0.42, green: 0.82, blue: 1.0, alpha: 0.10).setFill()
        outer.fill()

        let mid = NSBezierPath(ovalIn: NSRect(x: 8, y: 8, width: size - 16, height: size - 16))
        NSColor(calibratedRed: 0.56, green: 0.90, blue: 1.0, alpha: 0.18).setFill()
        mid.fill()

        let inner = NSBezierPath(ovalIn: NSRect(x: 18, y: 18, width: size - 36, height: size - 36))
        NSColor(calibratedRed: 0.78, green: 0.96, blue: 1.0, alpha: 0.22).setFill()
        inner.fill()

        image.unlockFocus()

        let view = NSImageView(
            frame: NSRect(
                x: fairyCenter.x - (size / 2),
                y: fairyCenter.y - (size / 2),
                width: size,
                height: size
            )
        )
        view.image = image
        view.wantsLayer = true
        view.layer?.zPosition = 0
        return view
    }

    private func createBodyView() -> NSImageView {
        let size: CGFloat = 44
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        NSColor.clear.set()
        NSRect(x: 0, y: 0, width: size, height: size).fill()

        let aura = NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: size, height: size))
        NSColor(calibratedRed: 0.56, green: 0.90, blue: 1.0, alpha: 0.32).setFill()
        aura.fill()

        let shell = NSBezierPath(ovalIn: NSRect(x: 7, y: 7, width: size - 14, height: size - 14))
        NSColor(calibratedRed: 0.84, green: 0.96, blue: 1.0, alpha: 0.62).setFill()
        shell.fill()

        let core = NSBezierPath(ovalIn: NSRect(x: 13, y: 13, width: size - 26, height: size - 26))
        NSColor.white.setFill()
        core.fill()

        let glint = NSBezierPath(ovalIn: NSRect(x: 15, y: 23, width: 7, height: 7))
        NSColor(calibratedWhite: 1.0, alpha: 0.75).setFill()
        glint.fill()

        image.unlockFocus()

        let view = NSImageView(
            frame: NSRect(
                x: fairyCenter.x - (size / 2),
                y: fairyCenter.y - (size / 2),
                width: size,
                height: size
            )
        )
        view.image = image
        view.wantsLayer = true
        view.layer?.zPosition = 5
        view.layer?.shadowColor = NSColor(calibratedRed: 0.64, green: 0.93, blue: 1.0, alpha: 1.0).cgColor
        view.layer?.shadowOffset = .zero
        view.layer?.shadowRadius = 14
        view.layer?.shadowOpacity = 0.95
        return view
    }

    private func createWing(for wing: WingTag) -> CALayer {
        let size = wing.size
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.clear.set()
        NSRect(origin: .zero, size: size).fill()

        let path = wingPath(for: wing, size: size)
        path.close()

        let gradient = NSGradient(
            colors: [
                NSColor(calibratedRed: 0.98, green: 1.0, blue: 1.0, alpha: wing.fillAlpha * 0.85),
                NSColor(calibratedRed: 0.78, green: 0.93, blue: 1.0, alpha: wing.fillAlpha * 0.45),
                NSColor(calibratedRed: 0.63, green: 0.86, blue: 0.98, alpha: wing.fillAlpha * 0.18)
            ]
        )
        gradient?.draw(in: path, angle: wing.isFront ? 156 : 196)

        NSColor(calibratedRed: 0.88, green: 0.98, blue: 1.0, alpha: wing.strokeAlpha).setStroke()
        path.lineWidth = wing.isFront ? 1.05 : 0.95
        path.stroke()

        let vein = veinPath(for: wing, size: size)
        NSColor(calibratedRed: 0.92, green: 0.99, blue: 1.0, alpha: wing.strokeAlpha * 0.82).setStroke()
        vein.lineWidth = wing.isFront ? 0.82 : 0.72
        vein.stroke()

        image.unlockFocus()

        let layer = CALayer()
        layer.bounds = CGRect(origin: .zero, size: size)
        layer.position = CGPoint(
            x: fairyCenter.x + wing.rootOffset.x,
            y: fairyCenter.y + wing.rootOffset.y
        )
        layer.anchorPoint = wing.anchorPoint
        layer.zPosition = wing.zPosition
        layer.masksToBounds = false
        layer.contentsGravity = .resizeAspect
        layer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        layer.transform = CATransform3DMakeRotation(wing.restAngle, 0, 0, 1)

        if let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            layer.contents = cgImage
        }

        return layer
    }

    private func wingPath(for wing: WingTag, size: CGSize) -> NSBezierPath {
        let width = size.width
        let height = size.height

        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            let mirroredX = wing.isLeft ? x : (width - x)
            return CGPoint(x: mirroredX, y: y)
        }

        let path = NSBezierPath()

        path.move(to: point(width - 1.0, height * 0.12))
        path.curve(
            to: point(width * 0.76, height * 0.52),
            controlPoint1: point(width * 0.98, height * 0.28),
            controlPoint2: point(width * 0.88, height * 0.48)
        )
        path.curve(
            to: point(width * 0.04, height * 0.76),
            controlPoint1: point(width * 0.52, height * 0.74),
            controlPoint2: point(width * 0.18, height * 0.86)
        )
        path.curve(
            to: point(width * 0.18, height * 0.42),
            controlPoint1: point(width * 0.06, height * 0.66),
            controlPoint2: point(width * 0.10, height * 0.50)
        )
        path.curve(
            to: point(width * 0.38, height * 0.14),
            controlPoint1: point(width * 0.24, height * 0.28),
            controlPoint2: point(width * 0.30, height * 0.18)
        )
        path.curve(
            to: point(width - 1.0, height * 0.12),
            controlPoint1: point(width * 0.58, height * 0.02),
            controlPoint2: point(width * 0.86, height * 0.02)
        )

        return path
    }

    private func veinPath(for wing: WingTag, size: CGSize) -> NSBezierPath {
        let width = size.width
        let height = size.height

        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            let mirroredX = wing.isLeft ? x : (width - x)
            return CGPoint(x: mirroredX, y: y)
        }

        let path = NSBezierPath()

        path.move(to: point(width * 0.94, height * 0.14))
        path.curve(
            to: point(width * 0.16, height * 0.50),
            controlPoint1: point(width * 0.70, height * 0.24),
            controlPoint2: point(width * 0.36, height * 0.44)
        )
        path.move(to: point(width * 0.66, height * 0.42))
        path.line(to: point(width * 0.24, height * 0.68))
        path.move(to: point(width * 0.56, height * 0.18))
        path.line(to: point(width * 0.28, height * 0.22))

        return path
    }

    private func createSparkleView(size: CGFloat) -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.95).cgColor
        view.layer?.cornerRadius = size / 2
        view.layer?.shadowColor = NSColor(calibratedRed: 0.74, green: 0.96, blue: 1.0, alpha: 1.0).cgColor
        view.layer?.shadowOffset = .zero
        view.layer?.shadowRadius = 6
        view.layer?.shadowOpacity = 1.0
        view.layer?.zPosition = 6
        return view
    }

    private func startAmbientAnimations() {
        startIdleFlap()
        startHoverMotion()
        startBodyPulse()
        startSparkleOrbit()
    }

    private func startIdleFlap() {
        setFlapSpeed(idleFlapSpeed)
    }

    private func setFlapSpeed(_ speed: TimeInterval) {
        for (wing, layer) in wingLayers {
            layer.removeAnimation(forKey: "flap")
            layer.removeAnimation(forKey: "wingStretch")
            let closeDelta = wing.flapDirection * wing.flapAmplitude

            let flap = CAKeyframeAnimation(keyPath: "transform.rotation.z")
            flap.values = [
                0.0,
                closeDelta,
                0.0
            ]
            flap.keyTimes = [0.0, 0.5, 1.0]
            flap.duration = speed * wing.durationScale
            flap.repeatCount = .infinity
            flap.beginTime = CACurrentMediaTime() + wing.phaseOffset
            flap.isAdditive = true
            flap.timingFunctions = [
                CAMediaTimingFunction(name: .easeInEaseOut),
                CAMediaTimingFunction(name: .easeInEaseOut)
            ]
            flap.fillMode = .backwards
            layer.add(flap, forKey: "flap")

            let stretch = CAKeyframeAnimation(keyPath: "transform.scale.y")
            stretch.values = [1.0, wing.isFront ? 0.84 : 0.90, 1.0]
            stretch.keyTimes = [0.0, 0.5, 1.0]
            stretch.duration = flap.duration
            stretch.repeatCount = .infinity
            stretch.beginTime = flap.beginTime
            stretch.timingFunctions = flap.timingFunctions
            stretch.fillMode = .backwards
            layer.add(stretch, forKey: "wingStretch")
        }
    }

    private func startHoverMotion() {
        fairyView.layer?.removeAnimation(forKey: "hover")

        let hover = CAKeyframeAnimation(keyPath: "transform.translation.y")
        hover.values = [0, 4, 0, -5, 0]
        hover.keyTimes = [0.0, 0.25, 0.5, 0.75, 1.0]
        hover.duration = 2.4
        hover.repeatCount = .infinity
        hover.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: 4)
        fairyView.layer?.add(hover, forKey: "hover")
    }

    private func startBodyPulse() {
        glowView.layer?.removeAnimation(forKey: "glowScale")
        glowView.layer?.removeAnimation(forKey: "glowOpacity")
        bodyView.layer?.removeAnimation(forKey: "bodyScale")
        bodyView.layer?.removeAnimation(forKey: "bodyOpacity")

        let glowScale = CABasicAnimation(keyPath: "transform.scale")
        glowScale.fromValue = 0.94
        glowScale.toValue = 1.08
        glowScale.duration = 1.6
        glowScale.autoreverses = true
        glowScale.repeatCount = .infinity
        glowScale.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        glowView.layer?.add(glowScale, forKey: "glowScale")

        let glowOpacity = CABasicAnimation(keyPath: "opacity")
        glowOpacity.fromValue = 0.55
        glowOpacity.toValue = 0.95
        glowOpacity.duration = 1.6
        glowOpacity.autoreverses = true
        glowOpacity.repeatCount = .infinity
        glowOpacity.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        glowView.layer?.add(glowOpacity, forKey: "glowOpacity")

        let bodyScale = CABasicAnimation(keyPath: "transform.scale")
        bodyScale.fromValue = 0.98
        bodyScale.toValue = 1.06
        bodyScale.duration = 1.1
        bodyScale.autoreverses = true
        bodyScale.repeatCount = .infinity
        bodyScale.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        bodyView.layer?.add(bodyScale, forKey: "bodyScale")

        let bodyOpacity = CABasicAnimation(keyPath: "opacity")
        bodyOpacity.fromValue = 0.85
        bodyOpacity.toValue = 1.0
        bodyOpacity.duration = 1.1
        bodyOpacity.autoreverses = true
        bodyOpacity.repeatCount = .infinity
        bodyOpacity.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        bodyView.layer?.add(bodyOpacity, forKey: "bodyOpacity")
    }

    private func startSparkleOrbit() {
        let center = CGPoint(x: fairySize / 2, y: fairySize / 2)

        for (index, sparkle) in sparkleViews.enumerated() {
            guard let layer = sparkle.layer else { continue }

            layer.removeAnimation(forKey: "orbit")
            layer.removeAnimation(forKey: "twinkle")
            layer.removeAnimation(forKey: "sparkleScale")

            // Stagger each sparkle onto its own ring so a swarm reads cleanly.
            let ring = CGFloat(index % 3)
            let orbitWidth: CGFloat = 30 + ring * 8
            let orbitHeight: CGFloat = orbitWidth * 0.66
            let orbitRect = CGRect(
                x: center.x - (orbitWidth / 2),
                y: center.y - (orbitHeight / 2),
                width: orbitWidth,
                height: orbitHeight
            )

            layer.position = CGPoint(x: orbitRect.maxX, y: center.y)

            let orbitPath = CGMutablePath()
            orbitPath.addEllipse(in: orbitRect)

            let orbit = CAKeyframeAnimation(keyPath: "position")
            orbit.path = orbitPath
            orbit.duration = 2.0 + Double(index) * 0.35
            orbit.repeatCount = .infinity
            orbit.calculationMode = .paced
            orbit.beginTime = CACurrentMediaTime() + (Double(index) * 0.4)
            orbit.fillMode = .backwards
            layer.add(orbit, forKey: "orbit")

            let twinkle = CABasicAnimation(keyPath: "opacity")
            twinkle.fromValue = 0.2
            twinkle.toValue = 1.0
            twinkle.duration = 0.55 + Double(index % 3) * 0.12
            twinkle.autoreverses = true
            twinkle.repeatCount = .infinity
            twinkle.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(twinkle, forKey: "twinkle")

            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 0.8
            scale.toValue = 1.15
            scale.duration = twinkle.duration
            scale.autoreverses = true
            scale.repeatCount = .infinity
            scale.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(scale, forKey: "sparkleScale")
        }
    }

    private func randomCoordinate(min: CGFloat, max: CGFloat, fallback: CGFloat) -> CGFloat {
        guard max > min else { return fallback }
        return CGFloat.random(in: min...max)
    }

    private func startWandering() {
        if currentState != .wandering { return }
        // Hold position (cheap hover only) while the Mac is busy or the screen is off.
        if calmMode || displayAsleep { return }

        let cs = contentSize
        guard cs.width > fairySize, cs.height > fairySize else { return }

        let minX = edgeInset
        let maxX = cs.width - fairySize - edgeInset
        let minY = edgeInset
        let maxY = cs.height - fairySize - edgeInset

        let destination = CGPoint(
            x: randomCoordinate(min: minX, max: maxX, fallback: (cs.width - fairySize) / 2),
            y: randomCoordinate(min: minY, max: maxY, fallback: (cs.height - fairySize) / 2)
        )

        let cur = fairyView.frame.origin
        let dx = cur.x - destination.x
        let dy = cur.y - destination.y
        let distance = sqrt((dx * dx) + (dy * dy))
        let duration = max(1.4, TimeInterval(distance / wanderSpeed))

        moveFairy(toLocal: destination, duration: duration, timing: .easeInEaseOut) {
            if self.currentState == .wandering && !self.calmMode && !self.displayAsleep {
                self.startWandering()
            }
        }
    }

    private func triggerExcitement() {
        // Reset state from thinking to wandering when task is done
        if currentState == .thinking {
            currentState = .wandering
            setFlapSpeed(idleFlapSpeed)
        }

        let center = centeredLocalOrigin()
        setFlapSpeed(excitedFlapSpeed)

        moveFairy(toLocal: center, duration: 0.55, timing: .easeOut) {
            let baseY = center.y
            self.excitedBob(toY: baseY + 44, duration: 0.26) {
                self.excitedBob(toY: baseY - 18, duration: 0.26) {
                    self.excitedBob(toY: baseY + 34, duration: 0.24) {
                        self.excitedBob(toY: baseY, duration: 0.24) {
                            if self.currentState == .wandering {
                                self.startIdleFlap()
                                self.startWandering()
                            }
                        }
                    }
                }
            }
        }
    }

    private func excitedBob(toY y: CGFloat, duration: TimeInterval, completion: @escaping () -> Void) {
        let origin = CGPoint(x: fairyView.frame.origin.x, y: y)
        moveFairy(toLocal: origin, duration: duration, timing: .easeInEaseOut, completion: completion)
    }
}

extension AppDelegate: NSTextFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            // User pressed Enter
            let prompt = control.stringValue
            if inputMode == .mini {
                // Empty prompt in mini mode == "give me a status summary".
                sendCommandToMini(prompt)
            } else if !prompt.isEmpty {
                sendPromptToAgent(prompt)
            } else {
                cancelListening()
            }
            return true
        } else if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            // User pressed Escape
            cancelListening()
            return true
        }
        return false
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? {
        if customFieldEditor == nil {
            let fieldEditor = NSTextView()
            fieldEditor.isFieldEditor = true
            fieldEditor.drawsBackground = false
            fieldEditor.backgroundColor = .clear
            fieldEditor.insertionPointColor = .white
            fieldEditor.focusRingType = .none
            customFieldEditor = fieldEditor
        }
        
        if let tf = client as? NSTextField {
            customFieldEditor?.font = tf.font
            customFieldEditor?.textColor = tf.textColor
        }
        
        return customFieldEditor
    }
}
@main
struct NaviApp {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
