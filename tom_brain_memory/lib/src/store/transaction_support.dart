// Transaction-rollback helper shared by every `BEGIN … COMMIT` block
// in the package (Plan step D.3.3).
//
// Every transactional writer follows the same shape:
//
//     _db.execute('BEGIN');
//     try {
//       …
//       _db.execute('COMMIT');
//     } catch (error, stack) {
//       rollbackQuietly(_db);
//       Error.throwWithStackTrace(error, stack);
//     }
//
// The naive form — `catch (_) { _db.execute('ROLLBACK'); rethrow; }` —
// masks the original failure whenever the `ROLLBACK` statement itself
// throws (a poisoned handle, a closed database). The operator then sees
// the rollback error and loses the cause. [rollbackQuietly] swallows a
// rollback failure precisely so the caller can rethrow the *original*
// error with its stack intact.

import 'package:sqlite3/sqlite3.dart';

/// Issues `ROLLBACK` on [db], swallowing any error the rollback itself
/// raises.
///
/// A rollback failure means the handle is already in a bad state; the
/// error that triggered the rollback is the one worth surfacing. The
/// caller is expected to immediately rethrow that original error (via
/// `Error.throwWithStackTrace`) after calling this — see the file
/// header for the canonical pattern.
void rollbackQuietly(Database db) {
  try {
    db.execute('ROLLBACK');
  } catch (_) {
    // Intentionally swallowed: never let a rollback failure mask the
    // original error the caller is about to rethrow.
  }
}
