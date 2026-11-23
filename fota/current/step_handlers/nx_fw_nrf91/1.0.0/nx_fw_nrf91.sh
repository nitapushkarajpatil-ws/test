#!/bin/sh
# Step handler "nx_fw_nrf91" (single script, all steps): the application of the
# Serial Modem v2 firmware on the nRF9160 (LTE IoT 4 Click), updated over its AT
# UART with the DFU kit (nx-modem-dfu.sh, sm_dfu_host.py, sm_at.py). Follows
# the same layout as nx_fw_a55.
#
# Manifest entry (the component name is free, the handler is fixed):
#     { "component": "nrf91_app", "stepHandler": { "name": "nx_fw_nrf91", ... },
#       "rebootRequired": false, "version": "v2.0.2",
#       "firmware": { "url": ".../sm2-click-app-2.0.2.signed.bin", ... } }
# The artifact is the MCUboot-signed application image
# (sm2-click-app-<x.y.z>.signed.bin). "version" must be what AT#XSMVER reports
# once the image runs (first field, e.g. v2.0.2); get_version reads exactly that.
#
# Steps:
#   get_version  AT#XSMVER through "nx-modem-dfu.sh version". This stops the
#                cellular stack for a few seconds and restarts it; raise
#                "timeouts": { "get_version": 90 } in nexrev_update.json if
#                the default 30 s is too short on your board.
#   install      checks the downloaded file against the manifest sha256 and
#                keeps a copy in NEXREV_STATE_DIR. The modem is NOT touched,
#                so the download can still use cellular.
#   abort        drops the staged copy.
#   apply        "nx-modem-dfu.sh application <file>": streams the image over
#                AT#XDFU*, activates it, MCUboot swaps (~80 s) and the stack is
#                restarted. Then checks that AT#XSMVER reports the target.
#                Never reboots the i.MX93.
#   commit       checks AT#XSMVER == target, drops the staged copy.
#   rollback     drops the staged copy. MCUboot on the Click has downgrade
#                prevention: once the new image runs it can NOT be replaced by
#                an older one over DFU (the image transfers, MCUboot keeps the
#                newer version). So rollback after a completed apply fails
#                with a clear reason; before apply, or if the Click reverted by
#                itself, it succeeds.
#
# Called by the updater as: handler.sh <step> <component> [args...]
#   handler.sh get_version <component>
#   handler.sh install     <component> <file> <sha256>
#   handler.sh abort       <component>
#   handler.sh apply       <component>
#   handler.sh commit      <component>
#   handler.sh rollback    <component>
# NEXREV_VERSION_FROM/TO and NEXREV_STATE_DIR come from the updater; set them
# yourself when running it by hand.
#
# Needs on the device (not part of this handler): the DFU kit tools directory,
# found in $NX_NRF91_TOOLS or one of
#   /usr/lib/nx-nrf91-dfu/tools  /opt/nrf91-dfu-kit/tools
# and a Click already running Serial Modem v2 (first install over SWD).

set -u
if [ $# -lt 2 ]; then
    echo "usage: $0 get_version|install|abort|apply|commit|rollback <component> [args...]" >&2
    exit 2
fi
step=$1
comp=$2
shift 2

fail() {
    # Last line of stderr = the reason the updater records.
    echo "nx_fw_nrf91: $*" >&2
    exit 1
}

TOOLS=""
for d in "${NX_NRF91_TOOLS:-}" /usr/lib/nx-nrf91-dfu/tools /opt/nrf91-dfu-kit/tools; do
    if [ -n "$d" ] && [ -f "$d/nx-modem-dfu.sh" ]; then
        TOOLS=$d
        break
    fi
done
[ -n "$TOOLS" ] || fail "nx-modem-dfu.sh not found (set NX_NRF91_TOOLS or install the DFU kit)"
DFU=$TOOLS/nx-modem-dfu.sh

S=${NEXREV_STATE_DIR:-/var/lib/nexrev/handlers/nx_fw_nrf91}
STAGED=$S/staged.bin
META=$S/staged.sha256

# stdout: the application version only, e.g. v2.0.2.
read_version() {
    out=$(sh "$DFU" version 2>&1) || {
        printf '%s\n' "$out" | tail -n 5 >&2
        return 1
    }
    v=$(printf '%s\n' "$out" | sed -n 's/.*#XSMVER: *"\([^"]*\)".*/\1/p' | head -n 1)
    [ -n "$v" ] || {
        echo "nx_fw_nrf91: no #XSMVER in the reply" >&2
        return 1
    }
    printf '%s\n' "$v"
}

# The wrapper leaves the cellular stack stopped when a step fails; "version"
# starts it again.
restart_stack() {
    sh "$DFU" version >/dev/null 2>&1 || true
}

drop_staged() {
    rm -f "$STAGED" "$META"
}

case $step in
get_version)
    read_version || fail "cannot read AT#XSMVER from the Click"
    ;;

