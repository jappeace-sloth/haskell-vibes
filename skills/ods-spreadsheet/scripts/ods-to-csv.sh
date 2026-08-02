#!/usr/bin/env bash
# Recalculate an .ods with headless LibreOffice and export every sheet to CSV.
# Usage: ods-to-csv.sh FILE.ods OUTDIR
# Produces OUTDIR/<base>-<SheetName>.csv per sheet, values freshly computed.
set -euo pipefail

if [ $# -ne 2 ]; then
    echo "usage: $0 FILE.ods OUTDIR" >&2
    exit 1
fi

input_file=$1
output_dir=$2
mkdir -p "$output_dir"

# The nixpkgs soffice wrapper spawns dbus under /run/user unless a session
# bus address is already set; /run/user is not writable in the container.
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-disabled:}"

profile_dir=$(mktemp -d)
export HOME="$profile_dir"
export XDG_RUNTIME_DIR="$profile_dir"

# Filter tokens, in order: FieldSeparator=44 (comma), TextDelimiter=34
# (quote), CharSet=UTF8, FirstRow=1, CellFormats=(default), LanguageId=0,
# QuotedFieldAsText=false, DetectSpecialNumbers=true,
# SaveCellContentsAsShown=true, ExportCellFormulas=false,
# RemoveSpacesFromCells=false, SheetToExport=-1. That last -1 exports ALL
# sheets, one file per sheet; plain --convert-to csv drops sheet 2+.
filter='csv:Text - txt - csv (StarCalc):44,34,UTF8,1,,0,false,true,true,false,false,-1'

if command -v soffice >/dev/null 2>&1; then
    soffice --headless --convert-to "$filter" --outdir "$output_dir" "$input_file"
else
    nix-shell -p libreoffice --run \
        "soffice --headless --convert-to \"$filter\" --outdir \"$output_dir\" \"$input_file\""
fi
