import XCTest


extension XCUIElement {
	// XCUITest only retries finding an element for a few seconds, which isn't always enough on CI.
	func waitThenTap(_ description: String, timeout: TimeInterval = 30.0) {
		if !waitForExistence(timeout: timeout) {
			XCTFail("Failed to find \(description)")
		}
		tap()
	}
}

final class JoplinUITests: XCTestCase {

	override func setUpWithError() throws {
		continueAfterFailure = false
	}

	override func tearDownWithError() throws {
	}

	@MainActor
	func testCreateNote() throws {
		let app = XCUIApplication()
		app.launch()
		app.activate()

		let mainScreen = MainScreen()
		mainScreen.waitFor(app: app)
		mainScreen.newFolder(app: app, name: "UI Tests")
		mainScreen.newNote(app: app)

		// Should be able to fill the note body
		let markdownEditor = app.textViews["Markdown editor"].firstMatch
		// The editor is rendered in a WebView, which can take a while to load on CI
		markdownEditor.waitThenTap("the Markdown editor", timeout: 60.0)
		markdownEditor.typeText("Note body.")

		let stopEditing = app.buttons["Stop editing"].firstMatch
		stopEditing.waitThenTap("the \"stop editing\" button")
		
		// Should render
		let noteBodyText = app.staticTexts["Note body."]
		let rendered = noteBodyText.waitForExistence(timeout: 60.0)
		XCTAssertTrue(rendered)
	}

	// Draws with the native PencilKit editor, saves, then edits the drawing again.
	@MainActor
	func testNativeInkDrawing() throws {
		let app = XCUIApplication()
		app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
		app.launch()
		app.activate()

		let mainScreen = MainScreen()
		mainScreen.waitFor(app: app)
		mainScreen.newFolder(app: app, name: "Ink Tests")
		mainScreen.newNote(app: app)

		let markdownEditor = app.textViews["Markdown editor"].firstMatch
		XCTAssertTrue(markdownEditor.waitForExistence(timeout: 60.0))

		app.buttons["Actions"].firstMatch.waitThenTap("the actions menu")
		app.descendants(matching: .any)["Draw picture"].firstMatch.waitThenTap("the \"draw picture\" menu item")

		let inkEditor = InkEditorScreen()
		inkEditor.waitFor(app: app)
		inkEditor.drawWord(app: app, offsetY: 0)
		attachScreenshot(app, name: "1-new-drawing")
		inkEditor.done(app: app)

		// Back in the note editor, the drawing has been attached
		XCTAssertTrue(markdownEditor.waitForExistence(timeout: 60.0))
		let linkAdded = NSPredicate(format: "value CONTAINS ':/'")
		expectation(for: linkAdded, evaluatedWith: markdownEditor)
		waitForExpectations(timeout: 30.0)
		attachScreenshot(app, name: "2-note-with-drawing")

		// Open the drawing again from the viewer (long press > Edit)
		app.buttons["Stop editing"].firstMatch.waitThenTap("the \"stop editing\" button")
		let image = app.webViews.images.firstMatch
		XCTAssertTrue(image.waitForExistence(timeout: 60.0))
		attachScreenshot(app, name: "3-viewer")
		app.webViews.firstMatch.swipeUp()
		sleep(1)
		attachScreenshot(app, name: "3b-viewer-page-2")
		app.webViews.firstMatch.swipeDown()
		sleep(1)
		editFirstImage(app)

		inkEditor.waitFor(app: app)
		attachScreenshot(app, name: "4-reopened-drawing")
		inkEditor.drawWord(app: app, offsetY: 200)
		attachScreenshot(app, name: "5-edited-drawing")
		inkEditor.done(app: app)

		XCTAssertTrue(app.webViews.images.firstMatch.waitForExistence(timeout: 60.0))
		attachScreenshot(app, name: "6-viewer-after-edit")
	}

	// A drawing made with the previous editor (js-draw) is opened in the native
	// editor as a background layer, and can be drawn on.
	//
	// Needs prepared data: run testNativeInkDrawing first, then replace the
	// drawing's resource file in the simulator with an SVG created by js-draw.
	// (Creating the js-draw drawing from the test is not possible: in the
	// simulator, long-pressing small images in the note viewer opens the system
	// image menu instead of Joplin's.)
	@MainActor
	func testOpenLegacyDrawing() throws {
		let app = XCUIApplication()
		app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
		app.launch()
		app.activate()

		let noteItem = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Drawing'")).firstMatch
		if !noteItem.waitForExistence(timeout: 30.0) {
			throw XCTSkip("No prepared note with a drawing")
		}
		if !app.webViews.images.firstMatch.waitForExistence(timeout: 5.0) {
			noteItem.tap()
		}
		attachScreenshot(app, name: "1-legacy-in-viewer")
		editFirstImage(app)

		// The user is told that the old drawing becomes a background layer
		let notice = app.alerts["Drawing from the previous editor"]
		XCTAssertTrue(notice.waitForExistence(timeout: 30.0), "Missing notice for legacy drawings")
		attachScreenshot(app, name: "2-legacy-notice")
		notice.buttons.firstMatch.tap()

		let inkEditor = InkEditorScreen()
		inkEditor.waitFor(app: app)
		inkEditor.drawWord(app: app, offsetY: 350)
		attachScreenshot(app, name: "3-legacy-in-native-editor")
		inkEditor.done(app: app)

		XCTAssertTrue(app.webViews.images.firstMatch.waitForExistence(timeout: 60.0))
		attachScreenshot(app, name: "4-viewer-after-conversion")

		// Reopening: now a PencilKit drawing, no notice any more
		editFirstImage(app)
		inkEditor.waitFor(app: app)
		XCTAssertFalse(app.alerts["Drawing from the previous editor"].waitForExistence(timeout: 3.0))
		attachScreenshot(app, name: "5-reopened")
		app.buttons["Cancel"].firstMatch.waitThenTap("the cancel button")
	}

