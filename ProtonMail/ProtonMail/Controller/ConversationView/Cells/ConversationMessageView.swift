import ProtonCore_UIFoundations
import UIKit

class ConversationMessageView: UIView {

    var tapAction: (() -> Void)?

    let cellControl = UIControl(frame: .zero)
    let container = SubviewsFactory.container

    let contentStackView = UIStackView.stackView(axis: .horizontal, alignment: .center, spacing: 4)
    let initialsContainer = SubviewsFactory.initialsContainer
    let initialsLabel = UILabel.initialsLabel
    let initialsIcon = SubviewsFactory.draftIconImageView
    let initialsView = UIView()

    let replyImageView = SubviewsFactory.replyImageView
    let replyAllImageView = SubviewsFactory.replyAllImageView
    let forwardImageView = SubviewsFactory.forwardImageView

    let senderLabel = UILabel()
    let attachmentImageView = SubviewsFactory.attachmentImageView
    let starImageView = SubviewsFactory.starImageView

    let originImageView = SubviewsFactory.originImageView

    let timeLabel = UILabel()

    let spacer = UIView()

    let expirationView = SubviewsFactory.expirationView
    let tagsView = ConversationMessageViewTags()

    init() {
        super.init(frame: .zero)
        addSubviews()
        setUpLayout()
        setUpActions()
    }

    private func addSubviews() {
        addSubview(cellControl)
        cellControl.addSubview(container)
        container.addSubview(contentStackView)

        initialsView.addSubview(initialsContainer)
        initialsView.addSubview(initialsIcon)
        initialsContainer.addSubview(initialsLabel)

        contentStackView.addArrangedSubview(initialsView)
        contentStackView.addArrangedSubview(replyImageView)
        contentStackView.addArrangedSubview(replyAllImageView)
        contentStackView.addArrangedSubview(forwardImageView)
        contentStackView.addArrangedSubview(StackViewContainer(view: senderLabel, bottom: -3))
        contentStackView.addArrangedSubview(expirationView)
        contentStackView.addArrangedSubview(tagsView)
        contentStackView.addArrangedSubview(spacer)
        contentStackView.addArrangedSubview(attachmentImageView)
        contentStackView.addArrangedSubview(starImageView)
        contentStackView.addArrangedSubview(originImageView)
        contentStackView.addArrangedSubview(timeLabel)
    }

    private func setUpLayout() {
        [
            cellControl.topAnchor.constraint(equalTo: topAnchor),
            cellControl.leadingAnchor.constraint(equalTo: leadingAnchor),
            cellControl.trailingAnchor.constraint(equalTo: trailingAnchor),
            cellControl.bottomAnchor.constraint(equalTo: bottomAnchor)
        ].activate()

        [
            container.topAnchor.constraint(equalTo: cellControl.topAnchor, constant: 4),
            container.leadingAnchor.constraint(equalTo: cellControl.leadingAnchor, constant: 4),
            container.trailingAnchor.constraint(equalTo: cellControl.trailingAnchor, constant: -4),
            container.bottomAnchor.constraint(equalTo: cellControl.bottomAnchor, constant: -4)
        ].activate()

        [
            contentStackView.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            contentStackView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            contentStackView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            contentStackView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12)
        ].activate()

        [
            initialsContainer.topAnchor.constraint(greaterThanOrEqualTo: initialsView.topAnchor),
            initialsContainer.leadingAnchor.constraint(greaterThanOrEqualTo: initialsView.leadingAnchor),
            initialsContainer.trailingAnchor.constraint(lessThanOrEqualTo: initialsView.trailingAnchor),
            initialsContainer.bottomAnchor.constraint(lessThanOrEqualTo: initialsView.bottomAnchor),
            initialsContainer.heightAnchor.constraint(equalToConstant: 28),
            initialsContainer.widthAnchor.constraint(equalToConstant: 28)
        ].activate()

        [
            initialsLabel.centerYAnchor.constraint(equalTo: initialsContainer.centerYAnchor),
            initialsLabel.leadingAnchor.constraint(equalTo: initialsContainer.leadingAnchor, constant: 2),
            initialsLabel.trailingAnchor.constraint(equalTo: initialsContainer.trailingAnchor, constant: -2)
        ].activate()

        [
            initialsIcon.centerXAnchor.constraint(equalTo: initialsView.centerXAnchor),
            initialsIcon.centerYAnchor.constraint(equalTo: initialsView.centerYAnchor)
        ].activate()

        [
            initialsView.heightAnchor.constraint(equalToConstant: 28),
            initialsView.widthAnchor.constraint(equalToConstant: 28)
        ].activate()

        contentStackView.setCustomSpacing(4, after: initialsView)

        senderLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        senderLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    private func setUpActions() {
        cellControl.addTarget(self, action: #selector(cellTapped), for: .touchUpInside)
    }

    @objc private func cellTapped() {
        tapAction?()
    }

    required init?(coder: NSCoder) {
        nil
    }

}

private enum SubviewsFactory {

    static var attachmentImageView: UIImageView {
        let imageView = UIImageView(frame: .zero)
        imageView.contentMode = .scaleAspectFit
        imageView.image = Asset.mailAttachment.image
        imageView.tintColor = UIColorManager.IconWeak
        return imageView
    }

    static var starImageView: UIImageView {
        let imageView = UIImageView(frame: .zero)
        imageView.contentMode = .scaleAspectFit
        imageView.image = Asset.mailStar.image
        return imageView
    }

    static var originImageView: UIImageView {
        let imageView = UIImageView(frame: .zero)
        imageView.contentMode = .scaleAspectFit
        return imageView
    }

    static var draftIconImageView: UIImageView {
        let imageView = UIImageView(frame: .zero)
        imageView.image = Asset.mailDraftIcon.image
        imageView.tintColor = UIColorManager.IconNorm
        imageView.contentMode = .scaleAspectFit
        return imageView
    }

    static var container: UIView {
        let view = UIView()
        view.backgroundColor = UIColorManager.BackgroundNorm
        view.layer.cornerRadius = 6
        view.layer.apply(shadow: .custom(y: 1))
        view.isUserInteractionEnabled = false
        return view
    }

    static var initialsContainer: UIView {
        let view = UIView()
        view.backgroundColor = UIColorManager.InteractionWeak
        view.layer.cornerRadius = 6
        view.isUserInteractionEnabled = false
        return view
    }

    static var expirationView: TagIconView {
        let tagView = TagIconView()
        tagView.imageView.image = Asset.iconHourglass.image
        tagView.backgroundColor = UIColorManager.InteractionWeak
        return tagView
    }

    static var forwardImageView: UIImageView {
        imageView(Asset.mailForward.image)
    }

    static var replyImageView: UIImageView {
        imageView(Asset.mailReply.image)
    }

    static var replyAllImageView: UIImageView {
        imageView(Asset.mailReplyAll.image)
    }

    private static func imageView(_ image: UIImage) -> UIImageView {
        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFit
        imageView.image = image
        return imageView
    }

}
