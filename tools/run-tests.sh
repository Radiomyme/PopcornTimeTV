#!/bin/zsh
# Every test of the project from one command (see README, "Tests").
#
#   tools/run-tests.sh [quick]  The unit tests, in parallel, in well under a minute:
#                               - PopcornTimeTests (this repo, macOS): the extra sources, bandwidth,
#                                 loading phases, bounded storage, the remux and FarTargetWatch rules
#                               - PopcornTorrent: PopcornTorrentLogicTests, and PopcornTorrent-Tests
#                                 (offline streaming: a seeder on 127.0.0.1, inside the localhost-only
#                                 sandbox)
#                               A test bundle is rebuilt only when its sources changed, then run with
#                               xctest directly (xcodebuild alone costs ~15 s per run).
#   tools/run-tests.sh full     quick, then the long benches, the independent ones in parallel; a
#                               bench whose kit is not on this Mac is skipped with a note:
#                               - PopcornTorrent's SessionHarness, 10 modes and the network settings
#                                 of the tvOS / iOS / Mac profiles (offline, sandboxed)          ~2.5 min
#                               - P10 and B6 (a real AVPlayer on a 20 s clip; format-coverage-wip, a
#                                 local bench folder, not in the repository)                    ~3 min
#                               - with PT_FORMAT_BENCH=<restored bench folder>: the remux e2e engine
#                                 (~17 min), then the F3 bench (~90 min), see format-coverage-wip/REPRISE.md
#                               - with PT_BOUNDED_RUNS=1: the bounded-storage disk-image runs   ~5 min
#   tools/run-tests.sh clean    Deletes the cache (builds, logs).
#
# Environment:
#   PT_TEST_CACHE       builds, stamps and logs (default: ~/Library/Caches/PopcornTimeTV-tests)
#   POPCORNTORRENT_DIR  the PopcornTorrent package (default: the local package in PopcornTime.xcworkspace)
#   PT_APP_DERIVED_DATA the app's DerivedData folder to build the tests in (default: $PT_TEST_CACHE/app-dd)
#   PT_FORK_PACKAGES    an already resolved package folder for PopcornTorrent (-clonedSourcePackagesDirPath)
# Nothing here contacts a tracker, the DHT or a peer: the torrent tests use generated torrents
# without trackers and a seeder on 127.0.0.1, under sandbox-exec (tools/localhost-only.sb).
# Exit code 0 when every suite that ran passed.
set -u
zmodload zsh/datetime

REPO=${0:A:h:h}
MODE=${1:-quick}
CACHE=${PT_TEST_CACHE:-$HOME/Library/Caches/PopcornTimeTV-tests}
SANDBOX=$REPO/tools/localhost-only.sb
ARCH=$(uname -m)

case $MODE in
  quick|full) ;;
  clean) rm -rf "$CACHE"; print "Removed $CACHE"; exit 0 ;;
  *) print -u2 "usage: ${0:t} [quick|full|clean]"; exit 2 ;;
esac

LOGS=$CACHE/logs/$(date +%Y%m%d-%H%M%S)
mkdir -p $LOGS $CACHE/bin $CACHE/work
XCTEST=$(xcrun --find xctest) || { print -u2 "xctest not found (Xcode command line tools)"; exit 2 }
RESULTS=$LOGS/results.txt
: > $RESULTS
# The bundles are built without code coverage; one built with it (Xcode's package schemes gather it)
# would write default.profraw into the current folder: into the logs instead.
export LLVM_PROFILE_FILE=$LOGS/coverage-%p.profraw

# One line per suite: name, PASS / FAIL / SKIP, seconds, detail.
record() { print -r -- "$1|$2|$3|$4" >> $RESULTS }

# The PopcornTorrent package: $POPCORNTORRENT_DIR, else the workspace's local package.
fork_dir() {
  if [[ -n ${POPCORNTORRENT_DIR:-} ]]; then print -r -- $POPCORNTORRENT_DIR; return; fi
  local p
  p=$(sed -n 's/.*location = "absolute:\([^"]*\)".*/\1/p' $REPO/PopcornTime.xcworkspace/contents.xcworkspacedata |
      while IFS= read -r line; do [[ -f $line/Package.swift && $line == *PopcornTorrent* ]] && print -r -- $line; done | head -1)
  print -r -- $p
}

