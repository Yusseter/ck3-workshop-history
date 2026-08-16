# Analysis 07 - Archive Verification Plan

Generated: 2026-08-16 14:59:50 +03:00

This analysis combines the Steam/Git candidate mapping from Analysis 05 with
the Skymods revision inventory from Analysis 06.

It does not download or inspect any archive content.

The purpose of this stage is to reduce the archive-content verification problem
to a deterministic and auditable retrieval plan before large historical mod
archives are downloaded.

## Inputs

- analysis/results/05-steam-git-candidate-mapping/steam-git-event-matrix.csv
- analysis/results/05-steam-git-candidate-mapping/candidate-pairs.csv
- analysis/results/05-steam-git-candidate-mapping/git-commit-classification.csv
- analysis/results/06-skymods-archive-inventory/skymods-revisions.csv
- analysis/results/06-skymods-archive-inventory/steam-skymods-time-candidates.csv

## Temporal alignment

Analysis 06 deliberately treated Steam and Skymods timestamps as different time
bases.

This analysis therefore does not assume a named timezone conversion.

Instead, it measures repeated whole-hour relationships directly from the
captured datasets.

The dominant observed whole-hour offsets are:

6, 7, 8 hours

A temporal pair is considered bidirectionally unique only when:

- its observed offset belongs to a dominant cluster
- the Steam and Skymods timestamps have the same minute
- the Steam event has only one dominant Skymods candidate
- the Skymods revision has only one dominant Steam event candidate

Temporal alignment is evidence for selecting an archive candidate. It is not
content verification.

## Verification priorities

P0_AMBIGUOUS

Archive content is particularly useful because the temporal relationship,
Steam/Git relationship, or Git/archive relationship is ambiguous.

P1_VERIFY_GIT_CANDIDATE

A plausible Git/archive relationship exists but still requires content
verification.

P2_STRONG_GIT_CANDIDATE

Existing metadata gives a strong relationship. Content verification is useful
but not the first retrieval priority.

P3_CURRENT_HEAD_OPTIONAL

The current Git working tree already has independent current-Steam comparison
evidence, so downloading the corresponding Skymods archive is optional for the
first verification pass.

## Outputs

### offset-clusters.csv

Observed whole-hour relationships between the captured Steam and Skymods
timestamps.

### steam-skymods-alignment.csv

Every Analysis 06 time candidate with its measured offset and temporal
classification.

### git-skymods-candidates.csv

Candidate relationships connecting:

Steam event -> historical Git commit -> Skymods revision

No relationship in this file is content-verified.

### git-verification-summary.csv

One row for every historical Git commit, including archive candidate counts and
the resulting verification priority.

### download-plan.csv

One row for every Skymods revision.

FirstPassRecommended identifies the archive candidates that should be reviewed
before bulk recovery work because they can resolve ambiguous historical Git
relationships.

### summary.csv

Per-mod verification-planning statistics.

## Next stage

The next analysis should download only a reviewed subset of the archive plan
and compare archive contents against historical Git snapshots.

Content verification should include at minimum:

- archive integrity
- descriptor remote_file_id
- descriptor metadata
- path inventory
- byte hashes for files represented by the historical Git snapshot
- deterministic projected snapshot fingerprints

Only content evidence should promote an archive relationship to a validated
historical snapshot.

## Validation

Steam events: 1198
Historical Git commits: 116
Skymods revisions: 605
Analysis 06 time candidates: 1206
Dominant temporal pairs: 606
Git/Skymods candidate rows: 144
First-pass archive revisions: 52
Recovery-candidate revisions: 522
Warnings: 2
Validation errors: 0
