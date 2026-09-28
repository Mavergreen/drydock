# tests/golden_match.awk -- match a golden table's rows with a run's by
# contents, for tests/raise_corpus_test.sh and tests/raise_oracle_counts_test.sh.
#
#   awk -f golden_match.awk -v tm=TM -v rm=RM TABLE_ROWS RUN_ROWS
#
# Each row is "file", a tab, a path, a tab, the sha256 of the file's x86_64
# slice, and what was measured. A row is matched when the other side has the
# same path with the same sha256: the table's matched rows go to TM and the
# run's to RM, each in its own order, for the caller to compare. A path only
# in the table is missing, one only in the run is added, and one on both
# sides with different contents is changed; each is information, not a
# difference. Prints up to 5 of each kind, then one line of counts:
# "matched M table T run R missing X added Y changed Z".
BEGIN { FS = "\t"; printf "" > tm; printf "" > rm }
FNR == NR {
    if ($1 != "file") next
    nt++
    tsha[$2] = $3
    trow[nt] = $0
    tpath[nt] = $2
    next
}
$1 == "file" {
    nr++
    rsha[$2] = $3
    if (!($2 in tsha)) { added++; if (added <= 5) print "INFO added: " $2; next }
    if (tsha[$2] != $3) { changed++; if (changed <= 5) print "INFO changed: " $2; next }
    print > rm
}
END {
    for (i = 1; i <= nt; i++) {
        p = tpath[i]
        if (!(p in rsha)) { missing++; if (missing <= 5) print "INFO missing: " p; continue }
        if (rsha[p] != tsha[p]) continue
        matched++
        print trow[i] > tm
    }
    printf "matched %d table %d run %d missing %d added %d changed %d\n",
        matched, nt, nr, missing, added, changed
}