# A short hash of the content of a git tree's inputs (the files as they are on disk, tracked or
# not): a commit that leaves them as they are (a README) does not change it, so nothing is rebuilt.
# Finder's .DS_Store files are not inputs.
inputs_hash() {
  local dir=$1; shift
  local files=$(git -C $dir ls-files --cached --others --exclude-standard -- "$@" |
      while IFS= read -r file; do [[ -f $dir/$file && ${file:t} != .DS_Store ]] && print -r -- $file; done | sort -u)
  { print -r -- $files; print -r -- $files | git -C $dir hash-object --stdin-paths } | shasum | cut -c1-16
}

# Pulls "Executed N tests, with F failures" out of an xctest log.
executed() { grep -E 'Executed [0-9]+ tests?' $1 | tail -1 | sed -E 's/^[[:space:]]*//; s/ \([0-9]+ unexpected\)//; s/ in [0-9.]+ \(([0-9.]+)\) seconds/ in \1 s/' }

# MARK: - Quick: the app's unit tests

app_tests() {
  local start=$EPOCHREALTIME dd=${PT_APP_DERIVED_DATA:-$CACHE/app-dd} stamp=$CACHE/app.stamp hash f
  # The workspace too: its package pins (Package.resolved) and a local package override decide
  # which PopcornTorrent the bundle is built against.
  hash=$(inputs_hash $REPO PopcornKit PopcornTime/Resources PopcornTime/Startup PopcornTimeTests PopcornTime.xcodeproj \
      PopcornTime.xcworkspace/contents.xcworkspacedata PopcornTime.xcworkspace/xcshareddata/swiftpm/Package.resolved)
  f=$(fork_dir); [[ -n $f ]] && hash=$hash-$(inputs_hash $f PopcornTorrent Package.swift Package.resolved)
  local products=$dd/Build/Products/Debug built=cached
  if [[ ! -d $products/PopcornTimeTests.xctest || $(cat $stamp 2>/dev/null) != $hash ]]; then
    built=built
    if ! xcodebuild build-for-testing -workspace $REPO/PopcornTime.xcworkspace -scheme PopcornTimeTests \
         -destination "platform=macOS,arch=$ARCH" -configuration Debug -derivedDataPath $dd -enableCodeCoverage NO \
         > $LOGS/app-build.log 2>&1; then
      record "PopcornTimeTests" FAIL $((EPOCHREALTIME - start)) "build failed: $LOGS/app-build.log"; return 1
    fi
    print -r -- $hash > $stamp
  fi
  # Not under sandbox-exec: a SIP-protected launcher would drop DYLD_FRAMEWORK_PATH (PopcornKit.framework).
  # These tests read recorded answers only (Fixtures); they never use the network.
  DYLD_FRAMEWORK_PATH=$products:$products/PackageFrameworks $XCTEST $products/PopcornTimeTests.xctest > $LOGS/app-tests.log 2>&1
  local rc=$?
  local checks=$(grep -E '^[A-Za-z0-9]+Tests: [0-9]+ checks' $LOGS/app-tests.log | awk '{s += $2} END {print s + 0}')
  record "PopcornTimeTests" $( ((rc == 0)) && print PASS || print FAIL ) $((EPOCHREALTIME - start)) "$(executed $LOGS/app-tests.log), $checks checks ($built)"
  return $rc
}

# MARK: - Quick: PopcornTorrent's unit and offline streaming tests

fork_tests() {
  local start=$EPOCHREALTIME f=$(fork_dir)
  if [[ -z $f ]]; then
    record "PopcornTorrent" SKIP 0 "no local package: set POPCORNTORRENT_DIR to a PopcornTorrent clone"; return 0
  fi
  if [[ ! -f $f/PopcornTorrentTests/PTOfflineStreamingTests.mm ]]; then
    # Older PopcornTorrent: its PopcornTorrent-Tests stream public torrents. Never run here.
    record "PopcornTorrent" SKIP 0 "$f has no offline streaming tests (PopcornTorrent-Tests streams public torrents there)"; return 0
  fi
  local dd=$CACHE/fork-dd stamp=$CACHE/fork.stamp hash built=cached
  hash=$(inputs_hash $f PopcornTorrent PopcornTorrentTests PopcornTorrentLogicTests Package.swift Package.resolved)
  local products=$dd/Build/Products/Debug
  if [[ ! -d $products/PopcornTorrent-Tests.xctest || $(cat $stamp 2>/dev/null) != $hash ]]; then
    built=built
    local -a packages=()
    [[ -n ${PT_FORK_PACKAGES:-} ]] && packages=(-clonedSourcePackagesDirPath $PT_FORK_PACKAGES -disableAutomaticPackageResolution)
    if ! (cd $f && xcodebuild build-for-testing -scheme PopcornTorrent -destination "platform=macOS,arch=$ARCH" \
            -derivedDataPath $dd -enableCodeCoverage NO $packages) > $LOGS/fork-build.log 2>&1; then
      record "PopcornTorrent" FAIL $((EPOCHREALTIME - start)) "build failed: $LOGS/fork-build.log"; return 1
    fi
    print -r -- $hash > $stamp
  fi
  local rc=0 logic stream
  $XCTEST $products/PopcornTorrentLogicTests.xctest > $LOGS/fork-logic.log 2>&1 || rc=1
  logic=$(executed $LOGS/fork-logic.log)
  record "PopcornTorrentLogicTests" $( ((rc == 0)) && print PASS || print FAIL ) $((EPOCHREALTIME - start)) "$logic ($built)"
  local s2=$EPOCHREALTIME
  sandbox-exec -f $SANDBOX $XCTEST $products/PopcornTorrent-Tests.xctest > $LOGS/fork-streaming.log 2>&1
  local rc2=$?
  record "PopcornTorrent-Tests (offline)" $( ((rc2 == 0)) && print PASS || print FAIL ) $((EPOCHREALTIME - s2)) "$(executed $LOGS/fork-streaming.log)"
  return $(( rc || rc2 ))
}

