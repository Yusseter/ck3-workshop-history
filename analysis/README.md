# Analysis

Research material used to design and reconstruct the CK3 Workshop history archive.

## Results

### 01-inventory

Initial inventory of the existing per-mod repositories, including:

- repository metadata
- existing commit history
- current ignore rules
- file sizes
- installed Steam Workshop copies

### 02-content-classification

Current-content analysis including:

- exact file-type inventory
- text/binary classification
- large-file analysis
- ignore-rule provenance
- comparison between local archive copies and current Steam Workshop copies

### 03-historical-commits

Historical Git analysis including:

- deterministic tree fingerprints
- descriptor metadata for every commit
- file changes per commit
- extension inventories
- duplicate-tree detection

### 04-steam-event-inventory

Steam Workshop Change Notes inventory including:

- raw Change Notes pages retained for audit and reproducibility
- declared and parsed event counts per mod
- normalized Steam-displayed timestamps
- rate-limit-aware Steam retrieval
- per-page SHA-256 provenance

The Steam event inventory now validates all selected mods against Steam's declared Change Notes counts. Events are identified from Steam's actual changelog headline structure rather than arbitrary body text beginning with `Update:`, producing 1,198 validated events with no parser warnings.

### 05-steam-git-candidate-mapping

Steam-to-Git candidate mapping including:

- one matrix row for every validated Steam Change Notes event
- deterministic Steam/Git candidate-pair scoring
- historical Git commit structural classification
- placeholder and cross-target snapshot detection
- current-tree evidence from the local/Steam comparison
- explicit ambiguous and unresolved classifications

This analysis maps 1,198 Steam events against 116 historical Git commits and produces 318 candidate pairs. Candidate relationships remain unverified at this stage; ambiguous same-day updates, repair commits, invalid snapshots, and unresolved events are intentionally preserved for later content and archive-source verification.

### 06-skymods-archive-inventory

Skymods archive inventory including:

- validated catalogue pages for all selected Workshop items
- current and historical revision inventories
- Modsbase archive-candidate links
- normalized Skymods-displayed UTC timestamps
- Steam-to-Skymods time-proximity candidates
- raw catalogue pages retained with SHA-256 provenance

The inventory validates all 13 selected Skymods catalogue pages against their expected Workshop IDs and records 605 exposed revisions with no parser warnings or validation errors. Steam-to-Skymods relationships remain unverified at this stage; revision timestamps and download links identify archive candidates only and are not treated as proof of Workshop-event identity or content equivalence.

### 07-archive-verification-plan

Archive verification planning including:

- empirical Steam-to-Skymods timestamp offset clustering
- bidirectional temporal candidate classification
- Steam-to-Git-to-Skymods candidate relationships
- per-commit archive verification priorities
- first-pass archive selection for ambiguous historical snapshots
- later recovery candidates for missing Workshop revisions

The analysis combines 1,198 Steam events, 116 historical Git commits, and 605 Skymods revisions. It identifies 606 dominant temporal pairs and 144 Git/Skymods candidate relationships, prioritizing 52 archive revisions for first-pass content verification while leaving all archive contents unverified.

### 08-archive-content-pilot

Archive-content pilot verification including:

- automated Modsbase retrieval through an isolated Chrome session
- local archive caching for deterministic reruns
- ZIP SHA-256 provenance and path-safe extraction
- descriptor `remote_file_id` validation
- Git attribute-aware projected blob comparison against historical commits
- raw browser pages retained with SHA-256 provenance
- content-based resolution of selected ambiguous archive/Git relationships

The pilot verifies four high-value P0 Skymods revisions against six historical Git candidates. All four archive descriptors match their expected Workshop IDs, and each revision produces exactly one projected historical Git match after applying the historical repository's Git clean and text-normalization behavior.

The verified projected matches are:

- CFG `3206891770|2` → `2e2602f56ee08890cc915690989b121c299ca8d0`
- CE `2829397295|3` → `8a0cffb5c6f82b7addeb8e91e25799b95d3689ae`
- EPE-CFP `2996881191|3` → `dbebe469551c494e9481693a5ef74dcc847c77b7`
- MBP-EPE-CFP `2543865921|3` → `c86a00c074ec2900035bcd8cca81c850b38d6a3c`

The rejected alternative CE and EPE-CFP candidates each contain five genuine tracked-blob differences, producing ten difference rows in total. No final Steam-event `KNOWN + EXISTING` or `KNOWN + RECOVERED` status is assigned by this pilot stage.

### 09-first-pass-archive-verification

First-pass archive verification including:

- resumable verification of all 52 P0 archive revisions selected by Analysis 07
- reuse of verified Analysis 08 archive content where available
- automated Modsbase retrieval through isolated Chrome/CDP sessions
- ZIP SHA-256 provenance and descriptor Workshop-ID validation
- complete archive path and size inventories
- Git attribute-aware projected blob comparison against historical candidates
- persistent per-revision state and cumulative result rebuilding
- unattended batch execution through the run-to-completion helper

The analysis completes all 52 first-pass archive revisions with no final errors. Of these, 41 resolve to a unique projected historical Git match, one retains multiple exact projected Git matches, and 10 have no exact projected Git match among their Analysis 07 candidates.

All 52 verified archives contain exactly one `descriptor.mod` whose `remote_file_id` matches the expected Workshop ID. Archive-to-Git relationships remain content-verification evidence only; this stage does not by itself assign final Steam-event `KNOWN + EXISTING` or `KNOWN + RECOVERED` statuses.

The data in this directory is retained as an audit trail for the reconstruction process.
