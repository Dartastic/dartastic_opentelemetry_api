// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';
import '../../factory/otel_factory.dart';
import '../../util/otel_error_handler.dart';
import '../../util/otel_log.dart';
import '../baggage/baggage.dart';
import '../trace/span.dart';
import '../trace/span_context.dart';
import 'context_key.dart';
// Use conditional imports to handle platform differences
import 'isolate_support.dart'
    if (dart.library.js_interop) 'isolate_support_web.dart';

part 'context_create.dart';

/// Represents the immutable context containing active spans, baggage, and other data.
@immutable
class Context {
  /// The key used to store context in zone values.
  static final _zoneKey = Object();

  /// Holds the singleton root context instance.
  static Context? _rootContext;

  /// The tokens of the contexts made current by [attach] and not yet
  /// detached, most recent last. Per isolate, like every static.
  static final List<ContextToken> _attached = <ContextToken>[];

  /// The Context set with the deprecated [current] setter.
  static Context? _currentContext;

  /// Cached reference to the OTelFactory for creating contexts.
  static OTelFactory? _otelFactory;

  /// The root context with no values
  static Context get root {
    return _rootContext ??= _getAndCacheOTelFactory().context();
  }

  /// Gets and caches the OTelFactory instance.
  ///
  /// Retrieves the global OTelFactory instance, lazily installing the No-Op
  /// API factory if no SDK has installed one yet. Per the OpenTelemetry
  /// specification, the API MUST NOT require explicit initialization, so this
  /// never throws. The global is re-read on every call — like [OTelAPI] —
  /// so a factory installed later (e.g. by an SDK's initialize()) replaces
  /// any no-op cached before initialization.
  static OTelFactory _getAndCacheOTelFactory() {
    return _otelFactory = OTelFactory.getOrCreateDefault();
  }

  /// The Context associated with the caller's current execution unit, the
  /// specification's "Get current Context" operation.
  ///
  /// The search order is:
  /// 1. the Context carried by the current [Zone] (set by [run], [runSync]
  ///    or anything built on them, such as `APITracer.withSpan`);
  /// 2. otherwise, the Context most recently made current by [attach] and
  ///    not yet detached;
  /// 3. otherwise, the Context set with the deprecated [current] setter;
  /// 4. otherwise, [root].
  ///
  /// A Zone context always wins, so a Context made current with [runSync]
  /// inside an attached region is the current one for that computation.
  /// An attached Context wins over the setter's, and the setter's is current
  /// again once everything attached is detached.
  static Context get current {
    return Zone.current[_zoneKey] as Context? ??
        (_attached.isEmpty ? null : _attached.last._context) ??
        _currentContext ??
        Context.root;
  }

  /// Sets the global current Context.
  ///
  /// This updates the global current Context but does not affect
  /// Zone-specific contexts or attached ones (see [current] for the order).
  ///
  /// @deprecated Use [Context.run] or [Context.runSync] to activate a context
  /// within a [Zone], or [attach] and [detach] where a callback runs outside
  /// that Zone. Setting this static field is unreliable in complex
  /// asynchronous workflows as it does not propagate through [Zone]s.
  @Deprecated(
      'Use Context.run() or Context.runSync() to ensure correct asynchronous propagation via Zones. This setter will be removed in v1.0.0.')
  static set current(Context newContext) {
    _currentContext = newContext;
  }

  /// Makes [context] current for the synchronous code that runs until the
  /// returned token is passed to [detach], the specification's
  /// "Attach Context" operation.
  ///
  /// Use it where a callback runs in a [Zone] other than the one that made
  /// a Context current, for example a framework that calls back into a Zone
  /// it captured earlier. [run] and [runSync] cannot reach such a callback:
  /// the callback leaves their Zone. An attached Context is read by
  /// [current] whenever the current Zone carries no Context of its own.
  ///
  /// Always detach in a `finally`:
  ///
  /// ```dart
  /// final token = Context.attach(context);
  /// try {
  ///   dispatch(event); // handlers here see `context` as Context.current
  /// } finally {
  ///   Context.detach(token);
  /// }
  /// ```
  ///
  /// **Synchronous only.** An attached Context does not follow `await`.
  /// The attachment belongs to the isolate, not to a Zone, so it covers
  /// exactly the code that runs between [attach] and [detach]. Detach
  /// before yielding to the event loop: anything else the event loop runs
  /// in the meantime, in a Zone without a Context, would see the attached
  /// Context as current. A continuation that runs after the detach sees
  /// the Context of the Zone it runs in. For asynchronous work, carry the
  /// Context with [run], which Zones propagate across `await`.
  static ContextToken attach(Context context) {
    final token = ContextToken._(context);
    _attached.add(token);
    return token;
  }

