import XCTest
@testable import BitClipboardCore

final class TextExtractionTests: XCTestCase {
    func testChineseProseImmediatelyFollowingDomainIsNotPartOfLink() {
        XCTAssertEqual(TextExtraction.extract(from: "https://blog.alphazero.top测试"), [
            ExtractedToken(kind: .link, value: "https://blog.alphazero.top")
        ])
        XCTAssertEqual(TextExtraction.extract(from: "官网www.apple.com说明，访问https://example.com测试").map(\.value),
                       ["www.apple.com", "https://example.com"])
    }

    func testNumbersAfterDomainAndChineseProseStillExtract() {
        XCTAssertEqual(TextExtraction.extract(from: "https://blog.alphazero.top验证码001234"), [
            ExtractedToken(kind: .link, value: "https://blog.alphazero.top"),
            ExtractedToken(kind: .number, value: "001234")
        ])
    }

    func testUnicodePathsQueriesAndFragmentsArePreserved() {
        let urls = ["https://example.com/中文路径?q=测试&code=42#章节", "https://example.com?查询=中文", "https://example.com/#中文"]
        for url in urls {
            XCTAssertEqual(TextExtraction.extract(from: url + "。"), [ExtractedToken(kind: .link, value: url)])
            XCTAssertTrue(TextExtraction.isStandaloneLink(url))
        }
    }

    func testInternationalDomainsPortsAndIPAddresses() {
        for url in ["https://例子.中国/路径", "https://例子.com/路径", "https://xn--fsqu00a.xn--fiqs8s/", "http://localhost:3000/path", "http://127.0.0.1:8080/path", "http://[::1]:3000/path"] {
            XCTAssertEqual(TextExtraction.extract(from: url), [ExtractedToken(kind: .link, value: url)])
        }
    }

    func testStandaloneLinkClassificationUsesTheSameBoundary() {
        XCTAssertTrue(TextExtraction.isStandaloneLink("https://blog.alphazero.top"))
        XCTAssertTrue(TextExtraction.isStandaloneLink("www.apple.com"))
        XCTAssertFalse(TextExtraction.isStandaloneLink("https://blog.alphazero.top测试"))
        XCTAssertFalse(TextExtraction.isStandaloneLink("参考https://example.com"))
        XCTAssertFalse(TextExtraction.isStandaloneLink("https://"))
    }

    func testChineseTextAndEmojiKeepNumbersExactly() {
        let tokens = TextExtraction.extract(from: "🔒验证码001234，金额-12.50，折扣15%，数量8。")
        XCTAssertEqual(tokens.map(\.value), ["001234", "-12.50", "15%", "8"])
        XCTAssertTrue(tokens.allSatisfy { $0.kind == .number })
    }

    func testURLNumbersAreNotExtractedSeparately() {
        let tokens = TextExtraction.extract(from: "验证码123456，访问：https://example.com:8080/path/42?code=123456。")
        XCTAssertEqual(tokens, [
            ExtractedToken(kind: .number, value: "123456"),
            ExtractedToken(kind: .link, value: "https://example.com:8080/path/42?code=123456")
        ])
    }

    func testDuplicatesPreserveFirstOccurrenceOrder() {
        let tokens = TextExtraction.extract(from: "www.apple.com 007 007 https://example.com www.apple.com 12")
        XCTAssertEqual(tokens.map(\.value), ["www.apple.com", "007", "https://example.com", "12"])
        XCTAssertEqual(tokens.map(\.kind), [.link, .number, .link, .number])
    }

    func testSentencePunctuationAndBalancedURLParentheses() {
        let tokens = TextExtraction.extract(from: "(https://en.wikipedia.org/wiki/Swift_(programming_language)). https://example.com/test?!")
        XCTAssertEqual(tokens.map(\.value), ["https://en.wikipedia.org/wiki/Swift_(programming_language)", "https://example.com/test"])
    }

    func testNoPartialNumbersInsideIdentifiers() {
        let tokens = TextExtraction.extract(from: "foo123bar build_42 v2 没有数字 1,234.56 +86")
        XCTAssertEqual(tokens.map(\.value), ["1,234.56", "+86"])
        XCTAssertTrue(TextExtraction.extract(from: "普通文字，没有可提取的内容。").isEmpty)
    }
}
