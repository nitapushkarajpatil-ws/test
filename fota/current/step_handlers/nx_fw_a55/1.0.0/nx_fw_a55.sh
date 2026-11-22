#!/bin/sh
# Step handler "nx_fw_a55" (single script, all steps): the Linux rootfs of the i.MX93 (Cortex-A55),
# A/B slots, installed through nx-fw-update (meta-cargt-nexrev,
# recipes-cargt/nx-fw-update). Follows docs/HANDLERS.md.
#
# Manifest entry (the component name is free, the handler is fixed):
#     { "component": "a55_rootfs", "stepHandler": "nx_fw_a55",
#       "rebootRequired": true, "version": "<SW_VER_STRING of the image>",
#       ... }
# The artifact is the signed .swu of the image (cargt-image-dev-swu or
# the production equivalent). "version" must equal the version in the
# .swu's sw-description, which is what /etc/sw-versions shows once it
# runs: install refuses the image otherwise.
#
# Steps, on the U-Boot environment (nx_slot, upgrade_available, bootcount):
#   get_version  nx-fw-update get_version a55 (/etc/sw-versions)
#   install      nx-fw-update download a55 <file>; nx-fw-update install a55:
#                the inactive slot is written, the running slot stays
#                selected
#   abort        nx-fw-update commit fail: running slot stays selected
#   apply        nx-fw-update commit pass: U-Boot boots the new slot next
#                (upgrade_available=1, bootcount=0). Does not reboot.
#   commit       after the reboot, new slot running: bootcount=0,
#                upgrade_available=0 (what nx-boot-commit writes too)
#   rollback     select the slot that runs NEXREV_VERSION_FROM for the next
#                boot, with nothing pending; works after install, after
#                apply and after the reboot into the new slot. The updater
#                reboots if needed.
#
# Called by the updater as: handler.sh <step> <component> [args...]
#   handler.sh get_version <component>
#   handler.sh install     <component> <file> <sha256>
#   handler.sh abort       <component>
#   handler.sh apply       <component>
#   handler.sh commit      <component>
#   handler.sh rollback    <component>
# The NEXREV_* environment comes from the updater (docs/HANDLERS.md); set
# NEXREV_VERSION_FROM/TO and NEXREV_STATE_DIR yourself when running it by hand.

set -u
if [ $# -lt 2 ]; then
    echo "usage: $0 get_version|install|abort|apply|commit|rollback <component> [args...]" >&2
    exit 2
fi
step=$1
comp=$2
shift 2

TARGET=a55
NX_FW=${NX_FW:-nx-fw-update}
# Settings and helpers of nx-fw-update (NX_FW_DIR, NX_FW_LOCK, nx_env...).
if [ -r /etc/default/nx-fw-update ]; then
    . /etc/default/nx-fw-update
fi
: "${NX_FW_DIR:=/data/firmware}"
: "${NX_FW_LIBDIR:=/usr/lib/nx-fw-update}"
: "${NX_FW_LOCK:=/run/nx-fw-update.lock}"
: "${NX_FW_DOWNLOAD_DIR:=$NX_FW_DIR/download}"
if ! . "$NX_FW_LIBDIR/nx-fw-lib.sh"; then
    echo "nx_fw_a55: $NX_FW_LIBDIR/nx-fw-lib.sh missing: nx-fw-update not installed" >&2
    exit 1
fi
# How long to wait while another nx-fw-update holds its lock (e.g. its
# boot-time run waiting for nx-boot-commit), in seconds.
: "${NX_A55_BUSY_WAIT:=600}"

fail() {
    # Last line of stderr = the reason the updater records.
    echo "nx_fw_a55: $*" >&2
    exit 1
}

# nx_fw <args>: runs nx-fw-update, retrying while it reports "busy" (exit 5:
# another nx-fw-update runs, or nothing may start yet). Sets rc and out
# (stdout); stderr passes through.
nx_fw() {
    waited=0
    while :; do
        out=$("$NX_FW" "$@")
        rc=$?
        [ "$rc" -eq 5 ] || return 0
        if [ "$waited" -ge "$NX_A55_BUSY_WAIT" ]; then
            echo "nx_fw_a55: nx-fw-update $1 still busy after ${waited}s" >&2
            return 0
        fi
        [ "$waited" -eq 0 ] && echo "nx_fw_a55: nx-fw-update busy, waiting (at most ${NX_A55_BUSY_WAIT}s)"
        sleep 10
        waited=$((waited + 10))
    done
}

# Take nx-fw-update's lock for our own environment writes, so they never
# interleave with an nx-fw-update run. Never call nx-fw-update while
# holding it: it would see itself as busy.
lock() {
    exec 9>"$NX_FW_LOCK" || fail "cannot open $NX_FW_LOCK"
    flock -w "$NX_A55_BUSY_WAIT" 9 || fail "nx-fw-update lock $NX_FW_LOCK still held after ${NX_A55_BUSY_WAIT}s"
}
unlock() {
    exec 9>&-
}

booted_slot() {
    booted=$(nx_booted_slot)
    case "$booted" in
    a|b) ;;
    *) fail "running slot is '${booted:-unknown}', not a or b (safe image, or not booted by the A/B boot script)" ;;
    esac
}