  /// Restores the Context that was current before [token]'s [attach], the
  /// specification's "Detach Context" operation.
  ///
  /// Detach in the reverse order of attach. The specification lets an
  /// implementation report a wrong call order, and this one never throws:
  /// - **Out of order.** When [token] is attached but a later attach is
  ///   still attached, the later attachments are detached with it, so the
  ///   Context current before [token]'s attach is current again, and the
  ///   wrong order is reported through `OTelErrorHandling.report`. Detaching
  ///   one of those later tokens afterwards is then a stale detach.
  /// - **Stale.** When [token] is no longer attached (it was detached
  ///   already, or an out-of-order detach removed it), nothing changes and
  ///   the stale detach is reported through `OTelErrorHandling.report`.
  static void detach(ContextToken token) {
    if (_attached.isNotEmpty && identical(_attached.last, token)) {
      _attached.removeLast();
      return;
    }
    final index = _attached.lastIndexOf(token);
    if (index < 0) {
      OTelErrorHandling.report(
          StateError('Context.detach: the token is not attached. It was '
              'detached already, or an out-of-order detach of an earlier '
              'token detached it. Nothing changed.'),
          StackTrace.current);
      return;
    }
    final later = _attached.length - index - 1;
    _attached.removeRange(index, _attached.length);
    OTelErrorHandling.report(
        StateError('Context.detach: detached out of order. $later later '
            'attachment(s) were still attached and were detached with it; '
            'the Context current before this attach is current again.'),
        StackTrace.current);
  }

  /// Clears the current span from the context.
  /// Returns a new context without the span and span context.
  ///
  /// This method only returns a new context; it does not change the current context.
  /// To make the new context active, use [run] or [runSync].
  static Context clearCurrentSpan() {
    return current.copyWithoutSpan();
  }

  /// Resets the current context to a new empty context and detaches every
  /// attached context.
  ///
  /// This is intended for testing purposes only and should not be used in production code.
  @visibleForTesting
  static void resetCurrent() {
    _attached.clear();
    _currentContext = ContextCreate.create();
  }

  /// Resets the root context to a new empty context.
  ///
  /// This is intended for testing purposes only and should not be used in production code.
  @visibleForTesting
  static void resetRoot() {
    _rootContext = ContextCreate.create();
  }

  /// The key used to store the active span - inner context keys can never be public, by spec
  static final ContextKey<APISpan> _spanKey =
      ContextKeyCreate.create('span', ContextKey.generateContextKeyId());
  static final ContextKey<SpanContext> _spanContextKey =
      ContextKeyCreate.create('spanContext', ContextKey.generateContextKeyId());
  static final ContextKey<Baggage> _baggageKey =
      ContextKeyCreate.create('baggage', ContextKey.generateContextKeyId());

  /// Creates a new Context.
  /// You cannot create a Context directly; you must use [OTelFactory]:
  /// ```dart
  /// var context = OTelFactory.context(values);
  /// ```
  const Context._(Map<ContextKey<Object?>, Object?>? contextValues)
      : _values = contextValues ?? const {};

  /// The values stored in this context, mapped by their context keys.
  final Map<ContextKey<Object?>, Object?> _values;

  /// Gets the currently active span in this context, if any
  APISpan? get span => _values[_spanKey] as APISpan?;

  /// Gets the current span from the context.
  ///
  /// Returns null if no span is set in the context.
  SpanContext? get spanContext => get<SpanContext?>(_spanContextKey);

  /// Gets the baggage from the context.
  Baggage? get baggage {
    final baggage = get<Baggage>(_baggageKey);
    return baggage;
  }

