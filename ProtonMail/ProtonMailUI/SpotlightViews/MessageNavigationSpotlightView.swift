// Copyright (c) 2023 Proton Technologies AG
//
// This file is part of Proton Mail.
//
// Proton Mail is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// Proton Mail is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with Proton Mail. If not, see https://www.gnu.org/licenses/.

import SwiftUI

public struct MessageNavigationSpotlightView: View {
    public let config = HostingProvider()
    let buttonTitle: String
    let message: String
    let title: String
    var closeAction: ((UIViewController?) -> Void)?

    public init(
        buttonTitle: String,
        message: String,
        title: String,
        closeAction: ((UIViewController?) -> Void)? = nil
    ) {
        self.buttonTitle = buttonTitle
        self.message = message
        self.title = title
        self.closeAction = closeAction
    }

    public var body: some View {
        SheetLikeSpotlightView(
            config: config,
            buttonTitle: buttonTitle,
            closeAction: closeAction,
            message: message,
            spotlightImage: ImageAsset.messageNavigationSpotlight,
            title: title,
            imageAlignBottom: true
        )
    }
}

#Preview {
    MessageNavigationSpotlightView(
        buttonTitle: "Got it",
        message: "You can now effortlessly navigate through messages  by swiping left or right.",
        title: "Jump to next message"
    )
}
