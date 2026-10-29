import Foundation
import Testing
@testable import ServerFinderCore

@Suite struct ServerAddressTests {
    private func address(_ string: String) -> String? {
        ServerAddress(URL(string: string)!)?.normalized
    }

    @Test func dropsUserNameAndIgnoresCase() {
        #expect(address("smb://admin@fileserver/Projects") == "smb://fileserver/projects")
        #expect(address("SMB://FILESERVER/PROJECTS/") == "smb://fileserver/projects")
        #expect(address("smb://user:secret@fileserver/Share") == "smb://fileserver/share")
    }

    @Test func decodesSpacesAndAccents() {
        #expect(address("smb://fileserver/Dise%C3%B1o%20Gr%C3%A1fico") == "smb://fileserver/diseño gráfico")
    }

    @Test func sameShareMatchesWhateverTheMountName() {
        let first = ServerAddress(URL(string: "smb://admin@fileserver/Projects")!)
        let second = ServerAddress(URL(string: "smb://otro@fileserver/projects")!)
        #expect(first == second)
        #expect(first != ServerAddress(URL(string: "smb://fileserver/Accounting")!))
    }

    @Test func keepsANonStandardPort() {
        #expect(address("smb://fileserver:4445/Share") == "smb://fileserver:4445/share")
    }

    @Test func localPathsAreNotServerAddresses() {
        #expect(ServerAddress(URL(fileURLWithPath: "/Volumes/Stats")) == nil)
    }
}

@Suite struct RescanScheduleTests {
    let now = Date(timeIntervalSince1970: 1_000_000)

    @Test func neverIndexedIsAlwaysDue() {
        #expect(RescanSchedule.isDue(lastIndexedAt: nil, interval: nil, now: now))
        #expect(RescanSchedule.isDue(lastIndexedAt: nil, interval: 7_200, now: now))
    }

    @Test func dueOnceTheIntervalHasPassed() {
        #expect(!RescanSchedule.isDue(lastIndexedAt: now.addingTimeInterval(-7_199), interval: 7_200, now: now))
        #expect(RescanSchedule.isDue(lastIndexedAt: now.addingTimeInterval(-7_200), interval: 7_200, now: now))
    }

    @Test func automaticRescansCanBeTurnedOff() {
        #expect(!RescanSchedule.isDue(lastIndexedAt: now.addingTimeInterval(-1_000_000), interval: nil, now: now))
    }
}