  // Returns the current context if it has baggage or makes a copy of the
  // current context with empty Baggage, sets it to Context.current and
  // returns it.
  /// Returns the current context with Baggage, creating empty Baggage if needed.
  ///
  /// If the current context has no Baggage, this creates a new context with empty Baggage,
  /// sets it as the current context, and returns it.
  static Context currentWithBaggage() {
    _getAndCacheOTelFactory();
    final current = Context.current;
    if (current.baggage != null) return current;
    return current.copyWithBaggage(OTelFactory.otelFactory!.baggage({}));
  }

  /// Creates a new Context without a span or span context
  Context copyWithoutSpan() {
    final newValues = Map<ContextKey<Object?>, Object?>.from(_values);
    newValues.remove(_spanKey);
    newValues.remove(_spanContextKey);
    return ContextCreate.create(contextMap: newValues);
  }

  /// Creates a new context with the given baggage
  /// Send an empty baggage to avoid sending any name/value pairs to an
  /// untrusted process.
  Context withBaggage(Baggage baggage) {
    return copyWith(_baggageKey, baggage);
  }

  /// Creates a new context with the given span context.
  ///
  /// Returns a new [Context] derived from this one with [spanContext] set,
  /// replacing any existing span context — even one belonging to a
  /// different trace. Per the OpenTelemetry Context specification a
  /// set-value operation always returns a derived Context, and per the
  /// Propagators API specification `extract` must never throw: receiving a
  /// valid `traceparent` for another trace while a local span is active is
  /// an ordinary situation, not an error. When the trace ID changes, a
  /// debug log records the replacement. Use [withSpan] to make a span (and
  /// its span context) current when creating child spans.
  Context withSpanContext(SpanContext spanContext) {
    final currentSpanContext = get<APISpan?>(_spanKey)?.spanContext ??
        get<SpanContext?>(_spanContextKey);
    if (currentSpanContext != null &&
        currentSpanContext.isValid &&
        spanContext.isValid &&
        currentSpanContext.traceId != spanContext.traceId &&
        OTelLog.isDebug()) {
      OTelLog.debug('Context.withSpanContext: replacing span context of trace '
          '${currentSpanContext.traceId} with span context of trace '
          '${spanContext.traceId}.');
    }

    return copyWith(_spanContextKey, spanContext);
  }

  /// Gets the value added for the [ContextKey]
  /// Returns null if no value is set for this key or if the value's type doesn't match T
  /// Gets a value from the context for the specified key.
  ///
  /// Returns null if the key is not present or if the value's type doesn't match T.
  /// This prevents type casting errors when retrieving values.
  T? get<T>(ContextKey<T> key) {
    final value = _values[key];
    if (value == null) return null;
    if (value is T) return value as T;
    return null; // Return null when types don't match instead of throwing
  }

  /// Creates a new Context with the given span set as active
  Context withSpan(APISpan span) {
    // Create a new context with both span and span context
    return ContextCreate.create(contextMap: {
      ..._values,
      _spanKey: span,
      _spanContextKey: span.spanContext,
    });
  }

  /// Creates a new Context with the given span set as active.
  ///
  /// This is separate from span creation as per the specification.
  /// This method only returns a new context; it does not change the current context.
  /// To make the new context active, use [run] or [runSync].
  Context setCurrentSpan(APISpan? span) {
    if (span == null) {
      // Remove both span and span context
      return ContextCreate.create(
          contextMap: Map.from(_values)
            ..remove(_spanKey)
            ..remove(_spanContextKey));
    } else {
      // Set both span and span context
      return ContextCreate.create(contextMap: {
        ..._values,
        _spanKey: span,
        _spanContextKey: span.spanContext,
      });
    }
  }

  /// Creates a new Context with the specified value for the given key
  Context copyWith<T>(ContextKey<T> key, T value) {
    return ContextCreate.create(contextMap: {
      ..._values,
      key: value,
    });
  }

