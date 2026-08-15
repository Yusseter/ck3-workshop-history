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

The data in this directory is retained as an audit trail for the reconstruction process.