	// Opens the first note with a drawing, edits it and saves. Used to check
	// prepared data, e.g. with a dark theme enabled.
	@MainActor
	func testEditExistingDrawing() throws {
		let app = XCUIApplication()
		app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
		app.launch()
		app.activate()

		let noteItem = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Drawing'")).firstMatch
		if !noteItem.waitForExistence(timeout: 30.0) {
			throw XCTSkip("No prepared note with a drawing")
		}
		if !app.webViews.images.firstMatch.waitForExistence(timeout: 5.0) {
			noteItem.tap()
		}
		editFirstImage(app)

		let inkEditor = InkEditorScreen()
		inkEditor.waitFor(app: app)
		inkEditor.drawWord(app: app, offsetY: 450)
		attachScreenshot(app, name: "1-editing")
		inkEditor.done(app: app)

		XCTAssertTrue(app.webViews.images.firstMatch.waitForExistence(timeout: 60.0))
		attachScreenshot(app, name: "2-viewer")
	}

	// Creates a canvas note with handwriting, a text box and two pages, saves it,
	// then opens it again.
	@MainActor
	func testCanvasNote() throws {
		let app = XCUIApplication()
		app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
		app.launch()
		app.activate()

		let mainScreen = MainScreen()
		mainScreen.waitFor(app: app)
		mainScreen.newFolder(app: app, name: "Canvas Tests")
		app.buttons["Add new"].waitThenTap("the \"add new\" button")
		app.descendants(matching: .any).matching(NSPredicate(format: "label LIKE \"*Canvas note\"")).firstMatch
			.waitThenTap("the \"canvas note\" menu item")

		let canvas = CanvasEditorScreen()
		canvas.waitFor(app: app)
		InkEditorScreen().drawWord(app: app, offsetY: 0)

		canvas.tapToolbarButton(app, "Add text box")
		sleep(1)
		app.typeText("Hallo Canvas")
		// Tap on an empty part of the page to finish editing
		app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
		attachScreenshot(app, name: "1-page-1")

		canvas.tapToolbarButton(app, "Paper")
		app.descendants(matching: .any)["Lined"].firstMatch.waitThenTap("the \"lined\" paper")

		canvas.tapToolbarButton(app, "Add page")
		sleep(2)
		InkEditorScreen().drawWord(app: app, offsetY: 0)
		attachScreenshot(app, name: "2-page-2")

		app.buttons["Done"].firstMatch.waitThenTap("the \"done\" button")

		// The viewer shows both pages
		let pages = app.webViews.images
		XCTAssertTrue(pages.firstMatch.waitForExistence(timeout: 60.0))
		let twoPages = NSPredicate(format: "count == 2")
		expectation(for: twoPages, evaluatedWith: pages)
		waitForExpectations(timeout: 30.0)
		attachScreenshot(app, name: "3-viewer")
		app.webViews.firstMatch.swipeUp()
		sleep(1)
		attachScreenshot(app, name: "3b-viewer-page-2")
		app.webViews.firstMatch.swipeDown()
		sleep(1)

		// Open it again with the edit button: the text box is still there
		app.buttons["Edit"].firstMatch.waitThenTap("the edit button")
		canvas.waitFor(app: app)
		let textBox = app.textViews.matching(NSPredicate(format: "value CONTAINS 'Hallo Canvas'")).firstMatch
		XCTAssertTrue(textBox.waitForExistence(timeout: 10.0), "The text box was not restored")
		attachScreenshot(app, name: "4-reopened")

		canvas.tapToolbarButton(app, "More")
		app.descendants(matching: .any)["Share as PDF"].firstMatch.waitThenTap("the \"share as PDF\" menu item")
		sleep(3)
		attachScreenshot(app, name: "5-share-pdf")
	}

