import AppKit
import SpriteKit

final class LetterFallScene: SKScene {
    private static let rainGlyphs = Array("aeiounrstlmcdpgbhkwyzAEGMRSTWأبتجحدرسشعفقكلمنهوي日本語中文字한글ÉéñüßçΩЖдλ")
    private static let rainCount = 150
    private static let rainDuration: TimeInterval = 3

    private var glyphSize: ClosedRange<CGFloat> { size.height * 0.022...size.height * 0.05 }

    override init(size: CGSize) {
        super.init(size: size)
        backgroundColor = .clear
        scaleMode = .resizeFill
        physicsWorld.gravity = CGVector(dx: 0, dy: -11)
        closeFloor()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func rain() {
        let interval = Self.rainDuration / Double(Self.rainCount)
        let drop = SKAction.run { [weak self] in
            guard let self, let glyph = Self.rainGlyphs.randomElement() else { return }
            spawn(glyph, at: CGPoint(x: .random(in: 0...size.width), y: size.height + 40),
                  size: .random(in: glyphSize), isInk: Bool.random())
        }
        run(.repeat(.sequence([drop, .wait(forDuration: interval)]), count: Self.rainCount))
    }

    func drop(word: String) {
        let spread = min(size.width * 0.3, 360)
        for (index, glyph) in word.enumerated() where !glyph.isWhitespace {
            run(.sequence([
                .wait(forDuration: Double(index) * 0.06),
                .run { [weak self] in
                    guard let self else { return }
                    spawn(glyph, at: CGPoint(x: size.width / 2 + .random(in: -spread...spread), y: size.height + 40),
                          size: glyphSize.upperBound * 1.15, isInk: true)
                },
            ]))
        }
    }

    func openFloor() {
        physicsBody = nil
        for node in children {
            node.physicsBody?.applyImpulse(CGVector(dx: .random(in: -2...2), dy: .random(in: 0...3)))
        }
    }

    override func didChangeSize(_ oldSize: CGSize) {
        super.didChangeSize(oldSize)
        if physicsBody != nil { closeFloor() }
    }

    private func closeFloor() {
        physicsBody = SKPhysicsBody(edgeLoopFrom: CGRect(x: 0, y: 0, width: size.width, height: size.height * 3))
        physicsBody?.friction = 0.6
    }

    private func spawn(_ glyph: Character, at point: CGPoint, size fontSize: CGFloat, isInk: Bool) {
        let label = SKLabelNode()
        label.attributedText = NSAttributedString(string: String(glyph), attributes: [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
            .foregroundColor: isInk ? OnboardingStyle.inkColor : OnboardingStyle.ghostColor,
        ])
        label.verticalAlignmentMode = .center
        label.horizontalAlignmentMode = .center
        label.position = point
        label.zRotation = .random(in: -0.6...0.6)
        let frame = label.calculateAccumulatedFrame()
        let body = SKPhysicsBody(rectangleOf: CGSize(width: max(frame.width * 0.9, 4), height: max(frame.height * 0.72, 4)))
        body.restitution = 0.12
        body.friction = 0.7
        body.angularDamping = 0.5
        body.velocity = CGVector(dx: .random(in: -40...40), dy: .random(in: -120...0))
        body.angularVelocity = .random(in: -3...3)
        label.physicsBody = body
        addChild(label)
    }
}