install)
    file=${1:?}
    sha=${2:?}
    [ -f "$file" ] || fail "image $file not found"
    got=$(sha256sum "$file" | cut -d' ' -f1)
    [ "$got" = "$sha" ] || fail "sha256 of $file is $got, expected $sha"
    # The signed image is named after its version (sm2-click-app-2.0.2.signed.bin).
    want=${NEXREV_VERSION_TO:?}
    case ${file##*/} in
    *"${want#v}"*) ;;
    *) fail "file name ${file##*/} does not contain the manifest version $want" ;;
    esac
    mkdir -p "$S" || fail "cannot create $S"
    drop_staged
    ln "$file" "$STAGED" 2>/dev/null || cp "$file" "$STAGED" || fail "cannot stage $file in $S"
    echo "$sha" >"$META"
    echo "nx_fw_nrf91: ${file##*/} staged ($want); the Click is not touched yet"
    ;;

abort)
    drop_staged
    echo "nx_fw_nrf91: staged image dropped"
    ;;

apply)
    want=${NEXREV_VERSION_TO:?}
    cur=$(read_version) || fail "cannot read the running version"
    if [ "$cur" = "$want" ]; then
        echo "nx_fw_nrf91: Click already runs $want, nothing to apply"
        exit 0
    fi
    [ -f "$STAGED" ] && [ -f "$META" ] || fail "no staged image (install did not run)"
    got=$(sha256sum "$STAGED" | cut -d' ' -f1)
    [ "$got" = "$(cat "$META")" ] || fail "staged image changed since install (sha256 $got)"

    echo "nx_fw_nrf91: updating the Click $cur -> $want over the AT UART (cellular is down meanwhile)"
    if ! sh "$DFU" application "$STAGED"; then
        restart_stack
        fail "nx-modem-dfu.sh application failed; the Click still runs the old image or is being reverted by MCUboot"
    fi
    now=$(read_version) || fail "update finished but AT#XSMVER cannot be read"
    [ "$now" = "$want" ] || fail "after the update the Click reports $now, not $want (MCUboot kept the old image: downgrade prevention, bad signature or version?)"
    echo "nx_fw_nrf91: Click now runs $now"
    ;;

commit)
    want=${NEXREV_VERSION_TO:?}
    cur=$(read_version) || fail "cannot read the running version"
    [ "$cur" = "$want" ] || fail "Click reports $cur, not $want: nothing to commit"
    drop_staged
    echo "nx_fw_nrf91: $cur committed"
    ;;

rollback)
    drop_staged
    cur=$(read_version) || fail "cannot read the running version"
    if [ "$cur" = "${NEXREV_VERSION_TO:?}" ] && [ "$cur" != "${NEXREV_VERSION_FROM:-}" ]; then
        fail "Click already runs $cur and MCUboot's downgrade prevention blocks going back to ${NEXREV_VERSION_FROM:-the old version} over DFU; reflash over SWD or ship a build with a higher version"
    fi
    echo "nx_fw_nrf91: Click runs $cur, nothing to roll back"
    ;;

*)
    echo "nx_fw_nrf91: unknown step $step" >&2
    exit 2
    ;;
esac
