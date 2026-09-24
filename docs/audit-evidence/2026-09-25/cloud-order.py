#!/usr/bin/env python3
"""Isolated SQL drain microprobe, not a full Notebook/Cloud benchmark.

Reproduces the CREATE/SELECT/UPDATE used by prepareCloudUpload. Seed all
pending hashes before measurement to isolate the queue's processed-prefix
scan. Production adds dependency children gradually; this fixture does not
measure that full traversal, the CK engine, or physical iPad latency.
"""
import json
import sqlite3
import time

results = []
for n in (1000, 2000, 4000, 8000):
    db = sqlite3.connect(':memory:')
    db.execute('CREATE TEMP TABLE cloud_order_nodes(hash TEXT PRIMARY KEY,expanded INTEGER NOT NULL DEFAULT 0)')
    # Unique, fixed-width, lexicographically ordered synthetic SHA-shaped keys.
    db.executemany('INSERT INTO cloud_order_nodes(hash) VALUES(?)',
                   ((f'{i:064x}',) for i in range(n)))
    db.commit()
    query = 'SELECT hash FROM cloud_order_nodes WHERE expanded=0 ORDER BY hash LIMIT 1'
    if n == 1000:
        print('QUERY PLAN:', db.execute('EXPLAIN QUERY PLAN ' + query).fetchall())
    instructions = [0]
    def progress():
        instructions[0] += 1000
        return 0
    db.set_progress_handler(progress, 1000)
    start = time.perf_counter()
    while True:
        row = db.execute(query).fetchone()
        if row is None:
            break
        db.execute('UPDATE cloud_order_nodes SET expanded=1 WHERE hash=?', (row[0],))
    elapsed = time.perf_counter() - start
    db.set_progress_handler(None, 0)
    results.append({'n': n, 'elapsed': elapsed, 'vm_approx': instructions[0]})
    db.close()
print(json.dumps(results, indent=2))
