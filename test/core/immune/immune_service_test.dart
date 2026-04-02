import 'package:flutter_test/flutter_test.dart';

import 'package:memento_mori_app/core/immune/immune_chunk.dart';
import 'package:memento_mori_app/core/immune/recipe_cache.dart';

void main() {
  group('ImmuneChunk', () {
    test('fromWire and toWire round-trip', () {
      final chunk = ImmuneChunk(
        id: 'immune_1',
        recipe: RecipeParams(
          donorSni: 'microsoft.com',
          mode: 'packet-up',
        ),
        meta: RecipeMeta(
          operatorCode: 'MTS',
          successCount: 5,
          attemptCount: 6,
          lastSuccessAt: DateTime.now(),
        ),
        ttlSeconds: 3600,
      );
      final wire = chunk.toWire();
      expect(wire['type'], 'IMMUNE_CHUNK');
      expect(wire['recipe']['donor'], 'microsoft.com');
      expect(wire['immuneTtlSec'], 3600);
      expect(wire.containsKey('ttl'), isFalse);

      final parsed = ImmuneChunk.fromWire(wire);
      expect(parsed.recipe.donorSni, chunk.recipe.donorSni);
      expect(parsed.recipeHash, chunk.recipeHash);
    });

    test('fromWire legacy: large ttl maps to recipe TTL not mesh hops', () {
      final legacy = {
        'type': 'IMMUNE_CHUNK',
        'id': 'legacy1',
        'recipe': {'donor': 'x.com', 'mode': 'packet-up'},
        'meta': {
          'ts': DateTime.now().millisecondsSinceEpoch,
        },
        'ttl': 7200,
      };
      final parsed = ImmuneChunk.fromWire(legacy);
      expect(parsed.ttlSeconds, 7200);
    });

    test('recipeHash is deterministic', () {
      final p = RecipeParams(donorSni: 'x', mode: 'y');
      expect(p.recipeHash, p.recipeHash);
      expect(p.recipeHash.length, 16);
    });
  });

  group('RecipeCache', () {
    test('put and selectBest', () {
      final cache = RecipeCache();
      final chunk = ImmuneChunk(
        id: 'c1',
        recipe: RecipeParams(donorSni: 'microsoft.com', mode: 'packet-up'),
        meta: RecipeMeta(lastSuccessAt: DateTime.now()),
      );
      cache.put(chunk);

      final best = cache.selectBest(operatorCode: 'MTS');
      expect(best, isNotNull);
      expect(best!.donorSni, 'microsoft.com');
    });

    test('demote blocks recipe after threshold', () {
      final cache = RecipeCache();
      final chunk = ImmuneChunk(
        id: 'c2',
        recipe: RecipeParams(donorSni: 'x.com', mode: 'y'),
        meta: RecipeMeta(lastSuccessAt: DateTime.now()),
      );
      cache.put(chunk);
      final hash = chunk.recipeHash;

      cache.demote(hash);
      cache.demote(hash);
      cache.demote(hash);

      expect(cache.selectBest(), isNull);
    });

    test('selectBest skips TTL-expired recipes', () {
      final cache = RecipeCache();
      final old = DateTime.now().subtract(const Duration(seconds: 100));
      final chunk = ImmuneChunk(
        id: 'exp',
        recipe: RecipeParams(donorSni: 'old.com', mode: 'm'),
        meta: RecipeMeta(lastSuccessAt: old),
        ttlSeconds: 60,
      );
      cache.put(chunk);
      expect(cache.selectBest(), isNull);
    });

    test('addConfirmation updates chunk', () {
      final cache = RecipeCache();
      final chunk = ImmuneChunk(
        id: 'c3',
        recipe: RecipeParams(donorSni: 'a.com', mode: 'b'),
        meta: RecipeMeta(
          lastSuccessAt: DateTime.now(),
          confirmedBy: [],
        ),
      );
      cache.put(chunk);
      cache.addConfirmation(chunk.recipeHash, 'node1');

      final c = cache.getByHash(chunk.recipeHash);
      expect(c?.meta.confirmedBy, contains('node1'));
    });
  });
}
