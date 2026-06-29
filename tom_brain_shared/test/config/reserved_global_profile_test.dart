// GA-1 / GA-2 — the reserved global-aggregation profile name
// (memory_specification.md § 2.6).

import 'package:tom_brain_shared/tom_brain_shared.dart';
import 'package:test/test.dart';

void main() {
  group('reservedGlobalProfile (GA-1)', () {
    test('is the bare string "global"', () {
      expect(reservedGlobalProfile, 'global');
    });

    test('isReservedGlobalProfile recognises it and only it', () {
      expect(isReservedGlobalProfile('global'), isTrue);
      expect(isReservedGlobalProfile('defaultmemory_default'), isFalse);
      expect(isReservedGlobalProfile('globalish'), isFalse);
      expect(isReservedGlobalProfile('user_global'), isFalse);
    });

    test(
        'validateMemoryProfileName still accepts "global" as a directory name '
        '(GA-2: the registry/Aggregator must be able to address it)', () {
      expect(isValidMemoryProfileName(reservedGlobalProfile), isTrue);
      expect(
        () => validateMemoryProfileName(reservedGlobalProfile),
        returnsNormally,
      );
    });
  });
}
