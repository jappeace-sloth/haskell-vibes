---
name: ods-spreadsheet
description: >
  Edit, create, and read OpenDocument spreadsheets (.ods) headlessly: modify
  cells, recalculate formulas with LibreOffice, and read the computed results
  back. Use when working with .ods files, when formula results must be
  recomputed after an edit, or when exporting spreadsheet values to CSV.
  Covers the LibreOffice-under-nix sandbox gotchas.
---

# ODS spreadsheets: edit cells, recalc, read results

An .ods file is a zip archive. The members that matter:

- `mimetype`: must be the FIRST entry and STORED (uncompressed), containing
  `application/vnd.oasis.opendocument.spreadsheet`.
- `content.xml`: all sheets, cells, and formulas.
- `META-INF/manifest.xml`: lists the members.

A cell looks like:

```xml
<table:table-cell office:value-type="float" office:value="10"><text:p>10</text:p></table:table-cell>
```

A formula cell carries the formula AND a cached result:

```xml
<table:table-cell table:formula="of:=SUM([.A1:.A2])" office:value-type="float" office:value="30"><text:p>30</text:p></table:table-cell>
```

Cross-sheet references: `of:=SUM([Sheet1.A1:.B1])`.

## Tooling policy

- One-off edits and throwaway analysis sheets: Python stdlib (`zipfile` +
  `xml.etree` or string surgery on `content.xml`) is fine.
- Structural / recurring tooling (anything committed as a program): write it
  in Haskell (e.g. `zip-archive` + `xml-conduit`), following the usual house
  style: top-level definitions with type signatures, no silent failure.

## The pipeline: modify → recalc → read

Editing `content.xml` by hand leaves every dependent formula's cached
`office:value` STALE. Never read cached values after an edit. Always run the
file through headless LibreOffice, which recalculates on load, and read the
values it computes.

Use the bundled helper (see [scripts/ods-to-csv.sh](scripts/ods-to-csv.sh)):

```bash
scripts/ods-to-csv.sh input.ods outdir/
```

It exports EVERY sheet to `outdir/<base>-<SheetName>.csv` with freshly
recalculated values. Equivalent inline:

```bash
export DBUS_SESSION_BUS_ADDRESS="disabled:"      # skip wrapper's dbus spawn
export HOME=<writable dir> XDG_RUNTIME_DIR=<writable dir>
nix-shell -p libreoffice --run \
  'soffice --headless --convert-to "csv:Text - txt - csv (StarCalc):44,34,UTF8,1,,0,false,true,true,false,false,-1" --outdir OUTDIR FILE.ods'
```

To keep .ods as the output format with refreshed caches, `--convert-to ods`
into a different outdir works the same way.

## Gotchas (each cost real debugging time)

- The nixpkgs `soffice` wrapper spawns a private dbus daemon under
  `/run/user/$(id -u)`, which is permission-denied in the vibe container and
  aborts the whole script (`bash -e`). Setting `DBUS_SESSION_BUS_ADDRESS` to
  any non-empty value (e.g. `disabled:`) skips that branch entirely.
- `HOME` and `XDG_RUNTIME_DIR` must point at writable directories or the
  LibreOffice profile creation fails.
- When writing `content.xml` from scratch: declare the formula namespace
  `xmlns:of="urn:oasis:names:tc:opendocument:xmlns:of:1.2"` on the root
  element. Without it every formula turns into `Err:510`.
- Plain `--convert-to csv` exports ONLY the first sheet, silently. The long
  filter string above ends in `-1` (the sheet-selection token), which means
  "all sheets, one CSV file per sheet". A positive N exports just sheet N.
- When zipping, write `mimetype` first with `zipfile.ZIP_STORED`.
- Dutch locale sheets may use `;` as argument separator in the UI, but the
  stored ODF formula syntax is always canonical (`of:=SUM([.A1:.A2])`).
