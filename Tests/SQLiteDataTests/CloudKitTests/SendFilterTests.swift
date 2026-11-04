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
#endif