# Forget nx-fw-update's record of this install (state + the downloaded
# image), so its boot-time run does not treat our rollback as a failed
# install of its own. Call with the lock held.
forget_nx_fw_install() {
    st=$NX_FW_DIR/.state/$TARGET
    [ -f "$st" ] || return 0
    f=$(nx_state_get "$st" file)
    case "$NX_FW_DIR/$f" in
    "$NX_FW_DOWNLOAD_DIR"/*)
        rm -f "$NX_FW_DIR/$f"
        rm -rf "$NX_FW_DOWNLOAD_DIR/.fetch-$TARGET"
        ;;
    esac
    rm -f "$st"
    echo "nx_fw_a55: cleared nx-fw-update's pending install record (${f:-?})"
}

# set_env name=value...: one environment write, checked afterwards.
set_env() {
    nx_env_set "$@" || fail "fw_setenv $* failed"
    for kv in "$@"; do
        [ "$(nx_env "${kv%%=*}")" = "${kv#*=}" ] ||
            fail "U-Boot environment not updated: ${kv%%=*}=$(nx_env "${kv%%=*}"), wanted ${kv#*=}"
    done
}

running_version() {
    "$NX_FW" get_version "$TARGET" 2>/dev/null
}

case $step in
get_version)
    # stdout: the version only. nx-fw-update exits 1 if it cannot be read.
    exec "$NX_FW" get_version "$TARGET"
    ;;

install)
    file=${1:?}
    sha=${2:?}
    [ -f "$file" ] || fail "image $file not found"
    # nx-fw-update keeps the source's extension and only stages a .swu.
    S=${NEXREV_STATE_DIR:?}
    mkdir -p "$S" || fail "cannot create $S"
    src=$S/incoming.swu
    rm -f "$src"
    ln "$file" "$src" 2>/dev/null || cp "$file" "$src" || fail "cannot copy $file to $src"

    echo "nx_fw_a55: handing ${file##*/} to nx-fw-update"
    nx_fw download "$TARGET" "$src"
    rm -f "$src"
    [ "$rc" -eq 0 ] || fail "nx-fw-update download $TARGET failed (exit $rc)"
    stored=$(printf '%s\n' "$out" | tail -n 1)
    [ -f "$stored" ] || fail "nx-fw-update download did not store the image (got '$stored')"

    # The copy nx-fw-update stages is the image the updater verified.
    got=$(sha256sum "$stored" | cut -d' ' -f1)
    [ "$got" = "$sha" ] || fail "sha256 of $stored is $got, expected $sha"

    # After the reboot get_version reads this version from /etc/sw-versions;
    # a different one would look like a bootloader fallback.
    v=${stored##*/}
    v=${v#"$TARGET"_}
    v=${v%.*}
    [ "$v" = "${NEXREV_VERSION_TO:?}" ] ||
        fail "image version (sw-description) is '$v' but the manifest says '$NEXREV_VERSION_TO'"

    nx_fw install "$TARGET"
    [ "$rc" -eq 0 ] || fail "nx-fw-update install $TARGET failed (exit $rc)"
    echo "nx_fw_a55: version $v staged in the inactive slot; running slot stays selected"
    ;;

abort)
    nx_fw commit fail
    case $rc in
    0) echo "nx_fw_a55: staged install aborted, running slot stays selected" ;;
    4) echo "nx_fw_a55: nothing staged" ;;
    *) fail "nx-fw-update commit fail failed (exit $rc)" ;;
    esac
    ;;