  /// Creates a new Context adding in [moreBaggage], replacing any existing
  /// keys that are the same as the keys in [moreBaggage]
  /// Creates a new Context with additional Baggage entries.
  ///
  /// This merges any existing Baggage with the new Baggage, with new entries
  /// replacing existing entries that have the same keys.
  Context copyWithBaggage(Baggage moreBaggage) {
    final currentBaggage = baggage;
    final newBaggage = currentBaggage == null
        ? moreBaggage
        : currentBaggage.copyWithBaggage(moreBaggage);
    return ContextCreate.create(contextMap: {
      ..._values,
      _baggageKey: newBaggage,
    });
  }

  /// Creates a new Context with the given SpanContext.
  ///
  /// This sets only the span context and not an active span.
  Context copyWithSpanContext(SpanContext spanContext) {
    final newContext = ContextCreate.create(contextMap: {
      ..._values,
      _spanContextKey: spanContext,
    });
    return newContext;
  }

  /// Runs a synchronous computation in a new Zone carrying this context.
  ///
  /// This is the preferred way to activate a context for synchronous code as it
  /// ensures that any asynchronous operations started within the computation
  /// will correctly inherit this context via the [Zone] mechanism.
  T runSync<T>(T Function() computation) {
    return runZoned(
      computation,
      zoneValues: {_zoneKey: this},
    );
  }

  /// Runs an asynchronous operation in a new Zone carrying this context.
  ///
  /// This is the preferred way to activate a context for asynchronous code as it
  /// ensures that all asynchronous callbacks throughout the [Future] chain
  /// will correctly inherit this context via the [Zone] mechanism.
  Future<T> run<T>(Future<T> Function() operation) {
    return runZoned(
      operation,
      zoneValues: {_zoneKey: this},
    );
  }

  /// Runs a computation in a new isolate with this context.
  ///
  /// This serializes the current context and factory configuration, passes them to
  /// the new isolate, and then runs the computation with the context set in the new isolate.
  ///
  /// On web platforms, this will run in the current thread as web doesn't support isolates.
  Future<T> runIsolate<T>(Future<T> Function() computation) async {
    // Serialize the current factory
    final oldFactory = _getAndCacheOTelFactory();
    final serializedFactory = oldFactory.serialize();
    final serializedContext = serialize();
    final factoryFactory = oldFactory.factoryFactory;

    Future<T> childMain() async {
      // Set up the factory in the new isolate.
      OTelFactory.otelFactory =
          OTelFactory.deserialize(serializedFactory, factoryFactory);

      // Deserialize the parent's context in the new isolate. Per the OTel
      // spec ([trace/api.md §SpanContext]: "Each propagators' deserialization
      // must set IsRemote to true on a parent SpanContext"), upgrade the
      // propagated SpanContext to isRemote=true on the receiving side — same
      // semantic as a SpanContext extracted from W3C trace-context HTTP
      // headers. Crossing an isolate boundary is the same kind of process
      // boundary.
      final deserialized = deserialize(serializedContext);
      final propagatedSpanContext = deserialized.spanContext;
      final isolateContext =
          (propagatedSpanContext != null && !propagatedSpanContext.isRemote)
              ? deserialized.copyWithSpanContext(
                  OTelFactory.otelFactory!.spanContext(
                    traceId: propagatedSpanContext.traceId,
                    spanId: propagatedSpanContext.spanId,
                    parentSpanId: propagatedSpanContext.parentSpanId,
                    traceFlags: propagatedSpanContext.traceFlags,
                    traceState: propagatedSpanContext.traceState,
                    isRemote: true,
                  ),
                )
              : deserialized;
      _rootContext ??= isolateContext;

      // Run the computation in a zone carrying the deserialized context.
      return runZoned(
        computation,
        zoneValues: {_zoneKey: isolateContext},
      );
    }

    // Spawn via the platform bridge, which re-installs the parent's
    // error handler inside the child isolate first (api#94).
    return runIsolateWithErrorHandlerBridge(childMain);
  }

