import Cocoa
import FlutterMacOS
import XCTest
@testable import BaoCode

class RunnerTests: XCTestCase {
  private func window(fullSizeContent: Bool = true) -> BaoWindow {
    var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
    if fullSizeContent { style.insert(.fullSizeContentView) }
    let window = BaoWindow(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
      styleMask: style, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.titlebarAppearsTransparent = true
    return window
  }

  private func click(
    _ window: NSWindow, at point: NSPoint,
    type: NSEvent.EventType = .leftMouseDown, count: Int = 2
  ) -> NSEvent {
    NSEvent.mouseEvent(
      with: type, location: point, modifierFlags: .shift, timestamp: 123,
      windowNumber: window.windowNumber, context: nil, eventNumber: 7,
      clickCount: count, pressure: 0.5)!
  }

  func testFlutterClicksDoNotAlsoTriggerAppKitDoubleClick() {
    let window = window()
    defer { window.close() }
    let content = window.contentView!
    let points = [
      NSPoint(x: 300, y: 200),
      NSPoint(x: content.bounds.maxX - 36, y: content.bounds.maxY - 15),
    ]
    for point in points {
      for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        let event = click(window, at: point, type: type)
        let forwarded = window.eventForContent(event)
        XCTAssertEqual(forwarded.clickCount, 1)
        XCTAssertEqual(forwarded.type, event.type)
        XCTAssertEqual(forwarded.locationInWindow, event.locationInWindow)
        XCTAssertEqual(forwarded.modifierFlags, event.modifierFlags)
        XCTAssertEqual(forwarded.timestamp, event.timestamp)
        XCTAssertEqual(forwarded.eventNumber, event.eventNumber)
        XCTAssertEqual(forwarded.windowNumber, event.windowNumber)
        XCTAssertEqual(forwarded.pressure, event.pressure)
      }
    }
  }

  func testSingleClicksAndOtherButtonsAreUnchanged() {
    let window = window()
    defer { window.close() }
    let point = NSPoint(x: 300, y: 200)
    let single = click(window, at: point, count: 1)
    XCTAssertTrue(window.eventForContent(single) === single)
    let right = click(window, at: point, type: .rightMouseDown)
    XCTAssertTrue(window.eventForContent(right) === right)
  }

  func testNativeTitleBarAndTrafficLightsKeepTheirDoubleClicks() {
    for fullSize in [false, true] {
      let window = window(fullSizeContent: fullSize)
      defer { window.close() }
      if !fullSize {
        let title = click(window, at: NSPoint(x: 300, y: window.frame.height - 8))
        XCTAssertTrue(window.eventForContent(title) === title)
      }
      for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
        let button = window.standardWindowButton(kind)!
        let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        let event = click(window, at: point)
        XCTAssertTrue(window.eventForContent(event) === event)
      }
    }
  }
}
