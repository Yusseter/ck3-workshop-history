# Analysis 05 - Steam / Git Candidate Mapping

Generated: 2026-08-15 23:06:38 +03:00

This analysis compares the authoritative Steam Change Notes event inventory from
Analysis 04 with the historical Git snapshot inventory from Analysis 03.

It is intentionally a candidate-generation stage, not a final reconstruction
decision stage.

## Inputs

- analysis/results/04-steam-event-inventory/steam-events.csv
- analysis/results/03-historical-commits/commit-snapshots.csv
- analysis/results/02-content-classification/current-comparison-summary.csv
- analysis/results/01-inventory/repo-summary.csv

## Outputs

### steam-git-event-matrix.csv

One row for every Steam Change Notes event.

The automatically selected Git row, when present, is only a candidate.
FinalStatus remains UNVERIFIED for every event in this analysis.

### candidate-pairs.csv

All Git / Steam candidate pairs admitted by deterministic matching rules.

Evidence may include:

- commit subject calendar-date proximity
- Git author calendar-date proximity
- matching version tokens
- matching descriptor Workshop ID
- current-head evidence from the existing local/Steam comparison

### git-commit-classification.csv

Classifies every historical Git commit before candidate matching.

Important structural categories include:

- NORMAL
- PLACEHOLDER
- CROSS_TARGET_DESCRIPTOR_MISMATCH
- EXTERNAL_DESCRIPTOR_MISMATCH
- DESCRIPTOR_ID_MISSING

Placeholder commits and commits whose descriptor points to another selected
target mod are excluded from automatic candidate mapping.

### summary.csv

Per-mod counts for Steam events, historical Git commits, candidate classes,
ambiguities, unresolved events, and structural commit classifications.

### warnings.txt

Review items that are not fatal validation errors.

## Matching policy

Steam NormalizedFetchedTime is used only as the calendar/time representation
captured by Analysis 04. It is not treated as a timezone-converted canonical
timestamp.

A Git commit is not declared to be a real Workshop revision merely because its
date or version resembles a Steam event.

Same-day and near-same-day events are deliberately left ambiguous when the
available evidence does not distinguish them.

Current-head evidence is stronger than date-only evidence, but still does not
change FinalStatus from UNVERIFIED in this stage.

Skymods and other external archive candidates are outside the scope of this
analysis and will be added only after the Steam/Git relationship has been
mapped independently.

## Validation

Steam events: 1198
Git commits: 116
Candidate pairs: 318
Event matrix rows: 1198
Repositories: 13
Warnings: 3
Validation errors: 0
