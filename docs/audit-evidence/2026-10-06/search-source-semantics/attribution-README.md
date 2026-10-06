# Search updater attribution

Three isolated processes, same multilingual A→B one-character edit.
Actual updateSearchIndex:1KiB5.57ms;1MiB128.20ms;4MiB542.99ms.
At4MiB top-level SQL_PROFILE70ms:entry upsert/FTS67ms,old-folded read3ms.
All sizes execute67short-posting inserts and3592owner VM steps.
The residue includes non-SQL preparation, timing resolution and instrumentation;
nested raw SQL profiles are preserved and must not be blindly added.

Every probe rolled back and kept source/index/cursors. This attributes a real
search-owner bottleneck and justifies a scoped preparation follow-up. It does
not implement or accept a hash-bound plan. Baseb463 is explicit; Root01b6a23e
allowances require their own runtime measurement after integration.

Only the unselected diagnostic cost-test file changed after the earlier strict
21/27whole-tree receipt; production search/reference and those21tests are unchanged.
