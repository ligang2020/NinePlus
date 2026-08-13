import SwiftUI
import UIKit

struct ScreenCaptureProtectedView<Content: View, Placeholder: View>: UIViewControllerRepresentable {
    var isEnabled: Bool
    var isObscured: Bool
    var content: Content
    var placeholder: Placeholder

    init(
        isEnabled: Bool,
        isObscured: Bool,
        @ViewBuilder content: () -> Content,
        @ViewBuilder placeholder: () -> Placeholder
    ) {
        self.isEnabled = isEnabled
        self.isObscured = isObscured
        self.content = content()
        self.placeholder = placeholder()
    }

    func makeUIViewController(context: Context) -> CaptureProtectedHostingController<Content, Placeholder> {
        CaptureProtectedHostingController(
            content: content,
            placeholder: placeholder,
            isEnabled: isEnabled,
            isObscured: isObscured
        )
    }

    func updateUIViewController(
        _ uiViewController: CaptureProtectedHostingController<Content, Placeholder>,
        context: Context
    ) {
        uiViewController.update(
            content: content,
            placeholder: placeholder,
            isEnabled: isEnabled,
            isObscured: isObscured
        )
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiViewController: CaptureProtectedHostingController<Content, Placeholder>,
        context: Context
    ) -> CGSize? {
        uiViewController.sizeThatFits(proposal)
    }
}

final class CaptureProtectedHostingController<Content: View, Placeholder: View>: UIViewController {
    private let protectedContainer = CaptureProtectedContainerView()
    private let contentHost: UIHostingController<Content>
    private let placeholderHost: UIHostingController<Placeholder>

    init(content: Content, placeholder: Placeholder, isEnabled: Bool, isObscured: Bool) {
        self.contentHost = UIHostingController(rootView: content)
        self.placeholderHost = UIHostingController(rootView: placeholder)
        super.init(nibName: nil, bundle: nil)
        protectedContainer.isProtectionEnabled = isEnabled
        protectedContainer.isObscured = isObscured
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = protectedContainer
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupHost(contentHost)
        setupHost(placeholderHost)
        protectedContainer.setContentView(contentHost.view)
        protectedContainer.setPlaceholderView(placeholderHost.view)
    }

    func update(content: Content, placeholder: Placeholder, isEnabled: Bool, isObscured: Bool) {
        contentHost.rootView = content
        placeholderHost.rootView = placeholder
        protectedContainer.isProtectionEnabled = isEnabled
        protectedContainer.isObscured = isObscured
    }

    func sizeThatFits(_ proposal: ProposedViewSize) -> CGSize {
        let width = proposal.width ?? UIView.layoutFittingCompressedSize.width
        let height = proposal.height ?? UIView.layoutFittingCompressedSize.height
        let fittingSize = CGSize(width: width, height: height)
        return contentHost.sizeThatFits(in: fittingSize)
    }

    private func setupHost<HostedContent: View>(_ host: UIHostingController<HostedContent>) {
        addChild(host)
        host.view.backgroundColor = .clear
        host.view.isUserInteractionEnabled = false
        host.didMove(toParent: self)
    }
}

final class CaptureProtectedContainerView: UIView {
    var isProtectionEnabled = false {
        didSet { updateProtectionState() }
    }

    var isObscured = false {
        didSet { updateProtectionState() }
    }

    private let placeholderContainer = UIView()
    private let publicContainer = UIView()
    private let secureCanvas: UIView?
    private let secureTextField = UITextField()
    private weak var contentView: UIView?
    private weak var placeholderView: UIView?

    override init(frame: CGRect) {
        secureTextField.isSecureTextEntry = true
        secureTextField.isUserInteractionEnabled = false
        secureCanvas = Self.makeSecureCanvas(from: secureTextField)
        super.init(frame: frame)
        setupUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setContentView(_ view: UIView) {
        contentView = view
        view.isUserInteractionEnabled = false
        updateProtectionState()
    }

    func setPlaceholderView(_ view: UIView) {
        placeholderView = view
        view.isUserInteractionEnabled = false
        install(view, in: placeholderContainer)
        updateProtectionState()
    }

    private func setupUI() {
        isUserInteractionEnabled = false
        backgroundColor = .clear
        clipsToBounds = false

        [placeholderContainer, publicContainer].forEach { container in
            container.backgroundColor = .clear
            container.isUserInteractionEnabled = false
            addSubview(container)
            pin(container, to: self)
        }

        if let secureCanvas {
            secureCanvas.backgroundColor = .clear
            secureCanvas.isUserInteractionEnabled = false
            addSubview(secureCanvas)
            pin(secureCanvas, to: self)
        }
    }

    private func updateProtectionState() {
        guard let contentView else { return }
        let hasSecureCanvas = secureCanvas != nil
        let shouldUseSecureCanvas = isProtectionEnabled && hasSecureCanvas
        let targetContainer = shouldUseSecureCanvas ? secureCanvas : publicContainer

        if let targetContainer, contentView.superview !== targetContainer {
            install(contentView, in: targetContainer)
        }

        placeholderContainer.isHidden = !isProtectionEnabled
        publicContainer.isHidden = shouldUseSecureCanvas
        secureCanvas?.isHidden = !shouldUseSecureCanvas || isObscured

        if isObscured {
            bringSubviewToFront(placeholderContainer)
        } else {
            if shouldUseSecureCanvas, let secureCanvas {
                bringSubviewToFront(secureCanvas)
            } else {
                bringSubviewToFront(publicContainer)
            }
        }
    }

    private func install(_ child: UIView, in container: UIView) {
        if child.superview !== container {
            child.removeFromSuperview()
            container.addSubview(child)
            pin(child, to: container)
        }
    }

    private func pin(_ child: UIView, to parent: UIView) {
        child.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            child.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            child.topAnchor.constraint(equalTo: parent.topAnchor),
            child.bottomAnchor.constraint(equalTo: parent.bottomAnchor)
        ])
    }

    private static func makeSecureCanvas(from textField: UITextField) -> UIView? {
        guard let canvas = textField.subviews.first else { return nil }
        canvas.subviews.forEach { $0.removeFromSuperview() }
        canvas.isUserInteractionEnabled = false
        return canvas
    }
}
