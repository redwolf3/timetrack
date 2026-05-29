// Weak-linked fallback symbols for sqlite3_snapshot_* APIs.
//
// Ubuntu's system libsqlite3 is not compiled with SQLITE_ENABLE_SNAPSHOT, so
// sqlite3_snapshot_{get,open,free,cmp} are absent from the shared library.
// GRDB 6 (DatabaseSnapshotPool / WALSnapshot) references them at link time
// even though TimeTrackKit never instantiates those classes.
//
// The weak definitions below satisfy the linker on Linux.  On macOS (and any
// system whose SQLite includes SQLITE_ENABLE_SNAPSHOT) the strong symbols from
// the real library win via normal symbol resolution and these stubs are never
// entered.  We use opaque void* so this file needs no sqlite3.h include and
// cannot accidentally conflict with a real header declaration.
//
// If this file is ever reached at runtime it means DatabaseSnapshotPool is
// being used on a SQLite that lacks snapshot support — GRDB would return
// SQLITE_ERROR anyway, so returning 1 (SQLITE_ERROR) is correct behaviour.

__attribute__((weak))
int sqlite3_snapshot_get(void *db, const char *zSchema, void **ppSnapshot) {
    return 1; /* SQLITE_ERROR */
}

__attribute__((weak))
int sqlite3_snapshot_open(void *db, const char *zSchema, void *pSnapshot) {
    return 1;
}

__attribute__((weak))
void sqlite3_snapshot_free(void *pSnapshot) {}

__attribute__((weak))
int sqlite3_snapshot_cmp(void *p1, void *p2) { return 0; }

__attribute__((weak))
int sqlite3_snapshot_recover(void *db, const char *zSchema) { return 1; }
