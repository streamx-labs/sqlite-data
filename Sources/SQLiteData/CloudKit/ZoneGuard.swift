#if canImport(CloudKit)
  public import CloudKit
  import ConcurrencyExtras

  /// Lets the app decide what happens to a zone the engine finds gone, and hold a zone it must not
  /// recreate yet.
  ///
  /// StreamX fork: upstream deletes every local row of a zone fetched as deleted or purged, and saves
  /// the default zone again on every start, on sign-in, after a deletion and when a send answers
  /// `zoneNotFound`. When the zone was lost rather than deleted on purpose, that wipes the last copy of
  /// the user's data and recreates an empty zone before anyone is asked. With a guard:
  /// - a fetched deletion asks `zoneDeleted` whether to delete the zone's local rows (the default) or
  ///   keep them;
  /// - a zone `isHeld` answers true for is never saved by the engine, and its pending record changes
  ///   stay pending (deletions included) without being sent, until the app lifts the hold.
  public struct ZoneGuard: Sendable {
    public enum DeletionAnswer: Sendable, Equatable {
      /// Upstream behaviour: the zone's local rows are deleted.
      case deleteLocal
      /// The zone's local rows stay. The app is expected to hold the zone (`isHeld`) while it decides.
      case keepLocal
    }

    /// Why the zone is gone, as CloudKit reports it (`.deleted` or `.purged`; an encrypted-data reset is
    /// the engine's own and never asked about).
    public enum DeletionReason: Sendable, Equatable {
      case deleted
      case purged
    }

    public var isHeld: @Sendable (_ zoneID: CKRecordZone.ID) -> Bool
    public var zoneDeleted:
      @Sendable (
        _ zoneID: CKRecordZone.ID,
        _ reason: DeletionReason,
        _ scope: CKDatabase.Scope
      ) -> DeletionAnswer

    public init(
      isHeld: @escaping @Sendable (_ zoneID: CKRecordZone.ID) -> Bool,
      zoneDeleted: @escaping @Sendable (
        _ zoneID: CKRecordZone.ID,
        _ reason: DeletionReason,
        _ scope: CKDatabase.Scope
      ) -> DeletionAnswer
    ) {
      self.isHeld = isHeld
      self.zoneDeleted = zoneDeleted
    }
  }

  let nextEngineZoneGuard = LockIsolated<ZoneGuard?>(nil)

  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  extension SyncEngine {
    /// Sets the guard the next `SyncEngine` created takes for its whole life. Call it before creating
    /// the engine: one created with `startImmediately` saves its zone at start.
    public static func setNextEngineZoneGuard(_ zoneGuard: ZoneGuard?) {
      nextEngineZoneGuard.setValue(zoneGuard)
    }

    /// Replaces this engine's guard (tests).
    public func setZoneGuard(_ zoneGuard: ZoneGuard?) {
      self.zoneGuard.setValue(zoneGuard)
    }

    func isHeld(_ zoneID: CKRecordZone.ID) -> Bool {
      zoneGuard.value?.isHeld(zoneID) ?? false
    }

    /// Removes the queued save of every zone held now, on both engines. The app calls it when a hold
    /// starts, so a save queued earlier is gone whatever order CKSyncEngine reads its pending changes in
    /// around `willSendChanges`.
    public func dropHeldZoneSaves() {
      guard syncEngines.withValue(\.isRunning) else { return }
      let engines = syncEngines.withValue { [$0.private, $0.shared] }
      for engine in engines {
        if let engine { dropHeldZoneSaves(syncEngine: engine) }
      }
    }

    /// Removes the queued save of every zone held now. Run just before a send and after a fetched
    /// deletion: a hold can start after its zone's save was queued.
    package func dropHeldZoneSaves(syncEngine: any SyncEngineProtocol) {
      guard zoneGuard.value != nil else { return }
      let heldSaves = syncEngine.state.pendingDatabaseChanges.filter { change in
        switch change {
        case .saveZone(let zone): isHeld(zone.zoneID)
        case .deleteZone: false
        @unknown default: false
        }
      }
      guard !heldSaves.isEmpty else { return }
      syncEngine.state.remove(pendingDatabaseChanges: heldSaves)
    }
  }
#endif
