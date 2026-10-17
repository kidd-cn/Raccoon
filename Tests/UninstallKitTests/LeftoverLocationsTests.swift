import Testing
import Foundation
import CleanKit
@testable import UninstallKit

@Suite
final class LeftoverLocationsTests {
    @Test func tableHasExpectedIDsAndGrading() {
        let ids = LeftoverLocations.all.map(\.id)
        #expect(Set(ids).count == ids.count)   // 唯一
        #expect(ids == ids.sorted())           // 有序:Task 5/6 的「先命中者胜出」依赖此不变量
        let byID = Dictionary(uniqueKeysWithValues: LeftoverLocations.all.map { ($0.id, $0) })
        #expect(Set(byID.keys) == [
            "caches", "logs", "webkit", "httpstorages", "saved-state", "launch-agents",
            "app-support", "containers", "group-containers", "app-scripts",
            "app-support-name", "logs-name",
        ])
        #expect(byID["caches"]?.safety == .regenerable)
        #expect(byID["logs"]?.safety == .regenerable)
        #expect(byID["webkit"]?.safety == .userData)
        #expect(byID["httpstorages"]?.safety == .regenerable)
        #expect(byID["saved-state"]?.safety == .regenerable)
        #expect(byID["launch-agents"]?.safety == .regenerable)
        #expect(byID["app-support"]?.safety == .userData)
        #expect(byID["containers"]?.safety == .userData)
        #expect(byID["group-containers"]?.safety == .userData)
        #expect(byID["app-scripts"]?.safety == .userData)
        #expect(byID["logs-name"]?.safety == .regenerable)
        #expect(byID["app-support-name"]?.safety == .userData)
        #expect(byID["saved-state"]?.match == .exactSuffixed(".savedState"))
        #expect(byID["launch-agents"]?.match == .exactSuffixed(".plist"))
        #expect(byID["group-containers"]?.match == .groupContainer)
        #expect(byID["app-support-name"]?.match == .appName)
        #expect(byID["logs-name"]?.match == .appName)
        let folders = Dictionary(grouping: LeftoverLocations.all, by: \.id).mapValues { $0[0].folder }
        #expect(folders == [
            "app-scripts": "Application Scripts",
            "app-support": "Application Support",
            "app-support-name": "Application Support",
            "caches": "Caches",
            "containers": "Containers",
            "group-containers": "Group Containers",
            "httpstorages": "HTTPStorages",
            "launch-agents": "LaunchAgents",
            "logs": "Logs",
            "logs-name": "Logs",
            "saved-state": "Saved Application State",
            "webkit": "WebKit",
        ])
    }

    @Test func excludedFoldersNeverEnterTableAndAreDenied() {
        let folders = Set(LeftoverLocations.all.map(\.folder))
        #expect(folders.isDisjoint(with: LeftoverLocations.excludedFolders))
        let protection = ProtectionStore()
        let home = NSHomeDirectory()
        for folder in LeftoverLocations.excludedFolders {
            #expect(protection.isDenied("\(home)/Library/\(folder)/com.example.foo"))
        }
    }

    // 事实断言:一期硬保护整棵覆盖 Preferences/Cookies,二期不列出这两处(列了也删不掉)。
    // 若有人放松硬保护,此测会红,提醒同步二期方案。
    @Test func preferencesAndCookiesAreHardProtected() {
        let home = NSHomeDirectory()
        let protection = ProtectionStore()
        #expect(protection.isDenied("\(home)/Library/Preferences/com.example.foo.plist"))
        #expect(protection.isDenied("\(home)/Library/Cookies/com.example.foo.binarycookies"))
        #expect(!protection.isDenied("\(home)/Library/Caches/com.example.foo"))
    }
}
