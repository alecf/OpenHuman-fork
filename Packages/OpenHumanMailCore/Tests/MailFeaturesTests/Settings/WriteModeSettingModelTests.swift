import Foundation
import Testing
@testable import MailFeatures

@MainActor
private final class RecordingSwitch: WriteModeSwitching {
    var allowsChanges: Bool
    let launchSource: WriteModeLaunchSource
    var writesNow: Bool
    var saved: [Bool] = []
    var reopened = 0
    var refuses = false

    init(on: Bool = false, source: WriteModeLaunchSource = .setting, writes: Bool = false) {
        allowsChanges = on
        launchSource = source
        writesNow = writes
    }

    func save(_ allowsChanges: Bool) throws {
        if refuses { throw CocoaError(.fileWriteNoPermission) }
        saved.append(allowsChanges)
        self.allowsChanges = allowsChanges
    }

    func reopen() { reopened += 1 }
}

@MainActor
@Suite struct WriteModeSettingModelTests {
    @Test func onAsksFirstAndCancelSavesNothing() {
        let port = RecordingSwitch()
        let model = WriteModeSettingModel(port: port)
        #expect(!model.isOn && model.status == nil)
        model.request(true)
        #expect(model.isConfirming && !model.isOn && port.saved.isEmpty, "the sheet, nothing saved")
        model.cancel()
        #expect(!model.isConfirming && !model.isOn && port.saved.isEmpty && port.reopened == 0)
        model.confirm()
        #expect(port.saved.isEmpty, "confirm without the sheet does nothing")
    }

    @Test func confirmSavesThenReopensWhenTheSwitchDecidesTheLaunch() {
        let port = RecordingSwitch()
        let model = WriteModeSettingModel(port: port)
        model.request(true)
        model.confirm()
        #expect(model.isOn && !model.isConfirming && port.saved == [true] && port.reopened == 1)

        let forced = RecordingSwitch(source: .environmentReadOnly)
        let readOnly = WriteModeSettingModel(port: forced)
        readOnly.request(true)
        readOnly.confirm()
        #expect(forced.saved == [true] && forced.reopened == 0)
        #expect(readOnly.status?.contains("OPENHUMAN_SAFE_MODE is set and keeps this launch read-only") == true)

        let terminal = RecordingSwitch(source: .environmentNormal, writes: true)
        let normal = WriteModeSettingModel(port: terminal)
        normal.request(true)
        normal.confirm()
        #expect(terminal.saved == [true] && terminal.reopened == 0)
    }

    @Test func offIsImmediateAndReopensReadOnlyOnlyWhileTheWindowWrites() {
        let writing = RecordingSwitch(on: true, writes: true)
        let model = WriteModeSettingModel(port: writing)
        model.request(false)
        #expect(!model.isOn && !model.isConfirming && writing.saved == [false] && writing.reopened == 1)

        let idle = RecordingSwitch(on: true, writes: false)
        let readOnly = WriteModeSettingModel(port: idle)
        #expect(readOnly.status?.hasPrefix("This window is read-only for now.") == true)
        readOnly.request(false)
        #expect(idle.saved == [false] && idle.reopened == 0)
    }

    @Test func aRefusedSaveChangesNothingAndSaysSo() {
        let port = RecordingSwitch(on: true, writes: true)
        port.refuses = true
        let model = WriteModeSettingModel(port: port)
        model.request(false)
        #expect(model.isOn && port.reopened == 0 && model.errorMessage != nil)
    }

    @Test func theSheetSaysPlainlyWhatChanges() {
        let text = WriteModeSettingModel.sheetPoints.joined(separator: " ")
        for words in ["Archive", "star", "send", "real Gmail", "Permanent delete", "Gmail settings", "stay impossible",
                      "⌘Z undoes most changes"] {
            #expect(text.contains(words), "\(words)")
        }
        #expect(!text.contains("turn it off"))
        #expect(WriteModeSettingModel.title == "Allow changes to my mailbox (write mode)")
        #expect(WriteModeSession.allowChanges.name == "write_mode.allow_changes")
        #expect(WriteModeSession.allowChanges.defaultValue == true && WriteModeSession.allowChanges.isSafetyKey,
                "on by default (WRITE-MODE-DEFAULT); still a safety key, so an unreadable value is off")
    }

    @Test func theRowShowsOnlyWhereChangesWereSavedOff() {
        #expect(!WriteModeSettingModel(port: RecordingSwitch(on: true, writes: true)).isShown, "the default: no row")
        let off = RecordingSwitch(on: false)
        let model = WriteModeSettingModel(port: off)
        #expect(model.isShown)
        model.request(true)
        #expect(model.isShown, "still shown while the sheet asks")
        model.confirm()
        #expect(!model.isShown && off.saved == [true] && off.reopened == 1)
        #expect(!WriteModeSettingModel.detail.contains("Off:"), "the row never offers read-only")
    }
}
