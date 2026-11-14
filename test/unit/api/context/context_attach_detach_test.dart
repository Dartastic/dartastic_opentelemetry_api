// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';

import 'package:dartastic_opentelemetry_api/dartastic_opentelemetry_api.dart';
import 'package:test/test.dart';

/// Context's Attach Context and Detach Context operations
/// (context/README.md, "Optional Global operations").
void main() {
  group('Context.attach / Context.detach', () {
    late ContextKey<String> key;
    late List<Object> reported;
    late Context base;

    setUp(() {
      OTelAPI.reset();
      OTelAPI.initialize(
        endpoint: 'http://localhost:4317',
        serviceName: 'test-service',
        serviceVersion: '1.0.0',
      );
      key = OTelAPI.contextKey<String>('attach-test');
      reported = <Object>[];
      OTelAPI.setErrorHandler((error, _) => reported.add(error));
      base = Context.current;
    });

    tearDown(OTelAPI.reset);

    Context contextWith(String value) => Context.root.copyWith(key, value);

    test('an attached context is current until it is detached', () {
      final context = contextWith('attached');
      expect(Context.current.get(key), isNull);

      final token = Context.attach(context);
      expect(Context.current, same(context));

      Context.detach(token);
      expect(Context.current, same(base));
      expect(reported, isEmpty);
    });

    test(
        'a callback run in a Zone captured earlier sees the attached context, '
        'which a Zone context cannot reach', () {
      // A framework that keeps a Zone and calls back into it, as
      // flutter_test 3.50's LiveTestWidgetsFlutterBinding does with its
      // _testZone for pointer events and frames.
      final foreignZone = Zone.current;
      final context = contextWith('interaction');

      String? seenViaZone;
      context.runSync(() {
        foreignZone.run(() => seenViaZone = Context.current.get(key));
      });
      expect(seenViaZone, isNull,
          reason: 'the callback leaves the Zone that carries the context');

      String? seenViaAttach;
      final token = Context.attach(context);
      try {
        foreignZone.run(() => seenViaAttach = Context.current.get(key));
      } finally {
        Context.detach(token);
      }
      expect(seenViaAttach, 'interaction');
      expect(Context.current.get(key), isNull);
    });

    test('a span started under an attached context takes it as the parent', () {
      final parent = OTelAPI.spanContext(
        traceId: OTelAPI.traceIdFrom('4bf92f3577b34da6a3ce929d0e0e4736'),
        spanId: OTelAPI.spanIdFrom('00f067aa0ba902b7'),
        traceFlags: OTelAPI.traceFlags(TraceFlags.SAMPLED_FLAG),
        isRemote: true,
      );
      final tracer = OTelAPI.tracerProvider().getTracer('attach-test');
      final foreignZone = Zone.current;

      late APISpan span;
      final token = Context.attach(Context.root.withSpanContext(parent));
      try {
        foreignZone.run(() => span = tracer.startSpan('handler'));
      } finally {
        Context.detach(token);
      }

      // With only the API installed, the span carries the parent's
      // SpanContext (trace/api.md, behavior without an SDK).
      expect(span.spanContext.traceId, parent.traceId);
      expect(span.spanContext.spanId, parent.spanId);
    });

    test('a Zone context wins over an attached context', () {
      final attached = contextWith('attached');
      final zoned = contextWith('zoned');

      final token = Context.attach(attached);
      try {
        expect(zoned.runSync(() => Context.current), same(zoned));
        expect(Context.current, same(attached));
      } finally {
        Context.detach(token);
      }
    });

    test('nested attaches detach in reverse order, restoring each in turn', () {
      final outer = contextWith('outer');
      final inner = contextWith('inner');

      final outerToken = Context.attach(outer);
      final innerToken = Context.attach(inner);
      expect(Context.current, same(inner));

      Context.detach(innerToken);
      expect(Context.current, same(outer));

      Context.detach(outerToken);
      expect(Context.current, same(base));
      expect(reported, isEmpty);
    });

    test(
        'an out-of-order detach restores the context current before that '
        'attach, reports the wrong order and does not throw', () {
      final outer = contextWith('outer');
      final middle = contextWith('middle');
      final inner = contextWith('inner');

      final outerToken = Context.attach(outer);
      final middleToken = Context.attach(middle);
      final innerToken = Context.attach(inner);

      Context.detach(middleToken);
      expect(Context.current, same(outer));
      expect(reported, hasLength(1));
      expect(reported.single, isA<StateError>());
      expect('${reported.single}', contains('out of order'));

      // The inner attachment went with it: its detach is stale.
      Context.detach(innerToken);
      expect(Context.current, same(outer));
      expect(reported, hasLength(2));
      expect('${reported.last}', contains('not attached'));

      Context.detach(outerToken);
      expect(Context.current, same(base));
      expect(reported, hasLength(2));
    });

    test('detaching a token twice is reported, changes nothing, never throws',
        () {
      final outer = contextWith('outer');
      final inner = contextWith('inner');

      final outerToken = Context.attach(outer);
      final innerToken = Context.attach(inner);
      Context.detach(innerToken);
      Context.detach(innerToken);

      expect(Context.current, same(outer));
      expect(reported, hasLength(1));
      expect(reported.single, isA<StateError>());
      expect('${reported.single}', contains('not attached'));

      Context.detach(outerToken);
      expect(Context.current, same(base));
    });

    test('a detach with nothing attached is reported and never throws', () {
      final token = Context.attach(contextWith('once'));
      Context.detach(token);

      Context.detach(token);
      expect(Context.current, same(base));
      expect(reported, hasLength(1));
    });

    test('an attached context does not follow await', () async {
      final context = contextWith('sync-only');
      final completer = Completer<void>();
      String? afterAwait = 'not run';

      Future<void> handler() async {
        await completer.future;
        afterAwait = Context.current.get(key);
      }

      final token = Context.attach(context);
      final pending = handler();
      Context.detach(token);

      completer.complete();
      await pending;
      expect(afterAwait, isNull,
          reason: 'the continuation runs after the detach');
    });

    test('Context.run carries the context across await under an attach',
        () async {
      final context = contextWith('zoned');
      final completer = Completer<void>();
      String? afterAwait;

      final token = Context.attach(contextWith('attached'));
      final pending = context.run(() async {
        await completer.future;
        afterAwait = Context.current.get(key);
      });
      Context.detach(token);

      completer.complete();
      await pending;
      expect(afterAwait, 'zoned');
    });

    test('resetCurrent detaches everything', () {
      Context.attach(contextWith('leaked'));
      Context.resetCurrent();
      expect(Context.current.get(key), isNull);
    });
  });
}
