import ComposeCore
import XCTest

final class InterpolationTests: XCTestCase {
  func testComposeOperators() throws {
    let subject = Interpolator(environment: ["SET": "value", "EMPTY": ""])

    XCTAssertEqual(try subject.interpolate("${SET}"), "value")
    XCTAssertEqual(try subject.interpolate("${UNSET-default}"), "default")
    XCTAssertEqual(try subject.interpolate("${EMPTY-default}"), "")
    XCTAssertEqual(try subject.interpolate("${EMPTY:-default}"), "default")
    XCTAssertEqual(try subject.interpolate("${SET+alternate}"), "alternate")
    XCTAssertEqual(try subject.interpolate("${EMPTY+alternate}"), "alternate")
    XCTAssertEqual(try subject.interpolate("${EMPTY:+alternate}"), "")
    XCTAssertEqual(try subject.interpolate("${UNSET:-${SET}}"), "value")
    XCTAssertEqual(try subject.interpolate("$SET $$ ${SET}"), "value $ value")
  }

  func testRequiredOperatorsDoNotExposeEnvironmentValues() throws {
    let subject = Interpolator(environment: ["SECRET": "do-not-print"])

    XCTAssertThrowsError(try subject.interpolate("${MISSING?provide it}")) { error in
      XCTAssertEqual((error as? ComposeError)?.message, "provide it")
      XCTAssertFalse(String(describing: error).contains("do-not-print"))
    }
    XCTAssertThrowsError(
      try Interpolator(environment: ["EMPTY": ""]).interpolate("${EMPTY:?cannot be empty}"))
  }
}
