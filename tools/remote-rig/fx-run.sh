#!/bin/zsh
# Loopback-rig launcher with a Siri Remote script (fx-rewind, 5.3.0): the DEBUG x86_64 tvOS app on a tvOS 26.5
# simulator, a private trackerless test torrent seeded on 127.0.0.1 only (seeder3.py under sandbox-exec
# localhost-only.sb), and optionally the remote presses of RemoteScriptUITests (XCUIRemote).
#   fx-run.sh <label> bighevc <seconds> <shot step> <progress 0..1> <image size|"full"> [app args]
# Env (required): FX_WORK, FX_RIG, FX_RIG_TOOLS, DEVICE, APP — see the messages below.
# Env (optional): SEED_RATE (MB/s, default 4), PORT (default 7691), SLOW_ON="<log text>" + SLOW_RATE=<MB/s> (the seed
#   slows down once the app logs that text), REMOTE="<script>" with XCTESTRUN=<the UI tests' .xctestrun> (built with
#   build-for-testing, ONLY_ACTIVE_ARCH=NO: the runner must hold arm64). With REMOTE the runner launches the app (its
#   script starts with "launch"); the app's stdout reaches the rig through the shim stdout-shim/ptstdout.dylib, built
#   from tools/remote-rig/ptstdout.c:
#     xcrun -sdk appletvsimulator clang -target x86_64-apple-tvos17.0-simulator -dynamiclib -o ptstdout.dylib ptstdout.c
# Leaves in $FX_RIG/e2e/: app-<label>.console.log (stamped), seeder-<label>.log (pieces asked / sent), run-<label>.out,
# remote-<label>.log (the runner: "PT_REMOTE <clock> <step>" lines), and screenshots in $FX_RIG/shots/<label>/.
# Example (the user's case, R1):
#   REMOTE='launch;waitlog:landed: playback ran;wait:8;playPause;wait:3;left*30/0.25;wait:1;select;wait:60' \
#     fx-run.sh R1 bighevc 150 10 0.7 full -PTDebugResumeAnswer resume -PTDebugResumeAnswerAfter 3
set -uo pipefail
W=${FX_WORK:?set FX_WORK to the work folder (its dd-fx/ holds the UI tests build)}
R=${FX_RIG_TOOLS:?set FX_RIG_TOOLS to the folder holding tools/localhost-only.sb}
N=${FX_RIG:?set FX_RIG to the rig folder (media/, tools/seeder3.py, tools/stamp.py, stdout-shim/ptstdout.dylib)}
L=$N/e2e
APP=${APP:?set APP to the x86_64 DEBUG PopcornTime.app}
BUNDLE_ID=com.popcorntime.tvos
DEVICE=${DEVICE:?set DEVICE to the UDID of your tvOS 26.5 simulator}
PORT=${PORT:-7691}
XCTESTRUN=${XCTESTRUN:-}
label=$1; film=$2; secs=$3; step=$4; progress=$5; size=$6; shift 6
case $film in
  bighevc) DUR=985 ;;
  *) echo "film: bighevc"; exit 2 ;;
esac
FILM=$N/media/film_$film.mkv; TOR=$N/media/film_$film.torrent
SH=$N/shots/$label
mkdir -p $L $SH
img=$N/vol-$label.sparseimage; mnt=$N/vol-$label
cleanup() {
  xcrun simctl terminate $DEVICE $BUNDLE_ID >/dev/null 2>&1
  [[ -n ${seeder:-} ]] && kill $seeder 2>/dev/null
  [[ -n ${ratewatch:-} ]] && kill $ratewatch 2>/dev/null; rm -f $N/rate-$label.txt
  # Our own subshells and their children only (tail, stamp, xcodebuild of this run).
  [[ -n ${LPID:-} ]] && { pkill -P $LPID 2>/dev/null; kill $LPID 2>/dev/null; }
  [[ -n ${XPID:-} ]] && { pkill -P $XPID 2>/dev/null; kill $XPID 2>/dev/null; }
  sleep 1
  if [[ $size != full ]]; then
    hdiutil detach -quiet $mnt 2>/dev/null || hdiutil detach -quiet -force $mnt 2>/dev/null
    rm -f $img; rmdir $mnt 2>/dev/null
  fi
}
trap cleanup EXIT; trap 'exit 1' INT TERM
dirargs=()
if [[ $size != full ]]; then
  rm -f $img; mkdir -p $mnt
  hdiutil create -quiet -size $size -fs APFS -type SPARSE -volname PTF$label $img || exit 3
  hdiutil attach -quiet -nobrowse -mountpoint $mnt $img || exit 3
  dirargs=(-PTDebugDownloadDir $mnt/dl)
  echo "$(date +%T) volume: $(df -m $mnt | tail -1)" | tee $L/run-$label.out
fi
echo "$(date +%T) label=$label film=$film progress=$progress size=$size seedRate=${SEED_RATE:-4} port=$PORT app=$APP extra: $*" >> $L/run-$label.out
echo "remote: ${REMOTE:-none}" >> $L/run-$label.out
echo "load: $(uptime | sed 's/.*load averages: //')" >> $L/run-$label.out
xcrun simctl boot $DEVICE >/dev/null 2>&1
xcrun simctl bootstatus $DEVICE -b >/dev/null
xcrun simctl terminate $DEVICE $BUNDLE_ID >/dev/null 2>&1
xcrun simctl uninstall $DEVICE $BUNDLE_ID >/dev/null 2>&1
xcrun simctl install $DEVICE $APP || exit 1
xcrun simctl spawn $DEVICE defaults write $BUNDLE_ID tosAccepted -bool YES
xcrun simctl spawn $DEVICE defaults write $BUNDLE_ID lastWhatsNewVersion -string 5.2.0
xcrun simctl spawn $DEVICE defaults write $BUNDLE_ID themeSongVolume -float 0
if [[ $progress != 0 ]]; then
  xcrun simctl spawn $DEVICE defaults write $BUNDLE_ID moviesProgress -dict tt0000000 -float $progress
