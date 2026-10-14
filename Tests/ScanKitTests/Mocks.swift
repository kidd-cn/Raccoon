import CleanKit

actor MockSnapshots: SnapshotCleanerServicing {
    let listed: [String]
    private(set) var deleted: [String] = []
    init(listed: [String] = []) { self.listed = listed }
    func listSnapshots() -> [String] { listed }
    func deleteSnapshot(_ date: String) -> Bool { deleted.append(date); return true }
}
