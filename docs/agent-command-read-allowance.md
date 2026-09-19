# Shared read allowance for an agent command

## Owner and budget

`NotebookSQLConnection` owns the synchronous lifetime of one transaction.
`NotebookCommandDispatcher` uses `changesStore` to choose a read or write
transaction with a finite allowance. Direct agent apply and undo use the same
connection limits: 65,536 result rows, 32 MiB of values in total, and 8 MiB for
one value. Receipt and continuation reads share this allowance.

These limits account for SQL results, not total RSS or SQLite instruction count.
Text and BLOB lengths are charged before Swift values are allocated. Repeated
queries spend the remaining allowance; nested calls cannot reset it.
Addressed element reads retain their stricter admission of 4,096 fragments and
4 MiB before decoding.

Exhaustion is retained on the connection. Catching the error does not permit a
commit: the final check rolls back content, journal, and receipt together.
The next transaction has a fresh connection; native input does not inherit a
completed command's failure.

## Useful-operation boundary

Structural operations that still require a full large owner must fail with
`agent_command_read` rather than load it without a bound. An addressed change
to an existing small element can still succeed, produce a receipt, and be undone.
A bounded response alone does not establish an addressed implementation.

Placement does not move saved content, but preparing an exact raster persists a
request. Its `changesStore` classification routes it through the native command
queue. A read transaction cannot silently promote itself to a writer.

## Verification

`NotebookAgentCommandBudgetTests` covers charging before copying, cumulative
reads, rows containing null values, nested commands, caught failures, and commit
fencing. Dispatcher checks exercise apply, receipt, continuation, retry, and undo
against a large owner and require `resource_limit` without partial publication.
See [verification](verification.md) for evidence scope and historical results.
