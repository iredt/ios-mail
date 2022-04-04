//
//  PushDataTests.swift
//  ProtonMail - Created on 30/11/2018.
//
//
//  Copyright (c) 2019 Proton Technologies AG
//
//  This file is part of ProtonMail.
//
//  ProtonMail is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  ProtonMail is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with ProtonMail.  If not, see <https://www.gnu.org/licenses/>.
    

import XCTest
@testable import ProtonMail

class PushContentTests: XCTestCase {

    func testInit_fullPayloadTypeEmail() {
        let payload = PushContentTestsData.fullPayloadTypeEmail
        let pushContent = try! PushContent(json: payload)

        XCTAssertEqual(pushContent.data.sender.address, "rosencrantz@protonmail.com")
        XCTAssertEqual(pushContent.data.sender.name, "Anatoly Rosencrantz")
        XCTAssertEqual(pushContent.data.badge, 11)
        XCTAssertEqual(pushContent.data.body, "Push push")
        XCTAssertEqual(pushContent.data.messageId, "ee_HZqOT23NjYQ-AKNZ5kv8s866qLYG0JFBFm4OMiFUxEiy1z9nEATUHPnJZrZBj2N6HK54_GM83U3qobcd1Ug==")
        XCTAssertEqual(pushContent.remoteNotificationType, .email)
    }

    func testInit_fullPayloadTypeOpenUrl() {
        let payload = PushContentTestsData.fullPayloadTypeOpenUrl
        let pushContent = try! PushContent(json: payload)

        XCTAssertEqual(pushContent.data.sender.address, "abuse@protonmail.com")
        XCTAssertEqual(pushContent.data.sender.name, "ProtonMail")
        XCTAssertEqual(pushContent.data.badge, 4)
        XCTAssertEqual(pushContent.data.body, "New login to your account on ProtonCalendar for web.")
        XCTAssertEqual(pushContent.data.messageId, "ee_HZqOT23NjYQ-AKNZ5kv8s866qLYG0JFBFm4OMiFUxEiy1z9nEATUHPnJZrZBj2N6HK54_GM83U3qobcd1Ug==")
        XCTAssertEqual(pushContent.remoteNotificationType, .openUrl)
    }
    
    func testInit_minimalPayload() {
        let payload = PushContentTestsData.minimalPayload
        let pushContent = try! PushContent(json: payload)

        XCTAssertEqual(pushContent.data.sender.address, "rosencrantz@protonmail.com")
        XCTAssertEqual(pushContent.data.sender.name, "Anatoly Rosencrantz")
        XCTAssertEqual(pushContent.data.badge, 11)
        XCTAssertEqual(pushContent.data.body, "Push push")
        XCTAssertEqual(pushContent.data.messageId, "ee_HZqOT23NjYQ-AKNZ5kv8s866qLYG0JFBFm4OMiFUxEiy1z9nEATUHPnJZrZBj2N6HK54_GM83U3qobcd1Ug==")
    }
    
    func testInit_noSenderName() {
        let payload = PushContentTestsData.payloadWithoutSenderName
        let pushContent = try! PushContent(json: payload)

        XCTAssertEqual(pushContent.data.sender.address, "rosencrantz@protonmail.com")
        XCTAssertEqual(pushContent.data.sender.name, "")
        XCTAssertEqual(pushContent.data.badge, 11)
        XCTAssertEqual(pushContent.data.body, "Push push")
        XCTAssertEqual(pushContent.data.messageId, "ee_HZqOT23NjYQ-AKNZ5kv8s866qLYG0JFBFm4OMiFUxEiy1z9nEATUHPnJZrZBj2N6HK54_GM83U3qobcd1Ug==")
    }

    func testInit_whenUnknownType() {
        let payload = PushContentTestsData.fullPayloadUnexpectedType
        let content = try! PushContent(json: payload)

        // An unknown type should not make PushContent fail, but RemoteNotificationType will be `nil`
        XCTAssert(content.type == "whatever unexpected type")
        XCTAssert(content.remoteNotificationType == nil)
    }
}

private enum PushContentTestsData {

    static let fullPayloadTypeEmail =
    """
    {
      "data": {
        "title": "ProtonMail",
        "subtitle": "",
        "body": "Push push",
        "sender": {
          "Name": "Anatoly Rosencrantz",
          "Address": "rosencrantz@protonmail.com",
          "Group": ""
        },
        "vibrate": 1,
        "sound": 1,
        "largeIcon": "large_icon",
        "smallIcon": "small_icon",
        "badge": 11,
        "messageId": "ee_HZqOT23NjYQ-AKNZ5kv8s866qLYG0JFBFm4OMiFUxEiy1z9nEATUHPnJZrZBj2N6HK54_GM83U3qobcd1Ug=="
      },
      "type": "email",
      "version": 2
    }
    """

    static let fullPayloadTypeOpenUrl =
    """
    {
      "data": {
        "body": "New login to your account on ProtonCalendar for web.",
        "sender": {
          "Name": "ProtonMail",
          "Address": "abuse@protonmail.com",
          "Group": ""
        },
        "badge": 4,
        "messageId": "ee_HZqOT23NjYQ-AKNZ5kv8s866qLYG0JFBFm4OMiFUxEiy1z9nEATUHPnJZrZBj2N6HK54_GM83U3qobcd1Ug==",
        "url": "https://protonmail.com/support/knowledge-base/display-name-and-signature/"
      },
      "type": "open_url"
    }
    """

    static let fullPayloadUnexpectedType =
    """
    {
      "data": {
        "title": "ProtonMail",
        "subtitle": "",
        "body": "Push push",
        "sender": {
          "Name": "Anatoly Rosencrantz",
          "Address": "rosencrantz@protonmail.com",
          "Group": ""
        },
        "vibrate": 1,
        "sound": 1,
        "largeIcon": "large_icon",
        "smallIcon": "small_icon",
        "badge": 11,
        "messageId": "ee_HZqOT23NjYQ-AKNZ5kv8s866qLYG0JFBFm4OMiFUxEiy1z9nEATUHPnJZrZBj2N6HK54_GM83U3qobcd1Ug=="
      },
      "type": "whatever unexpected type",
      "version": 2
    }
    """

    static let minimalPayload =
    """
    {
      "data": {
        "body": "Push push",
        "sender": {
          "Name": "Anatoly Rosencrantz",
          "Address": "rosencrantz@protonmail.com"
        },
        "badge": 11,
        "messageId": "ee_HZqOT23NjYQ-AKNZ5kv8s866qLYG0JFBFm4OMiFUxEiy1z9nEATUHPnJZrZBj2N6HK54_GM83U3qobcd1Ug=="
      }
    }
    """

    static let payloadWithoutSenderName =
    """
    {
      "data": {
        "body": "Push push",
        "sender": {
          "Name": "",
          "Address": "rosencrantz@protonmail.com"
        },
        "badge": 11,
        "messageId": "ee_HZqOT23NjYQ-AKNZ5kv8s866qLYG0JFBFm4OMiFUxEiy1z9nEATUHPnJZrZBj2N6HK54_GM83U3qobcd1Ug=="
      }
    }
    """
}
