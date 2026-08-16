# Analysis 06 - Skymods Archive Inventory

Generated: 2026-08-16 14:34:32 +03:00

This analysis inventories Skymods catalogue pages and revision links for the
selected CK3 Workshop targets.

It does not download or validate the contents of any Modsbase archive.

## Inputs

- analysis/results/05-steam-git-candidate-mapping/steam-git-event-matrix.csv

## Outputs

### source-config.csv

The exact Skymods catalogue page assigned to each selected Workshop item.

### skymods-mod-summary.csv

One row per selected mod containing:

- catalogue page identity
- primary Workshop ID validation
- current Skymods revision timestamp
- declared and parsed old-revision counts
- current file-size metadata
- raw-page SHA-256 provenance

### skymods-revisions.csv

One row for every current or historical revision exposed by Skymods.

Revision timestamps are retained as displayed by Skymods and additionally
normalized without timezone conversion.

ContentVerified remains False because no archive bytes are inspected here.

### steam-skymods-time-candidates.csv

Potential Steam-event / Skymods-revision relationships based only on calendar
proximity of up to two days.

Steam's displayed timestamp and Skymods' UTC timestamp are not assumed to use
the same time basis.

UnadjustedWallClockDeltaHours is diagnostic only and must not be interpreted as
a canonical timezone conversion.

Every archive candidate remains UNVERIFIED.

### raw-page-index.csv

SHA-256 provenance for the retained Skymods catalogue HTML pages.

### raw-pages/

Exact downloaded catalogue pages used by this analysis.

### summary.csv

Per-mod Steam event, Skymods revision, and archive-candidate counts.

## Evidence policy

A Skymods revision link proves only that an archive candidate is exposed by
Skymods for the displayed revision time.

It does not prove that:

- the archive belongs to the expected Workshop item
- the archive contents match a historical Git snapshot
- the archive corresponds to a specific Steam Change Notes event
- the archive timestamp is an exact Steam Workshop update timestamp

Those questions require archive-content inspection.

The next content-verification stage should validate downloaded candidates using
descriptor Workshop IDs, file inventories, deterministic fingerprints, and
historical Git snapshot comparisons before assigning KNOWN + RECOVERED or
KNOWN + EXISTING statuses.

## Validation

Steam events: 1198
Target mods: 13
Parsed Skymods pages: 13
Parsed Skymods revisions: 605
Steam/Skymods time candidate pairs: 1206
Warnings: 0
Validation errors: 0
