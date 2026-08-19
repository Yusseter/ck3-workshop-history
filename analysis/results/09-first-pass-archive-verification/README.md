# Analysis 09 - First-Pass Archive Verification

Generated: 2026-08-19 13:36:51 +03:00

This analysis expands the validated Analysis 08 archive-content pilot across the
full P0 first-pass queue produced by Analysis 07.

## Queue model

The Analysis 07 queue contains 52 P0 archive revisions.
Each invocation processes the next batch of up to 8 non-complete
revisions, while any still-unprocessed Analysis 08 pilot archives are seeded
from the existing cache without redownloading them.

Per-revision state is persisted under the ignored analysis/cache directory.
Successful revisions are not reprocessed on later runs. Failed revisions remain
retryable, and already-downloaded ZIPs are reused when possible.

Current queue state:

- complete: 52
- error: 0
- pending: 0
- queue complete: True

## Verification

For every completed revision, the analysis records:

- ZIP SHA-256 provenance and acquisition source
- descriptor metadata and Workshop-ID validation
- archive path/size inventory
- all related historical Git candidate commits from Analysis 07
- Git attribute-aware projected blob comparison
- unique, multiple, or absent projected Git content matches

Archive files are hashed through Git using their historical repository path so
applicable Git clean/text behavior is applied before blob comparison.

Archive-only files are retained as extras rather than treated as mismatches,
because the historical per-mod repositories may have ignored large Workshop
binary content.

This stage verifies archive-to-Git content relationships. It does not by itself
assign final Steam-event KNOWN + EXISTING or KNOWN + RECOVERED statuses.

## Resume behavior

Downloaded ZIPs, browser-page cache, per-revision state, and result fragments are
stored under analysis/cache and are ignored by Git. Extracted working copies are
removed after successful verification to avoid duplicating large archives on
disk.

The committed-style output directory is rebuilt cumulatively from completed
per-revision state after every run, so partial progress can be inspected without
losing previous successful work.

## Outputs

- archive-downloads.csv
- archive-descriptors.csv
- archive-file-inventory.csv
- git-content-comparisons.csv
- file-differences.csv
- revision-summary.csv
- queue-summary.csv
- summary.csv
- raw-page-index.csv
- raw-pages/
- errors.csv
- run-history.csv
- warnings.txt

## Current run

Run ID: 20260819-133206124
Processed this run: 1
Failed this run: 0
Imported from Analysis 08 cache this run: 0
Browser downloads this run: 1
