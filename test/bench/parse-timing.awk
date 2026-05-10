#!/usr/bin/env -S gawk -f
#
# Parse cardano-node TraceDispatcher human-format logs from stdin and emit
# one CSV row per CopiedBlockToImmutableDB event:
#
#   applied_at_unix_ms,slot,hash
#
# Expected line shape (ANSI colour codes optional, stripped if present):
#
#   [2026-05-04 13:36:17.6806Z][ymir:ChainDB.CopyToImmutableDBEvent.CopiedBlockToImmutableDB](Debug,29) Copied block <hash> at slot <slot> to the ImmDB
#
# Why CopiedBlockToImmutableDB? During fast ImmutableDB sync, the high-level
# chain-extension event (`AddedToCurrentChain`) fires only ~once per batch,
# so AddedToCurrentChain is too sparse for per-block timing. The Copy event
# fires once per block as it's committed to the immutable DB — this is the
# canonical per-block signal during bulk sync. sync-bench.sh patches the
# trace config to enable it at severity Debug with no rate cap.
#
# Timestamps carry 4 fractional digits (0.1 ms); we round to millisecond
# precision for the CSV. mktime needs gawk's UTC-aware extension form
# `mktime(spec, 1)`.

BEGIN {
  # When resuming a previous run, the orchestrator seeds the timing CSV
  # with the prior rows (which already carry the header) and asks us to
  # append, so we skip emitting a fresh header.
  if (!skip_header) print "applied_at_unix_ms,slot,hash"
  fflush()
}

# Strip ANSI colour escapes so the regexes don't have to deal with them.
{
  gsub(/\033\[[0-9;]*m/, "")
}

/CopiedBlockToImmutableDB.*Copied block /  {
  if (match($0, /\[([0-9]{4})-([0-9]{2})-([0-9]{2}) ([0-9]{2}):([0-9]{2}):([0-9]{2})\.([0-9]+)Z\]/, ts) == 0) next
  if (match($0, /Copied block ([a-f0-9]+) at slot ([0-9]+)/, m) == 0) next

  spec = ts[1] " " ts[2] " " ts[3] " " ts[4] " " ts[5] " " ts[6]
  secs = mktime(spec, 1)
  if (secs < 0) next

  # Normalise the fractional component to milliseconds.
  frac = ts[7]
  if (length(frac) >= 3)      msec = substr(frac, 1, 3) + 0
  else if (length(frac) == 2) msec = (frac + 0) * 10
  else if (length(frac) == 1) msec = (frac + 0) * 100
  else                        msec = 0

  printf "%d,%s,%s\n", secs * 1000 + msec, m[2], m[1]
  fflush()
}
