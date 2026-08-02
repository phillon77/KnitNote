import Foundation

public enum YarnLinkSelectionMerge {
    public static func merged(
        initial: Set<UUID>,
        edited: Set<UUID>,
        current: Set<UUID>
    ) -> Set<UUID> {
        let additions = edited.subtracting(initial)
        let removals = initial.subtracting(edited)
        return current.union(additions).subtracting(removals)
    }
}