else
  xcrun simctl spawn $DEVICE defaults delete $BUNDLE_ID moviesProgress >/dev/null 2>&1
fi
: > $L/app-$label.console.log
# SLOW_ON="<text>" SLOW_RATE=<MB/s>: the seed drops to that rate once the app's log says <text>.
ratefile=$N/rate-$label.txt; rm -f $ratefile
if [[ -n ${SLOW_ON:-} ]]; then
  ( until grep -q -- "$SLOW_ON" $L/app-$label.console.log 2>/dev/null; do sleep 0.2; done
    echo ${SLOW_RATE:-0.2} > $ratefile; echo "$(date +%T) seed rate -> ${SLOW_RATE:-0.2} MB/s" >> $L/run-$label.out ) &
  ratewatch=$!
fi
sandbox-exec -f $R/tools/localhost-only.sb /usr/bin/python3 -I $N/tools/seeder3.py $FILM $TOR $PORT ${SEED_RATE:-4} $ratefile > $L/seeder-$label.log 2>&1 &
seeder=$!
appargs=(-themeSongVolume 0 -PTDebugPlayTorrent $TOR -PTDebugLoopbackPort $PORT -PTDebugDuration $DUR \
  -PTDebugResumeTrace 1 -PTDebugPlayerStateEvery 1 -PTDebugHTTPTrace 1 $dirargs "$@")
if [[ -n ${REMOTE:-} ]]; then
  # The remote: the UI test runner launches the app itself (script step "launch") with these arguments; the app's
  # stdout reaches the rig through the shim (stdout-shim/ptstdout.dylib), stamped like simctl's console.
  [[ -f $XCTESTRUN ]] || { echo "XCTESTRUN missing: $XCTESTRUN"; exit 4; }
  RUN_XCTESTRUN=${XCTESTRUN:h}/fx-$label.xctestrun
  cp $XCTESTRUN $RUN_XCTESTRUN
  # The app under test is the rig's: UITargetAppPath and every PopcornTime.app of DependentProductPaths (xcodebuild
  # installs those too — the UI tests build's own app would otherwise replace the rig's).
  /usr/bin/python3 -I -c 'import plistlib,sys
p,app=sys.argv[1],sys.argv[2]; d=plistlib.load(open(p,"rb")); t=d["PopcornTimetvOSUITests"]
t["UITargetAppPath"]=app
t["DependentProductPaths"]=[app if x.endswith("/PopcornTime.app") else x for x in t.get("DependentProductPaths",[])]
env=t.get("UITargetAppEnvironmentVariables",{})
for k in ["DYLD_FRAMEWORK_PATH","DYLD_LIBRARY_PATH","__XPC_DYLD_FRAMEWORK_PATH","__XPC_DYLD_LIBRARY_PATH"]: env.pop(k,None)
plistlib.dump(d,open(p,"wb"))' $RUN_XCTESTRUN $APP
  # (The app's own frameworks only: the UI tests build's DYLD_FRAMEWORK_PATH would load ITS PopcornKit
  # in place of the rig app's — a crash at launch, "Symbol not found", once PopcornKit gained a symbol.)
  rm -rf "${N:?}/xcresult-${label:?}"
  raw=$N/e2e/raw-$label.txt; : > $raw
  ( tail -F -n +1 $raw 2>/dev/null | /usr/bin/python3 -I $N/tools/stamp.py > $L/app-$label.console.log ) &
  LPID=$!
  sep=$'\x1f'
  ( TEST_RUNNER_PT_REMOTE_SCRIPT="$REMOTE" TEST_RUNNER_PT_REMOTE_LOG=$L/app-$label.console.log TEST_RUNNER_PT_REMOTE_SHOTS=$SH \
    TEST_RUNNER_PT_REMOTE_LAUNCH_ARGS="${(pj:$sep:)appargs}" \
    TEST_RUNNER_PT_REMOTE_LAUNCH_ENV="DYLD_INSERT_LIBRARIES=$N/stdout-shim/ptstdout.dylib${sep}PT_STDOUT_FILE=$raw" \
    xcodebuild test-without-building -xctestrun $RUN_XCTESTRUN -destination "id=$DEVICE" \
      -derivedDataPath $W/dd-fx/uitests-run -resultBundlePath $N/xcresult-$label \
      -only-testing:PopcornTimetvOSUITests/RemoteScriptUITests/testPlaysTheRemoteScript 2>&1 \
      | /usr/bin/python3 -I $N/tools/stamp.py > $L/remote-$label.log ) &
  XPID=$!
else
  ( xcrun simctl launch --console-pty $DEVICE $BUNDLE_ID "${appargs[@]}" 2>&1 | /usr/bin/python3 -I $N/tools/stamp.py > $L/app-$label.console.log ) &
  LPID=$!
fi
t=0
while (( t < secs )); do
  sleep $step; t=$(( t + step ))
  xcrun simctl io $DEVICE screenshot --type=jpeg $SH/t$(printf %03d $t).jpg >/dev/null 2>&1
done
echo "$(date +%T) end after $secs s; load: $(uptime | sed 's/.*load averages: //')" >> $L/run-$label.out
echo done