apply)
    booted_slot
    other=$(nx_other_slot "$booted")
    nx_fw commit pass
    case $rc in
    0)
        echo "nx_fw_a55: slot $other selected for the next boot ($out)"
        ;;
    4)
        # Run twice (power cut after the switch): already applied?
        if [ "$(nx_env nx_slot)" = "$other" ] && [ "$(nx_env upgrade_available)" = 1 ]; then
            echo "nx_fw_a55: slot $other already selected for the next boot"
        else
            fail "nothing staged to apply (nx_slot=$(nx_env nx_slot), upgrade_available=$(nx_env upgrade_available))"
        fi
        ;;
    *) fail "nx-fw-update commit pass failed (exit $rc); the running slot stays selected" ;;
    esac
    ;;

commit)
    booted_slot
    v=$(running_version) || fail "cannot read the running version"
    [ "$v" = "${NEXREV_VERSION_TO:?}" ] ||
        fail "running version is '$v' on slot $booted, not $NEXREV_VERSION_TO: nothing to commit"
    lock
    if [ "$(nx_env nx_slot)" != "$booted" ]; then
        fail "U-Boot selects slot '$(nx_env nx_slot)' for the next boot, not the running slot $booted; not committing"
    fi
    if [ "$(nx_env upgrade_available)" = 0 ] && [ "$(nx_env bootcount)" = 0 ]; then
        echo "nx_fw_a55: slot $booted ($v) already committed"
    else
        set_env bootcount=0 upgrade_available=0 nx_other_failed=0
        echo "nx_fw_a55: slot $booted ($v) committed"
    fi
    unlock
    ;;

rollback)
    # 1. Anything still staged in nx-fw-update: drop it (the running slot
    #    stays selected). Not under our lock: nx-fw-update takes it itself.
    nx_fw commit fail
    case $rc in
    0|4) ;;
    *) fail "nx-fw-update commit fail failed (exit $rc)" ;;
    esac

    # 2. Select the slot that runs NEXREV_VERSION_FROM, nothing pending.
    booted_slot
    v=$(running_version) || fail "cannot read the running version"
    if [ "$v" = "${NEXREV_VERSION_TO:?}" ] && [ "$NEXREV_VERSION_TO" != "${NEXREV_VERSION_FROM:-}" ]; then
        # Booted into the new slot: back to the other one (untouched since
        # the update started) for the next boot.
        target=$(nx_other_slot "$booted")
        why="running new version $v on slot $booted; slot $target ($NEXREV_VERSION_FROM) boots next"
    else
        # Still (or again, after a U-Boot fallback) on the old slot.
        target=$booted
        why="running $v on slot $booted; it stays selected"
    fi
    lock
    set_env "nx_slot=$target" upgrade_available=0 bootcount=0
    forget_nx_fw_install
    unlock
    sync
    echo "nx_fw_a55: rolled back: $why"
    ;;

*)
    echo "nx_fw_a55: unknown step $step" >&2
    exit 2
    ;;
esac