	// Long-presses the first image in the note viewer and chooses "Edit". The
	// system image menu (Share, Save to Photos...) can appear instead of Joplin's
	// menu, so retry a few times.
	private func editFirstImage(_ app: XCUIApplication) {
		let image = app.webViews.images.firstMatch
		XCTAssertTrue(image.waitForExistence(timeout: 60.0))
		// Joplin's menu has "Open", the system image menu has "Share..." instead
		let joplinMenuOpen = app.descendants(matching: .any)["Open"].firstMatch
		for duration in [1.0, 1.5, 2.5, 0.7] {
			image.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: duration)
			if joplinMenuOpen.waitForExistence(timeout: 5.0) {
				app.descendants(matching: .any)["Edit"].firstMatch.tap()
				return
			}
			// Dismiss the system menu
			app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)).tap()
			sleep(1)
		}
		XCTFail("Failed to open the \"edit\" action")
	}

	private func attachScreenshot(_ app: XCUIApplication, name: String) {
		let attachment = XCTAttachment(screenshot: app.screenshot())
		attachment.name = name
		attachment.lifetime = .keepAlways
		add(attachment)
	}
}

class CanvasEditorScreen {
	func waitFor(app: XCUIApplication) {
		let addTextBox = app.buttons["Add text box"].firstMatch
		if !addTextBox.waitForExistence(timeout: 30.0) {
			XCTFail("Failed to find the canvas editor")
		}
		let loaded = NSPredicate(format: "isEnabled == true")
		let expectation = XCTNSPredicateExpectation(predicate: loaded, object: addTextBox)
		XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 30.0), .completed)
	}

	func tapToolbarButton(_ app: XCUIApplication, _ label: String) {
		app.buttons[label].firstMatch.waitThenTap("the \"\(label)\" button")
	}
}

class InkEditorScreen {
	func waitFor(app: XCUIApplication) {
		let done = app.buttons["Done"].firstMatch
		if !done.waitForExistence(timeout: 30.0) {
			XCTFail("Failed to find the drawing editor")
		}
		// Wait for the drawing to load
		let loaded = NSPredicate(format: "isEnabled == true")
		let expectation = XCTNSPredicateExpectation(predicate: loaded, object: done)
		XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 30.0), .completed)
	}

	// Writes "TITEL" (only straight strokes) with simulated finger strokes
	func drawWord(app: XCUIApplication, offsetY: CGFloat) {
		let origin = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
		let stroke = { (x1: CGFloat, y1: CGFloat, x2: CGFloat, y2: CGFloat) in
			let start = origin.withOffset(CGVector(dx: x1, dy: offsetY + y1))
			let end = origin.withOffset(CGVector(dx: x2, dy: offsetY + y2))
			start.press(forDuration: 0.1, thenDragTo: end, withVelocity: 300, thenHoldForDuration: 0.1)
		}
		// T
		stroke(60, 250, 140, 250)
		stroke(100, 250, 100, 370)
		// I
		stroke(170, 250, 170, 370)
		// T
		stroke(200, 250, 280, 250)
		stroke(240, 250, 240, 370)
		// E
		stroke(310, 250, 310, 370)
		stroke(310, 250, 370, 250)
		stroke(310, 310, 360, 310)
		stroke(310, 370, 370, 370)
		// L
		stroke(400, 250, 400, 370)
		stroke(400, 370, 460, 370)
	}

	func done(app: XCUIApplication) {
		app.buttons["Done"].firstMatch.waitThenTap("the \"done\" button")
	}
}

class MainScreen {
	private func sidebarToggle(_ app: XCUIApplication) -> XCUIElement {
		return app.buttons["Sidebar"]
	}

	func waitFor(app: XCUIApplication) {
		if !sidebarToggle(app).waitForExistence(timeout: 30.0) {
			assertionFailure("Failed to find the sidebar toggle")
		}
	}

	func openSidebar(app: XCUIApplication) -> SidebarScreen {
		sidebarToggle(app).firstMatch.waitThenTap("the sidebar toggle")
		return SidebarScreen()
	}
	
	func newFolder(app: XCUIApplication, name: String) {
		let sidebar = openSidebar(app: app)
		sidebar.newFolder(app: app, name: name)
	}
	
	func newNote(app: XCUIApplication) {
		app.buttons["Add new"].waitThenTap("the \"add new\" button")

		let newNoteButton = app.buttons
				.element(matching: NSPredicate(format: "label LIKE \"*New note\""))
		newNoteButton.firstMatch.waitThenTap("the \"new note\" button")
	}
}

class SidebarScreen {
	func newFolder(app: XCUIApplication, name: String) {
		let newFolderButton = app.buttons
				.element(matching: NSPredicate(format: "label LIKE \"*New Notebook\""))
		newFolderButton.firstMatch.waitThenTap("the \"new notebook\" button")

		let titleField = app.textFields["Enter notebook title"]
		titleField.firstMatch.waitThenTap("the notebook title field")
		titleField.firstMatch.typeText(name)
		
		let filledTitle = app.textFields[name]
		let found = filledTitle.waitForExistence(timeout: 10.0)
		if !found {
			// Currently, letters in rapidly typed text can be swapped (e.g. "Test" is input as "eTst").
			// This means that "found" can sometimes be false.
			// TODO: Fix this issue and fail if the typed title couldn't be found.
		}

		app.buttons["Save changes"].firstMatch.waitThenTap("the \"save changes\" button")
	}
}