# MARK: - Full: SessionHarness (PopcornTorrent), its runs in parallel

# The session modes, and the network settings of each platform's profile (mode:profile).
SESSION_MODES=(zombie starve guest background legacy premetadata nofile packs restart trackers network:tv network:ios network:mac)

session_harness() {
  local start=$EPOCHREALTIME f=$(fork_dir) build=$CACHE/harness-build
  if [[ -z $f || ! -f $f/Tools/BoundedStorageHarness/Package.swift ]]; then
    record "SessionHarness" SKIP 0 "no PopcornTorrent with Tools/BoundedStorageHarness"; return 0
  fi
  if ! swift build -c release --package-path $f/Tools/BoundedStorageHarness --scratch-path $build > $LOGS/harness-build.log 2>&1; then
    record "SessionHarness" FAIL $((EPOCHREALTIME - start)) "build failed: $LOGS/harness-build.log"; return 1
  fi
  local m
  for m in $SESSION_MODES; do
    ( w=$CACHE/work/session-$m; rm -rf $w
      sandbox-exec -f $SANDBOX $build/release/SessionHarness ${m%%:*} $w ${${m#*:}:#$m} > $LOGS/session-$m.log 2>&1
      print $? > $LOGS/session-$m.rc; rm -rf $w ) &
  done
  wait
  local -a failed=()
  local passes=0 fails=0
  for m in $SESSION_MODES; do
    [[ $(cat $LOGS/session-$m.rc) == 0 ]] || failed+=($m)
    passes=$(( passes + $(grep -c 'ASSERT PASS' $LOGS/session-$m.log) ))
    fails=$(( fails + $(grep -c 'ASSERT FAIL' $LOGS/session-$m.log) ))
  done
  record "SessionHarness (${#SESSION_MODES} runs)" $( (( ${#failed} == 0 )) && print PASS || print FAIL ) $((EPOCHREALTIME - start)) \
    "$passes passed, $fails failed${failed:+ (failed: $failed)}"
  (( ${#failed} == 0 ))
}

# MARK: - Full: P10 and B6, a real AVPlayer on a local clip

av_benches() {
  local start=$EPOCHREALTIME
  local r13=$REPO/format-coverage-wip/scratchpad/harness/P13/r13 media=$REPO/format-coverage-wip/media.nosync/harness/B1/media
  if [[ ! -f $r13/reg/p10unit/main.swift || ! -f $media/h264_20s.mp4 ]]; then
    record "P10 / B6 (AVPlayer)" SKIP 0 "no format-coverage-wip benches or clip on this Mac"; return 0
  fi
  local pb=$REPO/PopcornTime/Resources/Playback b
  local -a trio=($pb/AVPlayerItemFailureObserver.swift $pb/PlaybackRouting.swift $pb/PlaybackLanguagePreferences.swift)
  for b in p10unit b6unit; do
    ( src=($trio $r13/reg/$b/main.swift)
      bin=$CACHE/bin/$b-$(cat $src | shasum | cut -c1-16)   # compiled once per source version
      [[ -x $bin ]] || xcrun swiftc -O -target $ARCH-apple-macos14.0 $src -framework AVKit -o $bin > $LOGS/$b-build.log 2>&1
      $bin $media > $LOGS/$b.log 2>&1
      print $? > $LOGS/$b.rc ) &
  done
  wait
  local ok=1 detail=""
  for b in p10unit b6unit; do
    [[ $(cat $LOGS/$b.rc) == 0 ]] || ok=0
    detail+="${b%unit} $(grep -E '^RESULT|^FATAL' $LOGS/$b.log | tail -1 | sed 's/^RESULT //'); "
  done
  record "P10 / B6 (AVPlayer)" $( ((ok)) && print PASS || print FAIL ) $((EPOCHREALTIME - start)) "${detail%; }"
  ((ok))
}

# MARK: - Full: the format-coverage e2e engine and F3 (a restored bench folder)

format_benches() {
  local bench=${PT_FORMAT_BENCH:-}
  if [[ -z $bench || ! -x $bench/harness/e2e/run_all.sh ]]; then
    record "remux e2e + F3" SKIP 0 "set PT_FORMAT_BENCH to a folder restored by format-coverage-wip/restore.sh"; return 0
  fi
  local start=$EPOCHREALTIME rc=0
  $bench/harness/e2e/run_all.sh --jobs 3 > $LOGS/format-e2e.log 2>&1 || rc=1
  record "remux e2e" $( ((rc == 0)) && print PASS || print FAIL ) $((EPOCHREALTIME - start)) "$LOGS/format-e2e.log"
  local s2=$EPOCHREALTIME rc2=0
  # F3 alone: it serves on port 50710 and plays in real time.
  { $bench/harness/F3/build.sh && $bench/harness/F3/run.sh } > $LOGS/format-f3.log 2>&1 || rc2=1
  record "F3 bench" $( ((rc2 == 0)) && print PASS || print FAIL ) $((EPOCHREALTIME - s2)) "$LOGS/format-f3.log (x* cases: see its summary.json)"
  return $(( rc || rc2 ))
}

# MARK: - Full, opt-in: the bounded-storage disk-image runs (PopcornTorrent)

bounded_runs() {
  [[ ${PT_BOUNDED_RUNS:-0} == 1 ]] || { record "bounded disk images" SKIP 0 "PT_BOUNDED_RUNS=1 to run them"; return 0 }
  local start=$EPOCHREALTIME f=$(fork_dir) build=$CACHE/harness-build
  local run=$f/Tools/BoundedStorageHarness/run_harness.sh h=$build/release/BoundedStorageHarness
  swift build -c release --package-path $f/Tools/BoundedStorageHarness --scratch-path $build >> $LOGS/harness-build.log 2>&1 || {
    record "bounded disk images" FAIL $((EPOCHREALTIME - start)) "build failed"; return 1 }
  ( sandbox-exec -f $SANDBOX zsh $run $h bounded 3g $CACHE/work/hw-bounded $CACHE/work/hv-bounded \
      --size-mib 6144 --rate-mbs 40 --pause-seconds 60 --budget-mib 2048 > $LOGS/bounded.log 2>&1; print $? > $LOGS/bounded.rc ) &
  ( sandbox-exec -f $SANDBOX zsh $run $h full 8g $CACHE/work/hw-full $CACHE/work/hv-full \
      --size-mib 6144 > $LOGS/full.log 2>&1; print $? > $LOGS/full.rc ) &
  wait
  rm -rf $CACHE/work/hw-bounded $CACHE/work/hw-full
  local ok=$(( $(cat $LOGS/bounded.rc) == 0 && $(cat $LOGS/full.rc) == 0 ))
  record "bounded disk images" $( ((ok)) && print PASS || print FAIL ) $((EPOCHREALTIME - start)) \
    "bounded: $(grep -h RESULT $LOGS/bounded.log | tail -1 | sed 's/.*RESULT //'); full: $(grep -h RESULT $LOGS/full.log | tail -1 | sed 's/.*RESULT //')"
  ((ok))
}

# MARK: - Run

T0=$EPOCHREALTIME
print "PopcornTimeTV tests ($MODE) — logs in $LOGS"
app_tests & fork_tests &
wait
if [[ $MODE == full ]]; then
  session_harness & av_benches &
  wait
  bounded_runs
  format_benches
fi

print ""
failed=0
while IFS='|' read -r name result secs detail; do
  printf "%-32s %-4s %7.1f s  %s\n" $name $result $secs $detail
  [[ $result == FAIL ]] && failed=1
done < $RESULTS
printf "%-32s %-4s %7.1f s\n" "total ($MODE)" $( ((failed)) && print FAIL || print PASS ) $((EPOCHREALTIME - T0))
exit $failed
