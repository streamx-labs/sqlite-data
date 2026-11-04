#if canImport(CloudKit)
  public import CloudKit
  import ConcurrencyExtras

  /// Decides, at the moment a batch is built, whether a pending change may be sent.
  ///
  /// StreamX fork: an app that keeps rows of several environments in one store uses it to make
  /// "only the current environment is ever uploaded" hold at the single point where records reach
  /// CloudKit. A change it refuses is removed from the engine's pending state and never sent.
  public struct SendFilter: Sendable {
    /// A save, after the record was built from its row. `isOnServer` is true when the record's
    /// metadata holds a server record CloudKit returned (see `isConfirmedOnServer`).
    public var save: @Sendable (_ record: CKRecord, _ isOnServer: Bool) -> Bool
    /// A deletion, addressed to the zone the record was first published to.
    public var delete: @Sendable (_ recordID: CKRecord.ID) -> Bool

    public init(
      save: @escaping @Sendable (_ record: CKRecord, _ isOnServer: Bool) -> Bool,
      delete: @escaping @Sendable (_ recordID: CKRecord.ID) -> Bool
    ) {
      self.save = save
      self.delete = delete
    }
  }

  extension SendFilter {
    /// The last known server record is also written before CloudKit accepts a save
    /// (`refreshLastKnownServerRecord`), so its presence alone isn't proof: only a record CloudKit
    /// returned carries a change tag. Read from the metadata, not from the record being sent, which
    /// is built fresh when older metadata kept no full copy.
    public static func isConfirmedOnServer(_ lastKnownServerRecord: CKRecord?) -> Bool {
      lastKnownServerRecord?.recordChangeTag != nil
    }
  }

  let nextEngineSendFilter = LockIsolated<SendFilter?>(nil)

  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  extension SyncEngine {
    /// Sets the filter the next `SyncEngine` created takes for its whole life. Call it before
    /// creating the engine: one created with `startImmediately` sends from its first batch.
    public static func setNextEngineSendFilter(_ filter: SendFilter?) {
      nextEngineSendFilter.setValue(filter)
    }

    /// Replaces this engine's filter (tests).
    public func setSendFilter(_ filter: SendFilter?) {
      sendFilter.setValue(filter)
    }
  }
#endif
