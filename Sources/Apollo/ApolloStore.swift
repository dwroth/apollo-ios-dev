import Foundation

/// A function that returns a cache key for a particular result object. If it returns `nil`, a default cache key based on the field path will be used.
public typealias CacheKeyForObject = (_ object: JSONObject) -> JSONValue?
public typealias DidChangeKeysFunc = (Set<CacheKey>, UUID?) -> Void

func rootCacheKey<Operation: GraphQLOperation>(for operation: Operation) -> String {
  switch operation.operationType {
  case .query:
    return "QUERY_ROOT"
  case .mutation:
    return "MUTATION_ROOT"
  case .subscription:
    return "SUBSCRIPTION_ROOT"
  }
}

protocol ApolloStoreSubscriber: class {
  
  /// A callback that can be received by subscribers when keys are changed within the database
  ///
  /// - Parameters:
  ///   - store: The store which made the changes
  ///   - changedKeys: The list of changed keys
  ///   - contextIdentifier: [optional] A unique identifier for the request that kicked off this change, to assist in de-duping cache hits for watchers.
  func store(_ store: ApolloStore,
             didChangeKeys changedKeys: Set<CacheKey>,
             contextIdentifier: UUID?)
}

/// The `ApolloStore` class acts as a local cache for normalized GraphQL results.
public final class ApolloStore {
  public var cacheKeyForObject: CacheKeyForObject?

  private let queue: DispatchQueue

  private let cache: NormalizedCache

  // We need a separate read/write lock for cache access because cache operations are
  // asynchronous and we don't want to block the dispatch threads
  private let cacheLock = ReadWriteLock()

  private var subscribers: [ApolloStoreSubscriber] = []

  /// Designated initializer
  ///
  /// - Parameter cache: An instance of `normalizedCache` to use to cache results. Defaults to an `InMemoryNormalizedCache`.
  public init(cache: NormalizedCache = InMemoryNormalizedCache()) {
    self.cache = cache
    queue = DispatchQueue(label: "com.apollographql.ApolloStore", attributes: .concurrent)
  }

  fileprivate func didChangeKeys(_ changedKeys: Set<CacheKey>, identifier: UUID?) {
    for subscriber in self.subscribers {
      subscriber.store(self, didChangeKeys: changedKeys, contextIdentifier: identifier)
    }
  }

  /// Clears the instance of the cache. Note that a cache can be shared across multiple `ApolloClient` objects, so clearing that underlying cache will clear it for all clients.
  ///
  /// - Returns: A promise which fulfills when the Cache is cleared.
  public func clearCache(callbackQueue: DispatchQueue = .main, completion: ((Result<Void, Error>) -> Void)? = nil) {
    queue.async(flags: .barrier) {
      self.cacheLock.withWriteLock {
        let result = Result { try self.cache.clear() }
        DispatchQueue.apollo.returnResultAsyncIfNeeded(on: callbackQueue,
                                                       action: completion,
                                                       result: result)
      }
    }
  }

  func publish(records: RecordSet, identifier: UUID? = nil) {
    queue.async(flags: .barrier) {
      self.cacheLock.withWriteLock {
        do {
          let changedKeys = try self.cache.merge(records: records)
          self.didChangeKeys(changedKeys, identifier: identifier)
        } catch {
          assertionFailure(String(describing: error))
        }
      }
    }
  }

  func subscribe(_ subscriber: ApolloStoreSubscriber) {
    queue.async(flags: .barrier) {
      self.subscribers.append(subscriber)
    }
  }

  func unsubscribe(_ subscriber: ApolloStoreSubscriber) {
    queue.async(flags: .barrier) {
      self.subscribers = self.subscribers.filter({ $0 !== subscriber })
    }
  }

  /// Performs an operation within a read transaction
  ///
  /// - Parameters:
  ///   - body: The body of the operation to perform.
  ///   - callbackQueue: [optional] The callback queue to use to perform the completion block on. Will perform on the current queue if not provided. Defaults to nil.
  ///   - completion: [optional] The completion block to perform when the read transaction completes. Defaults to nil.
  public func withinReadTransaction<T>(_ body: @escaping (ReadTransaction) throws -> T,
                                       callbackQueue: DispatchQueue? = nil,
                                       completion: ((Result<T, Error>) -> Void)? = nil) {
    self.queue.async {
      self.cacheLock.withReadLock {
        do {
          let returnValue = try body(ReadTransaction(store: self))
          
          DispatchQueue.apollo.returnResultAsyncIfNeeded(on: callbackQueue,
                                                         action: completion,
                                                         result: .success(returnValue))
        } catch {
          DispatchQueue.apollo.returnResultAsyncIfNeeded(on: callbackQueue,
                                                         action: completion,
                                                         result: .failure(error))
        }
        
      }
    }
  }
  
  /// Performs an operation within a read-write transaction
  ///
  /// - Parameters:
  ///   - body: The body of the operation to perform
  ///   - callbackQueue: [optional] a callback queue to perform the action on. Will perform on the current queue if not provided. Defaults to nil.
  ///   - completion: [optional] a completion block to fire when the read-write transaction completes. Defaults to nil.
  public func withinReadWriteTransaction<T>(_ body: @escaping (ReadWriteTransaction) throws -> T,
                                            callbackQueue: DispatchQueue? = nil,
                                            completion: ((Result<T, Error>) -> Void)? = nil) {
    self.queue.async(flags: .barrier) {
      self.cacheLock.withWriteLock {
        do {
          let returnValue = try body(ReadWriteTransaction(store: self))
          
          DispatchQueue.apollo.returnResultAsyncIfNeeded(on: callbackQueue,
                                                         action: completion,
                                                         result: .success(returnValue))
        } catch {
          DispatchQueue.apollo.returnResultAsyncIfNeeded(on: callbackQueue,
                                                         action: completion,
                                                         result: .failure(error))
        }
      }
    }
  }

