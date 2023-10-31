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

import Foundation

extension UserDefaultsKeys {
    static let cachedServerNotices = UserDefaultsKey<[String]>(name: "cachedServerNotices", defaultValue: [])

    static let firstRunDate = UserDefaultsKey<Date?>(name: "firstRunDate", defaultValue: nil)

    static let lastBugReport = UserDefaultsKey<String>(name: "BugReportCache_LastBugReport", defaultValue: "")

    static let referralProgramPromptWasShown = UserDefaultsKey<Bool>(
        name: "referralProgramPromptWasShown",
        defaultValue: false
    )

    static let showServerNoticesNextTime = UserDefaultsKey<String>(name: "showServerNoticesNextTime", defaultValue: "0")

    /// It is used to check if the spotlight view should be shown for the user that has a
    /// standard toolbar action setting.
    static let toolbarCustomizeSpotlightShownUserIds = UserDefaultsKey<[String]>(
        name: "toolbarCustomizeSpotlightShownUserIds",
        defaultValue: []
    )
}