  /// Serializes the context into a JSON-compatible map.
  ///
  /// This is used for passing context across isolate boundaries.
  Map<String, dynamic> serialize() {
    final values = <String, dynamic>{};
    final keyNamesCount = <String, int>{};

    // Only serialize baggage if it has entries
    final currentBaggage = baggage;
    if (currentBaggage != null && currentBaggage.getAllValues().isNotEmpty) {
      values['baggage'] = currentBaggage.toJson();
    }

    // Only serialize span context if not null
    if (spanContext != null) {
      values['spanContext'] = spanContext!.toJson();
    }

    // Serialize remaining context values with their unique IDs
    _values.forEach((key, value) {
      if (key != _baggageKey && key != _spanKey && key != _spanContextKey) {
        // Skip keys that are not marked as transferable
        if (!key.isTransferable) {
          return;
        }

        try {
          // We still check for serializability to be safe, but now we only
          // do it for keys that are expected to be transferable.
          // In the future, we could skip this check for even better performance
          // if we trust the isTransferable flag.
          json.encode(value);

          // If we get here, the value is serializable
          // Handle multiple keys with the same name
          var finalKeyName = key.name;

          // If we've seen this key name before, make it unique
          keyNamesCount[key.name] = (keyNamesCount[key.name] ?? 0) + 1;
          if (keyNamesCount[key.name]! > 1) {
            finalKeyName = '${key.name}-${keyNamesCount[key.name]}';
          }

          // Create a composite key entry that includes both name and uniqueId
          values[finalKeyName] = {
            'value': value,
            'uniqueId': key.uniqueId,
            'originalKeyName':
                key.name, // Store original key name for deserialization
          };
        } catch (e) {
          // Value is not serializable, skip it
        }
      }
    });

    return values;
  }

  /// Deserializes a previously serialized context map back into a Context object.
  ///
  /// This is used when receiving context from another isolate.
  static Context deserialize(Map<String, dynamic> values) {
    _getAndCacheOTelFactory();
    var context = _otelFactory!.context();

    // Handle baggage if present and not empty
    if (values.containsKey('baggage')) {
      final baggageValue = values['baggage'];
      if (baggageValue is Map<String, dynamic> && baggageValue.isNotEmpty) {
        final baggage = Baggage.fromJson(baggageValue);
        context = context.copyWith(_baggageKey, baggage);
      }
    }

    // Handle span context if present and not null. Round-trip-faithful:
    // isRemote is preserved as serialized. The remote-on-receiving-side
    // override for cross-isolate transfer happens in [runIsolate].
    if (values.containsKey('spanContext')) {
      final spanContextValue = values['spanContext'];
      if (spanContextValue is Map<String, dynamic>) {
        final spanContext = SpanContext.fromJson(spanContextValue);
        context = context.copyWith(_spanContextKey, spanContext);
      }
    }

    // Handle remaining values
    values.forEach((key, value) {
      if (key != 'baggage' && key != 'spanContext') {
        if (value is Map<String, dynamic> && value.containsKey('uniqueId')) {
          final uniqueIdList =
              Uint8List.fromList((value['uniqueId'] as List).cast<int>());

          // Get the original key name if available, otherwise use the key
          final keyName = value.containsKey('originalKeyName')
              ? value['originalKeyName'] as String
              : key;

          // Note: Two keys with same name but different uniqueIds are valid and distinct

          // Recreate the context key with the same name and uniqueId
          final contextKey = OTelFactory.otelFactory!.contextKey<Object?>(
            keyName,
            uniqueIdList,
          );
          context = context.copyWith(contextKey, value['value']);
        }
      }
    });

    return context;
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! Context) return false;
    if (_values.length != other._values.length) return false;
    for (final key in _values.keys) {
      if (!other._values.containsKey(key)) return false;
      if (_values[key] != other._values[key]) return false;
    }
    return true;
  }

  @override
  int get hashCode {
    // Create a consistent hash based on the values and keys
    // Sort the keys for consistency
    final sortedEntries = _values.entries.toList()
      ..sort((a, b) => a.key.toString().compareTo(b.key.toString()));

    return Object.hashAll([
      for (final entry in sortedEntries) Object.hash(entry.key, entry.value)
    ]);
  }
}

/// The handle [Context.attach] returns. Pass it to [Context.detach] to
/// restore the Context that was current before the attach.
///
/// A token is opaque and single-use: detaching it twice is a stale detach.
final class ContextToken {
  ContextToken._(this._context);

  /// The Context the attach made current.
  final Context _context;
}
