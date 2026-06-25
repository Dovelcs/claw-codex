//
//  MKBTests.swift
//  MKBTests
//
//  Created by apple on 2026/5/23.
//

import Testing
@testable import MKB

struct MKBTests {

    @Test func richMessageParserDetectsCodeAndCommands() async throws {
        let text = """
        先执行：

        $ git status
        $ make -C ios-app

        ```swift
        print("ok")
        ```

        完成后检查结果。
        """

        let segments = FleetMessageParser.parse(text)

        #expect(segments.count == 4)
        #expect(segments[0].text == "先执行：")
        if case .command = segments[1].kind {
            #expect(segments[1].copyText == "git status\nmake -C ios-app")
        } else {
            Issue.record("Expected command segment")
        }
        if case .code(let language) = segments[2].kind {
            #expect(language == "swift")
            #expect(segments[2].copyText == "print(\"ok\")")
        } else {
            Issue.record("Expected code segment")
        }
        #expect(segments[3].text == "完成后检查结果。")
    }

}
