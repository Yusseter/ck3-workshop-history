# Analysis 08 - Archive Content Pilot

Generated: 2026-08-17 01:08:37 +03:00

This analysis performs the first archive-content verification pass for a small
set of high-value P0 candidates selected by Analysis 07.

## Pilot revisions

3206891770|2
2829397295|3
2996881191|3
2543865921|3

The full first-pass queue is intentionally not downloaded here.

## Browser retrieval

Missing pilot archives are downloaded through an isolated, visible Chrome
instance controlled over the Chrome DevTools Protocol.

The Chrome instance uses a temporary non-default user-data directory and is
closed after retrieval.

For each browser retrieval, the analysis retains:

- the Modsbase file-page HTML
- the generated download-page HTML
- the downloaded ZIP SHA-256

Browser pages are also cached under analysis/cache so a later cache-only rerun
can reproduce the committed raw-page output without redownloading the archive.

Downloaded ZIPs and extracted working data remain under the ignored
analysis/cache directory and are not part of the committed analysis results.

## Historical Git comparison

The archive contents are projected onto the files tracked by each related
historical Git commit.

Root repository metadata files such as .gitignore and .gitattributes are
excluded from projected content comparison because they are repository
bookkeeping rather than Workshop snapshot content.

Files present in the archive but absent from the historical Git commit are
reported as archive extras rather than mismatches. This is intentional because
the old per-mod repositories frequently ignored large Workshop binaries.

Archive files are hashed through Git using their historical repository path so
applicable Git clean/text filters are applied before blob comparison.

A projected Git match requires:

- at least one comparable tracked file
- every comparable Git-tracked file to exist in the archive
- every comparable Git-tracked file to have the identical Git blob SHA-1
- descriptor remote_file_id to match the expected Workshop ID

This stage validates archive-to-Git content relationships only. It does not yet
assign final KNOWN + EXISTING or KNOWN + RECOVERED Steam-event statuses.

## Validation

Requested pilot revisions: 4
Completed archives: 4
Descriptor records: 4
Git comparison rows: 6
File difference rows: 10
Raw browser pages: 8
Warnings: 0
Validation errors: 0
