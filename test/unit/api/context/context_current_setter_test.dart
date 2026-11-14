// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

// The deprecated Context.current setter keeps its behavior beside
// Context.attach and Context.detach.

import 'dart:async';

import 'package:dartastic_opentelemetry_api/dartastic_opentelemetry_api.dart';
import 'package:test/test.dart';

void main() {
  group('the deprecated Context.current setter', () {
    late ContextKey<String> key;

    setUp(() {
      OTelAPI.reset();
      OTelAPI.initialize(
        endpoint: 'http://localhost:4317',
        serviceName: 'test-service',
        serviceVersion: '1.0.0',
      );
      key = OTelAPI.contextKey<String>('setter-test');
    });

    tearDown(OTelAPI.reset);

    Context contextWith(String value) => Context.root.copyWith(key, value);

    test('a context it sets is current outside any Context Zone', () {
      final context = contextWith('global');
      Context.current = context;
      expect(Context.current, same(context));
    });

    test('a span in the context it sets is the current span', () {
      final tracer = OTelAPI.tracerProvider().getTracer('setter-test');
      final span = tracer.startSpan('test-span');
      Context.current = Context.current.withSpan(span);
      expect(Context.current.span, equals(span));
    });

    test('a callback in a Zone without a Context sees the context it sets', () {
      final context = contextWith('global');
      Context.current = context;
      String? seen;
      Zone.current.fork().run(() => seen = Context.current.get(key));
      expect(seen, 'global');
    });

    test('a Zone context wins over the context it sets', () {
      final zoned = contextWith('zoned');
      Context.current = contextWith('global');
      expect(zoned.runSync(() => Context.current), same(zoned));
      expect(Context.current.get(key), 'global');
    });

    test(
        'an attached context wins over the context it sets, which is current '
        'again after the detach', () {
      final global = contextWith('global');
      final attached = contextWith('attached');
      Context.current = global;

      final token = Context.attach(attached);
      expect(Context.current, same(attached));

      Context.detach(token);
      expect(Context.current, same(global));
    });

    test(
        'setting it under an attachment changes what is current after the '
        'detach', () {
      final attached = contextWith('attached');
      final global = contextWith('global');

      final token = Context.attach(attached);
      Context.current = global;
      expect(Context.current, same(attached));

      Context.detach(token);
      expect(Context.current, same(global));
    });

    test('resetCurrent replaces the context it set', () {
      Context.current = contextWith('global');
      Context.resetCurrent();
      expect(Context.current.get(key), isNull);
    });
  });
}
