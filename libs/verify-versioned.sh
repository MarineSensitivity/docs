#!/usr/bin/env bash
# Plan B verification. NOTE: every check assigns `fail` in the CURRENT shell —
# an earlier version set it inside $( ), i.e. a subshell, so the summary line
# printed "ALL PASSED" while four checks had failed. A verification that cannot
# report failure is exactly the class of bug this project keeps hitting.
S=/private/tmp/claude-501/-Users-bbest-Github-MarineSensitivity-workflows/c6d5128c-1ac1-4762-835e-7b1d2d02d01d/scratchpad
cd /Users/bbest/Github/MarineSensitivity/docs || exit 1
fail=0
ok()  { printf "%-70s %s\n" "$1" "PASS"; }
no()  { printf "%-70s %s\n" "$1" "FAIL${2:+ ($2)}"; fail=1; }
chk() { if [ "$1" = 0 ]; then no "$2" "$3"; else ok "$2"; fi; }   # $1: 1=pass

# releases.html is INTENTIONALLY cross-version (it IS the comparison page);
# search.json and index are indexes of it.
ch() { ls "$1"/*.html | grep -vE "releases\.html|search|/index\.html"; }

echo "== 1. No cross-version bleed =="
for tok in mdl_key global05 primary_producer is_valid_usa; do
  n=$(grep -l "$tok" $(ch $S/book_v3) 2>/dev/null | wc -l | tr -d ' ')
  chk $([ "$n" = 0 ] && echo 1 || echo 0) "  v3 build never says '$tok'" "$n files"
done
# native_asset appears in v3's db.html only inside the "Not published by v3" callout,
# which is the OPPOSITE of bleed — assert that, rather than its absence.
# strip tags first: the callout text is broken up by <code> spans, so a
# raw grep -o "...[^<]*" stops at the first tag and finds nothing — which read
# as a content failure when the content was correct.
n=$(python3 -c "
import re,html,sys
t=re.sub('<[^>]+>',' ',open('$S/book_v3/db.html').read()); t=html.unescape(t); t=re.sub(r'\\s+',' ',t)
i=t.find('Not published by v3')
print(1 if i>=0 and 'native_asset' in t[i:i+200] else 0)")
m=$(grep -l native_asset $(ch $S/book_v3) 2>/dev/null | grep -cv "db.html")
chk $([ "$n" -ge 1 ] && [ "$m" = 0 ] && echo 1 || echo 0) "  v3 names native_asset only as NOT published" "$m other files"
for tok in mdl_seq planarea; do
  n=$(grep -l "$tok" $(ch $S/book_v8) 2>/dev/null | wc -l | tr -d ' ')
  chk $([ "$n" = 0 ] && echo 1 || echo 0) "  v8 build never says '$tok'" "$n files"
done

echo "== 2. Numbers match the release =="
g() { grep -q "$2" "$S/$1" 2>/dev/null && echo 1 || echo 0; }
chk $(g book_v3/taxonomy.html "9,795")            "  v3 taxonomy reports 9,795 valid species"
chk $(g book_v8/taxonomy.html "17,112")           "  v8 taxonomy reports 17,112 valid species"
chk $(g book_v3/data-sources.html "7 source datasets") "  v3 data-sources says 7 datasets"
chk $(g book_v8/data-sources.html "8 source datasets") "  v8 data-sources says 8 datasets"
chk $(g book_v3/releases.html "9,795")            "  releases table carries v3's own count"
chk $(g book_v3/releases.html "17,112")           "  releases table carries v8's count too"
u=0
for f in $S/book_v3/*.html $S/book_v8/*.html; do
  grep -q 'r doc_ver()\|r doc_stat(\|r doc_manifest(' "$f" 2>/dev/null && { echo "     unevaluated inline R: $(basename $f)"; u=1; }
done
chk $([ "$u" = 0 ] && echo 1 || echo 0) "  no unevaluated inline R in either build"

echo "== 5. Links resolve =="
for ref in "apps/mapgl.qmd" "apps/mapsp.qmd" "fig-mapgl-flower" "calc_scores.qmd"; do
  n=$(grep -rl -- "$ref" *.qmd apps/*.qmd releases/*.qmd 2>/dev/null | wc -l | tr -d ' ')
  chk $([ "$n" = 0 ] && echo 1 || echo 0) "  source no longer references '$ref'" "$n"
done
for v in v3 v8; do
  b=0
  for h in $(grep -ho 'href="[a-zA-Z0-9_/-]*\.html' $S/book_$v/*.html | sed 's/.*href="//' | sort -u); do
    [ -f "$S/book_$v/$h" ] || { echo "     broken: $h"; b=$((b+1)); }
  done
  chk $([ "$b" = 0 ] && echo 1 || echo 0) "  $v internal chapter links all resolve" "$b broken"
done

echo "== 6. Docs match the live apps =="
for u in https://app.marinesensitivity.org/scores/ https://app.marinesensitivity.org/species/ \
         "https://app.marinesensitivity.org/scores/?ver=v3" "https://app.marinesensitivity.org/species/?ver=v8"; do
  c=$(curl -s -o /dev/null -w '%{http_code}' -L --max-time 25 "$u")
  chk $([ "$c" = 200 ] && echo 1 || echo 0) "  $u" "HTTP $c"
done
n=$(grep -rl "pg_tileserv\|PostgREST" *.qmd 2>/dev/null | xargs grep -L "etired\|commented out" 2>/dev/null | wc -l | tr -d ' ')
chk $([ "$n" = 0 ] && echo 1 || echo 0) "  no chapter presents PostGIS/pg_tileserv as current" "$n"

echo
if [ "$fail" = 0 ]; then echo "ALL AUTOMATED CHECKS PASSED"; else echo ">>> SOME CHECKS FAILED <<<"; fi
exit $fail
