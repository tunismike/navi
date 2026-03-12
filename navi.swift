import Cocoa
import QuartzCore

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
    private var isAnimating = false

    private var fairyCenter: CGPoint {
        CGPoint(x: fairySize / 2, y: fairySize / 2)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let visibleFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let startFrame = centeredFrame(in: visibleFrame)

        window = NSWindow(
            contentRect: startFrame,
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

        let contentView = NSView(frame: NSRect(origin: .zero, size: startFrame.size))
        contentView.wantsLayer = true
        contentView.layer?.masksToBounds = false

        fairyView = NSView(frame: contentView.bounds)
        fairyView.wantsLayer = true
        fairyView.layer?.masksToBounds = false
        contentView.addSubview(fairyView)

        buildFairy()

        window.contentView = contentView
        window.orderFrontRegardless()

        startAmbientAnimations()
        startWandering()

        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("NaviTaskComplete"),
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.triggerExcitement()
        }
    }

    private func centeredFrame(in visibleFrame: NSRect) -> NSRect {
        NSRect(
            x: visibleFrame.midX - (fairySize / 2),
            y: visibleFrame.midY - (fairySize / 2),
            width: fairySize,
            height: fairySize
        )
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

        sparkleViews = [
            createSparkleView(size: 5),
            createSparkleView(size: 4)
        ]

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

            let orbitWidth: CGFloat = index == 0 ? 42 : 34
            let orbitHeight: CGFloat = index == 0 ? 28 : 22
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
            orbit.duration = index == 0 ? 2.8 : 2.1
            orbit.repeatCount = .infinity
            orbit.calculationMode = .paced
            orbit.beginTime = CACurrentMediaTime() + (Double(index) * 0.45)
            orbit.fillMode = .backwards
            layer.add(orbit, forKey: "orbit")

            let twinkle = CABasicAnimation(keyPath: "opacity")
            twinkle.fromValue = index == 0 ? 0.25 : 0.15
            twinkle.toValue = 1.0
            twinkle.duration = index == 0 ? 0.7 : 0.55
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
        if isAnimating { return }
        guard let visibleFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame else { return }

        let minX = visibleFrame.minX + edgeInset
        let maxX = visibleFrame.maxX - fairySize - edgeInset
        let minY = visibleFrame.minY + edgeInset
        let maxY = visibleFrame.maxY - fairySize - edgeInset

        let destination = NSRect(
            x: randomCoordinate(min: minX, max: maxX, fallback: visibleFrame.midX - (fairySize / 2)),
            y: randomCoordinate(min: minY, max: maxY, fallback: visibleFrame.midY - (fairySize / 2)),
            width: fairySize,
            height: fairySize
        )

        let dx = window.frame.origin.x - destination.origin.x
        let dy = window.frame.origin.y - destination.origin.y
        let distance = sqrt((dx * dx) + (dy * dy))
        let duration = max(1.4, TimeInterval(distance / wanderSpeed))

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            self.window.animator().setFrame(destination, display: true)
        }) {
            if !self.isAnimating {
                self.startWandering()
            }
        }
    }

    private func triggerExcitement() {
        if isAnimating { return }
        isAnimating = true

        guard let visibleFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame else {
            isAnimating = false
            return
        }

        let targetFrame = centeredFrame(in: visibleFrame)
        setFlapSpeed(excitedFlapSpeed)

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.55
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.window.animator().setFrame(targetFrame, display: true)
        }) {
            let baseY = targetFrame.origin.y
            self.excitedBob(targetY: baseY + 44, duration: 0.26) {
                self.excitedBob(targetY: baseY - 18, duration: 0.26) {
                    self.excitedBob(targetY: baseY + 34, duration: 0.24) {
                        self.excitedBob(targetY: baseY, duration: 0.24) {
                            self.isAnimating = false
                            self.startIdleFlap()
                            self.startWandering()
                        }
                    }
                }
            }
        }
    }

    private func excitedBob(targetY: CGFloat, duration: TimeInterval, completion: @escaping () -> Void) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            var frame = self.window.frame
            frame.origin.y = targetY
            self.window.animator().setFrame(frame, display: true)
        }) {
            completion()
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
