# Analysis 10 - Event Resolution Matrix

Generated: 2026-08-19 19:15:20 +03:00

This analysis combines Steam events, historical Git candidates, Analysis 07
Steam/Skymods temporal alignment, and Analysis 09 content-verified archives into
one conservative event-level resolution matrix.

## Inputs

- Analysis 04 Steam event inventory
- Analysis 05 Steam/Git candidate mapping and Git structural classification
- Analysis 07 Steam/Skymods temporal alignment
- Analysis 09 first-pass archive verification

Input files are recorded with SHA-256 provenance in `input-files.csv`.

## Resolution policy

This stage promotes a Steam event to `KNOWN + EXISTING` when a
content-verified archive has a unique exact projected historical Git match and
the archive is sufficiently anchored to the Steam event.

An event may also resolve to `KNOWN + EXISTING` when its verified archive is
byte-identical to another verified revision whose archive already has one
unique exact historical Git match. This preserves repeated Workshop events that
published identical content without incorrectly treating the later event as a
recovery.

A `NO_PROJECTED_GIT_MATCH` result from Analysis 09 rules out only the tested
candidate Git commits. It is therefore not sufficient by itself to assign
`KNOWN + RECOVERED`. Those archives remain `UNVERIFIED` until they are
compared exhaustively against every historical Git snapshot in the same
repository.

Multiple projected Git matches remain `UNVERIFIED` because Git identity is
still ambiguous.

`KNOWN + MISSING` is deliberately not assigned by this stage.

Historical Git placeholders and cross-target snapshots are classified
`INVALID`. An `EXTERNAL_DESCRIPTOR_MISMATCH` is not automatically
classified as invalid, because descriptor-only near-match evidence may still
show that the snapshot is closely related to the target Workshop content.

Steam timestamps remain the captured Steam-displayed values from Analysis 04.
This stage does not perform timezone conversion or promote
`CanonicalTimeVerified`.

## Results

Steam events: 1198
Historical Git commits: 116
Analysis 09 verified archive/event links: 52

KNOWN + EXISTING events: 42
KNOWN + RECOVERED events: 0
KNOWN + MISSING events: 0
UNVERIFIED events: 1156

KNOWN + EXISTING Git commits: 41
INVALID Git commits: 8

Descriptor-only near matches: 3
Duplicate verified archive SHA-256 groups: 1
EXISTING events resolved through byte-identical archive evidence: 1

Warnings: 0
Validation errors: 0

## Outputs

- `input-files.csv`
- `event-resolution-matrix.csv`
- `verified-archive-event-links.csv`
- `git-resolution-matrix.csv`
- `descriptor-only-near-matches.csv`
- `event-status-summary.csv`
- `git-status-summary.csv`
- `repo-summary.csv`
- `warnings.txt`
- `validation-errors.txt`

This is the first conservative status-assignment pass. Remaining unverified
events and Git snapshots require later archive-recovery or local-repair
analysis before canonical Workshop history is constructed.
