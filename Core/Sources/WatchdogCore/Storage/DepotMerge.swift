import Foundation

/// Mac and iPhone both edit the one depot file in iCloud Drive. Before saving, each reads the file again and keeps
/// what the other device changed meanwhile: per value, bank and theme, and per settings block.
///
/// `base` is the state this device last read or wrote, `mine` what it wants to save, `theirs` what is in the file now.
/// Whatever this device changed against `base` wins; everything else comes from `theirs`.
/// When both changed the same value, this device's change wins (it is the later one); the hourly backup keeps the other.
public enum DepotMerge {
    public static func merge(base: DepotFile, mine: DepotFile, theirs: DepotFile) -> DepotFile {
        var out = theirs
        out.positions = mergeList(base.positions, mine.positions, theirs.positions)
        out.banks = mergeList(base.banks, mine.banks, theirs.banks)
        out.themes = mergeList(base.themes, mine.themes, theirs.themes)
        if !same(base.rules, mine.rules) { out.rules = mine.rules }
        if !same(base.exchanges, mine.exchanges) { out.exchanges = mine.exchanges }
        if !same(base.sources, mine.sources) { out.sources = mine.sources }
        if !same(base.notifications, mine.notifications) { out.notifications = mine.notifications }
        out.schemaVersion = max(mine.schemaVersion, theirs.schemaVersion)
        // A bank or theme deleted on one device leaves no dangling references in values the other device edited.
        let banks = Set(out.banks.map(\.id)), themes = Set(out.themes.map(\.id))
        for i in out.positions.indices {
            if let b = out.positions[i].bankID, !banks.contains(b) { out.positions[i].bankID = nil }
            if let t = out.positions[i].themeID, !themes.contains(t) { out.positions[i].themeID = nil }
        }
        return out
    }

    /// Whether saving `mine` would lose something from the file: the file changed since `base`.
    public static func fileChanged(base: DepotFile, theirs: DepotFile) -> Bool {
        !same(base.positions, theirs.positions) || !same(base.banks, theirs.banks) || !same(base.themes, theirs.themes)
            || !same(base.rules, theirs.rules) || !same(base.exchanges, theirs.exchanges) || !same(base.sources, theirs.sources)
            || !same(base.notifications, theirs.notifications)
    }

    /// Three-way merge of a list by id. Order: as in `theirs`, then what only this device added (in its order).
    static func mergeList<T: Codable & Identifiable>(_ base: [T], _ mine: [T], _ theirs: [T]) -> [T] where T.ID == UUID {
        let b = Dictionary(base.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let m = Dictionary(mine.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [T] = []
        var seen = Set<UUID>()
        for t in theirs {
            seen.insert(t.id)
            if let old = b[t.id] {
                guard let my = m[t.id] else {
                    // Deleted here. If the other device changed it meanwhile, the deletion still wins; the backup keeps it.
                    continue
                }
                out.append(same(old, my) ? t : my)
            } else {
                // Added by the other device (or by both with the same id: take mine).
                out.append(m[t.id] ?? t)
            }
        }
        for x in mine where !seen.contains(x.id) {
            // Added here, or still here but deleted by the other device: an unchanged one stays deleted, a changed one comes back.
            if let old = b[x.id] {
                if !same(old, x) { out.append(x) }
            } else {
                out.append(x)
            }
        }
        return out
    }

    static func same<T: Encodable>(_ a: T, _ b: T) -> Bool {
        let e = DepotStore.encoder()
        return (try? e.encode(a)) == (try? e.encode(b))
    }
}

public extension DepotStore {
    /// Saves `mine` without losing what another device wrote since `base`. Returns what was written,
    /// which becomes the new base (and the app's state, if the other device had changed something).
    func saveMerging(_ mine: DepotFile, base: DepotFile?) throws -> DepotFile {
        var result = mine
        if let base, exists, let theirs = try? load(), DepotMerge.fileChanged(base: base, theirs: theirs) {
            result = DepotMerge.merge(base: base, mine: mine, theirs: theirs)
        }
        try save(result)
        return (try? load()) ?? result
    }
}