  /// Loads the results for the given query from the cache.
  ///
  /// - Parameters:
  ///   - query: The query to load results for
  ///   - resultHandler: The completion handler to execute on success or error
  public func load<Operation: GraphQLOperation>(query: Operation, resultHandler: @escaping GraphQLResultHandler<Operation.Data>) {
    withinReadTransaction { transaction in
      let mapper = GraphQLSelectionSetMapper<Operation.Data>()
      let dependencyTracker = GraphQLDependencyTracker()
      
      do {
        let (data, dependentKeys) = try transaction.execute(selections: Operation.Data.selections,
                                                            onObjectWithKey: rootCacheKey(for: query),
                                                            variables: query.variables,
                                                            accumulator: zip(mapper, dependencyTracker))
        
        let result = GraphQLResult(data: data,
                                   extensions: nil,
                                   errors: nil,
                                   source:.cache,
                                   dependentKeys: dependentKeys)
        resultHandler(.success(result))
      } catch {
        resultHandler(.failure(error))
      }
    }
  }

  public class ReadTransaction {
    fileprivate let queue: DispatchQueue
    fileprivate let cache: NormalizedCache
    fileprivate let cacheKeyForObject: CacheKeyForObject?

    fileprivate lazy var loader: DataLoader<CacheKey, Record> = DataLoader(self.cache.loadRecords)

    fileprivate init(store: ApolloStore) {
      self.queue = DispatchQueue(label: "com.apollographql.ApolloStore.\(type(of: self))")
      self.cache = store.cache
      self.cacheKeyForObject = store.cacheKeyForObject
    }

    public func read<Query: GraphQLQuery>(query: Query) throws -> Query.Data {
      return try readObject(ofType: Query.Data.self,
                            withKey: rootCacheKey(for: query),
                            variables: query.variables)
    }

    public func readObject<SelectionSet: GraphQLSelectionSet>(ofType type: SelectionSet.Type,
                                                              withKey key: CacheKey,
                                                              variables: GraphQLMap? = nil) throws -> SelectionSet {
      let mapper = GraphQLSelectionSetMapper<SelectionSet>()
      return try execute(selections: type.selections,
                         onObjectWithKey: key,
                         variables: variables,
                         accumulator: mapper)
    }

    fileprivate func execute<Accumulator: GraphQLResultAccumulator>(selections: [GraphQLSelection], onObjectWithKey key: CacheKey, variables: GraphQLMap?, accumulator: Accumulator) throws -> Accumulator.FinalResult {
      let object = try loadObject(forKey: key).get()
      
      let executor = GraphQLExecutor { object, info in
        return object[info.cacheKeyForField]
      } resolveReference: { reference in
        self.loadObject(forKey: reference.key)
      }
      
      executor.cacheKeyForObject = self.cacheKeyForObject
      
      return try executor.execute(selections: selections,
                                  on: object,
                                  withKey: key,
                                  variables: variables,
                                  accumulator: accumulator)
    }
    
    private final func loadObject(forKey key: CacheKey) -> PossiblyDeferred<JSONObject> {
      self.loader[key].map { record in
        guard let record = record else { throw JSONDecodingError.missingValue }
        return record.fields
      }
    }
  }

  public final class ReadWriteTransaction: ReadTransaction {

    fileprivate var updateChangedKeysFunc: DidChangeKeysFunc?

    override init(store: ApolloStore) {
      self.updateChangedKeysFunc = store.didChangeKeys
      super.init(store: store)
    }

    public func update<Query: GraphQLQuery>(query: Query, _ body: (inout Query.Data) throws -> Void) throws {
      var data = try read(query: query)
      try body(&data)
      try write(data: data, forQuery: query)
    }

    public func updateObject<SelectionSet: GraphQLSelectionSet>(ofType type: SelectionSet.Type,
                                                                withKey key: CacheKey,
                                                                variables: GraphQLMap? = nil,
                                                                _ body: (inout SelectionSet) throws -> Void) throws {
      var object = try readObject(ofType: type,
                                  withKey: key,
                                  variables: variables)
      try body(&object)
      try write(object: object, withKey: key, variables: variables)
    }

    public func write<Query: GraphQLQuery>(data: Query.Data, forQuery query: Query) throws {
      try write(object: data,
                withKey: rootCacheKey(for: query),
                variables: query.variables)
    }

    public func write(object: GraphQLSelectionSet,
                      withKey key: CacheKey,
                      variables: GraphQLMap? = nil) throws {
      try write(object: object.jsonObject,
                forSelections: type(of: object).selections,
                withKey: key, variables: variables)
    }

    private func write(object: JSONObject,
                       forSelections selections: [GraphQLSelection],
                       withKey key: CacheKey,
                       variables: GraphQLMap?) throws {
      let normalizer = GraphQLResultNormalizer()
      let executor = GraphQLExecutor { object, info in
        return object[info.responseKeyForField]
      }
      
      executor.cacheKeyForObject = self.cacheKeyForObject
      
      let records = try executor.execute(selections: selections,
                                         on: object,
                                         withKey: key,
                                         variables: variables,
                                         accumulator: normalizer)
      let changedKeys = try self.cache.merge(records: records)
      
      // Remove cached records, so subsequent reads
      // within the same transaction will reload the updated value.
      loader.removeAll()
      
      if let didChangeKeysFunc = self.updateChangedKeysFunc {
        didChangeKeysFunc(changedKeys, nil)
      }
    }
  }
}
