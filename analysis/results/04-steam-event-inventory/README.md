# Analysis 04 — Steam Event Inventory

Read-only inventory of Steam Workshop Change Notes for the selected CK3 mods.

## Outputs

- `steam-events.csv`
- `steam-mod-summary.csv`
- `raw-page-index.csv`
- `warnings.txt`
- `raw-pages/`

Every fetched Steam Change Notes page is retained as raw HTML and indexed by
SHA-256 so the parser results can be audited and reproduced.

`raw-pages/` also acts as the local cache for subsequent analysis runs. Set
`$ForceRefresh = $true` in the analysis script when the Steam pages should be
downloaded again.

Events are identified from Steam's actual changelog headline HTML structure
(`div.changelog.headline`) rather than from arbitrary text beginning with
`Update:`. Change-note bodies may themselves contain text beginning with
`Update:` and must not be interpreted as separate Workshop events.

`RawDisplayedTime` is the timestamp text returned by the direct Steam HTTP
request used for this analysis.

`NormalizedFetchedTime` converts that returned text to `YYYY-MM-DD HH:mm`
without performing a timezone conversion.

It is not yet treated as the canonical Workshop timestamp. Steam's browser
display context must first be compared against these values. Every event is
therefore emitted with `CanonicalTimeVerified=False`.

This analysis does not modify any source archive repository or Steam Workshop
folder and does not automatically classify Git snapshot matches.
