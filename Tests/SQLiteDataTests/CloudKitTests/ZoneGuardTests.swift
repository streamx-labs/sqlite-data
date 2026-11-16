#if canImport(CloudKit)
  import CloudKit
  import ConcurrencyExtras
  import SQLiteData
  import Testing

  extension BaseCloudKitTests {
    /// StreamX fork: the app keeps a lost zone's rows and holds the zone, which the engine then never
    /// recreates nor sends to, until the hold is lifted.
    @MainActor
    final class ZoneGuardTests: BaseCloudKitTests, @unchecked Sendable {
      private func held(_ zones: LockIsolated<Set<String>>, keep: Bool) -> ZoneGuard {
        ZoneGuard(
          isHeld: { zones.value.contains($0.zoneName) },
          zoneDeleted: { _, _, _ in keep ? .keepLocal : .deleteLocal }
        )
      }

      private func zoneExists(_ zoneID: CKRecordZone.ID) -> Bool {
        syncEngine.private.database.state.withValue { $0.storage[zoneID] != nil }
      }

      private var savesDefaultZone: Bool {
        syncEngine.private.state.pendingDatabaseChanges.contains(.saveZone(syncEngine.defaultZone))
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func aKeptZoneDeletionLeavesTheRowsAndDoesNotRecreateAHeldZone() async throws {
        try await userDatabase.userWrite { db in
          try db.seed { RemindersList(id: 1, title: "Personal") }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        let zones = LockIsolated<Set<String>>([syncEngine.defaultZone.zoneID.zoneName])
        syncEngine.setZoneGuard(held(zones, keep: true))
        syncEngine.private.state.removePendingChanges()

        await syncEngine.handleEvent(
          SyncEngine.Event.fetchedDatabaseChanges(
            modifications: [],
            deletions: [(syncEngine.defaultZone.zoneID, .purged)]
          ),
          syncEngine: syncEngine.private
        )

        try await userDatabase.read { db in
          try #expect(RemindersList.count().fetchOne(db) == 1)
        }
        #expect(!savesDefaultZone)
      }

      /// Without an answer to keep, upstream behaviour: the rows go and the zone is saved again.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func theDefaultAnswerDeletesAsUpstream() async throws {
        try await userDatabase.userWrite { db in
          try db.seed { RemindersList(id: 1, title: "Personal") }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        syncEngine.setZoneGuard(held(LockIsolated([]), keep: false))
        syncEngine.private.state.removePendingChanges()

        await syncEngine.handleEvent(
          SyncEngine.Event.fetchedDatabaseChanges(
            modifications: [],
            deletions: [(syncEngine.defaultZone.zoneID, .deleted)]
          ),
          syncEngine: syncEngine.private
        )

        try await userDatabase.read { db in
          try #expect(RemindersList.count().fetchOne(db) == 0)
        }
        #expect(savesDefaultZone)
        syncEngine.private.state.removePendingChanges()
      }

      /// A held zone's edits and deletions stay pending and are not sent; lifting the hold sends them.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func aHeldZonesChangesStayPendingUnsent() async throws {
        try await userDatabase.userWrite { db in
          try db.seed {
            RemindersList(id: 1, title: "Keep")
            RemindersList(id: 2, title: "Delete")
          }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        let zones = LockIsolated<Set<String>>([syncEngine.defaultZone.zoneID.zoneName])
        syncEngine.setZoneGuard(held(zones, keep: true))

        try await userDatabase.userWrite { db in
          try RemindersList.find(1).update { $0.title = "Edited" }.execute(db)
          try RemindersList.find(2).delete().execute(db)
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        #expect(syncEngine.pendingPrivateRecordZoneChanges.contains(.saveRecord(RemindersList.recordID(for: 1))))
        #expect(syncEngine.pendingPrivateRecordZoneChanges.contains(.deleteRecord(RemindersList.recordID(for: 2))))
        #expect((try? syncEngine.private.database.record(for: RemindersList.recordID(for: 2))) != nil)

        zones.withValue { $0.removeAll() }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        #expect(syncEngine.pendingPrivateRecordZoneChanges.isEmpty)
        #expect((try? syncEngine.private.database.record(for: RemindersList.recordID(for: 2))) == nil)
      }

      /// A zone save queued before the hold (CKSyncEngine sends database changes itself) is dropped.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func aSaveQueuedBeforeTheHoldIsDropped() async throws {
        syncEngine.private.state.add(pendingDatabaseChanges: [.saveZone(syncEngine.defaultZone)])
        syncEngine.setZoneGuard(held(LockIsolated([syncEngine.defaultZone.zoneID.zoneName]), keep: true))

        await syncEngine.handleEvent(
          SyncEngine.Event.fetchedDatabaseChanges(
            modifications: [],
            deletions: [(syncEngine.defaultZone.zoneID, .deleted)]
          ),
          syncEngine: syncEngine.private
        )

        #expect(!savesDefaultZone)
      }

      /// A held zone other than the default one: its queued save is dropped after the deletion, so the
      /// next send does not recreate it.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func aQueuedSaveOfAnotherHeldZoneIsNotSent() async throws {
        let other = CKRecordZone(zoneID: CKRecordZone.ID(zoneName: "other", ownerName: CKCurrentUserDefaultName))
        syncEngine.private.state.removePendingChanges()
        syncEngine.private.state.add(pendingDatabaseChanges: [.saveZone(other)])
        syncEngine.setZoneGuard(held(LockIsolated(["other"]), keep: true))

        await syncEngine.handleEvent(
          SyncEngine.Event.fetchedDatabaseChanges(modifications: [], deletions: [(other.zoneID, .deleted)]),
          syncEngine: syncEngine.private
        )
        try await syncEngine.private.sendChanges(CKSyncEngine.SendChangesOptions())

        #expect(syncEngine.private.state.pendingDatabaseChanges.isEmpty)
        #expect(!zoneExists(other.zoneID))
      }

      /// The hold starts after the default zone's save was queued, with no deletion or sign-in between:
      /// the send drops the save instead of recreating the zone.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func aHoldStartingAfterTheSaveWasQueuedStopsTheSend() async throws {
        syncEngine.private.state.removePendingChanges()
        _ = try syncEngine.private.database.modifyRecordZones(deleting: [syncEngine.defaultZone.zoneID])
        syncEngine.private.state.add(pendingDatabaseChanges: [.saveZone(syncEngine.defaultZone)])
        let zones = LockIsolated<Set<String>>([])
        syncEngine.setZoneGuard(held(zones, keep: true))
        zones.withValue { $0.insert(syncEngine.defaultZone.zoneID.zoneName) }

        try await syncEngine.private.sendChanges(CKSyncEngine.SendChangesOptions())

        #expect(!savesDefaultZone)
        #expect(!zoneExists(syncEngine.defaultZone.zoneID))
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func signingInDoesNotRecreateAHeldZone() async throws {
        syncEngine.setZoneGuard(held(LockIsolated([syncEngine.defaultZone.zoneID.zoneName]), keep: true))
        await signIn()
        #expect(!savesDefaultZone)
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func signingInRecreatesAZoneThatIsNotHeld() async throws {
        syncEngine.setZoneGuard(held(LockIsolated([]), keep: true))
        await signIn()
        #expect(savesDefaultZone)
        syncEngine.private.state.removePendingChanges()
      }
    }
  }
#endif
