#if canImport(CloudKit)
  import CloudKit
  import ConcurrencyExtras
  import SQLiteData
  import SQLiteDataTestSupport
  import Testing

  extension BaseCloudKitTests {
    /// StreamX fork: a change the send filter refuses never reaches CloudKit and leaves the
    /// pending state; everything else is sent as before.
    @MainActor
    final class SendFilterTests: BaseCloudKitTests, @unchecked Sendable {
      /// The cached record a save leaves before CloudKit answers has no change tag; a server copy does.
      @Test func onlyARecordCloudKitReturnedIsOnTheServer() throws {
        #expect(!SendFilter.isConfirmedOnServer(nil))

        let sent = CKRecord(
          recordType: "remindersLists",
          recordID: CKRecord.ID(recordName: "1:remindersLists", zoneID: CKRecordZone.ID(zoneName: "zone"))
        )
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        sent.encodeSystemFields(with: archiver)
        let unarchiver = try NSKeyedUnarchiver(forReadingFrom: archiver.encodedData)
        unarchiver.requiresSecureCoding = true
        let cached = try #require(CKRecord(coder: unarchiver))
        #expect(!SendFilter.isConfirmedOnServer(cached))

        #expect(SendFilter.isConfirmedOnServer(ServerCopy(recordType: "remindersLists", recordID: sent.recordID)))
      }

      /// An edit to a record already on the server waits in the engine's own queue, not in the
      /// pending-changes table, until it is sent.
      @Test func anEditToASyncedRecordIsPendingUntilSent() async throws {
        try await userDatabase.userWrite { db in
          try db.seed { RemindersList(id: 1, title: "Mine") }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        #expect(syncEngine.pendingPrivateRecordZoneChanges.isEmpty)

        try await userDatabase.userWrite { db in
          try RemindersList.find(1).update { $0.title = "Edited" }.execute(db)
        }
        #expect(syncEngine.pendingPrivateRecordZoneChanges == [.saveRecord(RemindersList.recordID(for: 1))])

        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        #expect(syncEngine.pendingPrivateRecordZoneChanges.isEmpty)
      }

      @Test func refusedSaveIsNeverSent() async throws {
        syncEngine.setSendFilter(
          SendFilter(
            save: { record, _ in ((record.encryptedValues["title"] as? String) ?? (record["title"] as? String)) != "Foreign" },
            delete: { _ in true }
          )
        )
        try await userDatabase.userWrite { db in
          try db.seed {
            RemindersList(id: 1, title: "Mine")
            RemindersList(id: 2, title: "Foreign")
          }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        #expect((try? syncEngine.private.database.record(for: RemindersList.recordID(for: 1))) != nil)
        #expect((try? syncEngine.private.database.record(for: RemindersList.recordID(for: 2))) == nil)
        #expect(
          !syncEngine.private.state.pendingRecordZoneChanges
            .contains(.saveRecord(RemindersList.recordID(for: 2)))
        )
      }

      @Test func refusedDeletionIsNeverSent() async throws {
        try await userDatabase.userWrite { db in
          try db.seed { RemindersList(id: 1, title: "Mine") }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        syncEngine.setSendFilter(SendFilter(save: { _, _ in true }, delete: { _ in false }))

        try await userDatabase.userWrite { db in
          try RemindersList.find(1).delete().execute(db)
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        #expect((try? syncEngine.private.database.record(for: RemindersList.recordID(for: 1))) != nil)
        #expect(
          !syncEngine.private.state.pendingRecordZoneChanges
            .contains(.deleteRecord(RemindersList.recordID(for: 1)))
        )
      }
    }
  }

  /// A record as CloudKit returns it: with a change tag.
  private final class ServerCopy: CKRecord, @unchecked Sendable {
    override var recordChangeTag: String? { "server-tag" }
  }
#endif
