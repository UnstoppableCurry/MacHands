import AppKit

/// 品牌视觉常量与几个自绘控件。跟官网(mint 绿 + 天蓝)统一色调,
/// 别让 App 和网站看起来像两个不相关的东西。
///
/// 坑:CALayer.backgroundColor 是 CGColor,一旦赋值就冻结成当时那个外观
/// (浅色/深色)的快照,系统切换外观后不会自动跟着变。所有用到 layer 上色的
/// 自绘控件都重写 `viewDidChangeEffectiveAppearance()` 重新上色一次；
/// 反之 NSTextField.textColor 这种"活的" NSColor 属性本身就是动态的,不用管。
enum Theme {
    static let accentA = NSColor(srgbRed: 0.31, green: 0.88, blue: 0.63, alpha: 1)   // 官网 --accent
    static let accentB = NSColor(srgbRed: 0.37, green: 0.72, blue: 1.00, alpha: 1)   // 官网 --accent2
    static let danger  = NSColor(srgbRed: 0.94, green: 0.36, blue: 0.36, alpha: 1)

    static let cardRadius: CGFloat = 14
    static let buttonRadius: CGFloat = 10

    static func attributed(_ text: String, color: NSColor, size: CGFloat, weight: NSFont.Weight) -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        return NSAttributedString(string: text, attributes: [
            .foregroundColor: color,
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .paragraphStyle: para
        ])
    }
}

/// 圆角渐变徽标(App 的"手"标志)。用 CAGradientLayer + NSImageView 叠加,
/// 不走自定义 draw(_:),降低出错面。
final class GradientBadge: NSView {

    private let gradientLayer = CAGradientLayer()
    private let symbolView = NSImageView()

    init(symbolName: String, size: CGFloat, tint: NSColor = .white) {
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        wantsLayer = true
        gradientLayer.colors = [Theme.accentA.cgColor, Theme.accentB.cgColor]
        gradientLayer.startPoint = CGPoint(x: 0, y: 1)
        gradientLayer.endPoint = CGPoint(x: 1, y: 0)
        gradientLayer.cornerRadius = size * 0.28
        gradientLayer.cornerCurve = .continuous
        layer?.addSublayer(gradientLayer)

        symbolView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        symbolView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: size * 0.42, weight: .semibold)
        symbolView.contentTintColor = tint
        symbolView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(symbolView)

        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size),
            heightAnchor.constraint(equalToConstant: size),
            symbolView.centerXAnchor.constraint(equalTo: centerXAnchor),
            symbolView.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("code-only") }

    override func layout() {
        super.layout()
        gradientLayer.frame = bounds
    }

    func setSymbol(_ name: String) {
        symbolView.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }
}

/// 卡片容器:圆角 + 语义化背景色。默认跟随控件背景色/分隔线色,随外观自动变;
/// `setTint` 可以换成别的强调色(比如暂停横幅的红),换过之后外观切换也不会被冲掉——
/// 冻结的是 CGColor 快照,所以每次 viewDidChangeEffectiveAppearance 都重新算一遍,
/// 而不是写死颜色只算一次。
final class CardView: NSView {

    private var tintBackground: NSColor?
    private var tintBorder: NSColor?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Theme.cardRadius
        layer?.cornerCurve = .continuous
        applyColors()
    }
    required init?(coder: NSCoder) { fatalError("code-only") }

    func setTint(background: NSColor, border: NSColor) {
        tintBackground = background
        tintBorder = border
        applyColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        layer?.backgroundColor = (tintBackground ?? NSColor.controlColor).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = (tintBorder ?? NSColor.separatorColor).cgColor
    }
}

/// 三种风格的按钮:填色(主操作)、淡色描边(次操作)、危险(拒绝类)。
/// 全部自绘,不混用系统 .rounded 贝塞尔——混着用反而不统一。
final class StyledButton: NSButton {

    enum Kind { case filled(NSColor), tinted(NSColor), outline }

    var kind: Kind = .outline { didSet { applyStyle() } }
    private var titleSize: CGFloat = 13
    private var titleWeight: NSFont.Weight = .semibold

    convenience init(title: String, kind: Kind, size: CGFloat = 13, weight: NSFont.Weight = .semibold) {
        self.init(frame: .zero)
        self.title = title
        self.titleSize = size
        self.titleWeight = weight
        self.kind = kind
        applyStyle()
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        isBordered = false
        bezelStyle = .regularSquare
        wantsLayer = true
        layer?.cornerRadius = Theme.buttonRadius
        layer?.cornerCurve = .continuous
        setButtonType(.momentaryChange)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyStyle()
    }

    override var title: String {
        didSet { applyStyle() }
    }

    private func applyStyle() {
        let fg: NSColor
        switch kind {
        case .filled(let bg):
            layer?.backgroundColor = bg.cgColor
            layer?.borderWidth = 0
            fg = .white
        case .tinted(let bg):
            layer?.backgroundColor = bg.withAlphaComponent(0.14).cgColor
            layer?.borderWidth = 1
            layer?.borderColor = bg.withAlphaComponent(0.4).cgColor
            fg = bg
        case .outline:
            layer?.backgroundColor = NSColor.controlColor.cgColor
            layer?.borderWidth = 1
            layer?.borderColor = NSColor.separatorColor.cgColor
            fg = .labelColor
        }
        attributedTitle = Theme.attributed(title, color: fg, size: titleSize, weight: titleWeight)
    }
}
