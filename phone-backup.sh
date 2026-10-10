#!/usr/bin/env bash
# Phone Backerupper - back up an Android phone's photos & videos (USB, "File transfer"/MTP mode)
# to a plain folder (on this computer) and/or a Borg repo, and restore them again.
# Linux only (needs gvfs for MTP, FUSE, rsync, bash 4+). Run with no arguments for the menu.
#
#   Phone    -> Folder        incremental rsync into a folder on this computer
#   Phone    -> Borg          new archive in the Borg repo, read straight from the phone
#   Phone    -> Folder+Borg both of the above (Borg is still done if the folder copy fails,
#                             e.g. not enough free space - so the media always lands somewhere)
#   Folder   -> Borg          archive the folder copy
#   Folder   -> Phone         copy the folder copy back to the phone
#   Borg     -> Folder        pick an archive, restore it into the folder copy
#   Borg     -> Phone         pick an archive, restore it to the phone
#
# By default only images and videos are handled. --full (or the menu question) takes everything
# visible over MTP. Nothing is ever deleted, and restores never overwrite files that already exist.
#
# Usage: phone-backup.sh [--mode MODE] [--full] [--archive REF] [--yes] [options]
#   MODE: p2f p2b p2fb f2b f2p b2f b2p   (also: computer=p2f, borg=p2b, both=p2fb)
#   --full        everything on the phone, not just images & videos (own archive series "phone-full")
#   --archive REF archive for b2f/b2p without the picker (Borg 2: aid:<id prefix>; Borg 1: archive name)
#   --yes         don't ask for confirmation (timers/scripts)
#   --borg1       use Borg 1 (default)           --borg2   use Borg 2 (EXPERIMENTAL)
#   --compact     run `borg compact` after a Borg backup (slow; frees space from pruned archives)
#   --no-prune    keep every archive      --keep-last N   retention = just the newest N archives (use with --mode prune)
#   --history M   EXPERIMENTAL: after a Phone->Folder sync, keep a dated copy of the folder
#                 in "<folder>-history". M = reflink (btrfs/XFS: shares disk space, nearly free)
#                         or hardlink (any Linux filesystem: unchanged files share space).
#                 Without a mode, the folder is just the latest sync (the default).
#   --plain       no fancy menus (plain numbered prompts)
#   --dest DIR    folder for the plain copy        --repo PATH   Borg repo to use this run
#   --exclude PAT      skip files/folders matching PAT (repeatable); --exclude-file FILE; --show-excludes
#                      (patterns: see README. e.g. --exclude "*.tmp" --exclude "DCIM/Camera/old")
#   --workdir DIR scratch space (archive mount point, temp files; small - no full copies are staged)
#
# Extras (optional; the menu has a "More..." entry, or pass these as --mode for scripts/agents):
#   --mode prune | compact | check | unlock      repo maintenance (prune uses the retention in KEEP)
#   --mode apply-excludes --target folder|borg|both [--archive REF] [--compact] --yes
#                 apply the exclusions file to EXISTING backups: deletes matching files from the folder copy
#                 and/or rewrites Borg archives without them (permanent! all phone archives unless --archive)
#   --mode init --new-repo PATH [--encryption none|passphrase]   create a new Borg repo (--borg1/--borg2)
#   --mode transfer --to-repo PATH [--to-borg 1|2] [--delete-source]
#                 copy the phone archives into another repo (Borg 2 -> Borg 2 uses `borg transfer`,
#                 anything else extracts each archive temporarily and re-archives it)
#   --status           print key=value status lines and exit      --list-archives   print archives and exit
#   Exit codes: 0 ok, 1 finished with warnings/fallback, 2 failed, 64 bad usage.
#
# Settings live at the top of this file, and can be overridden in ~/.config/phone-backup.conf
# (a bash file; see the README).
set -uo pipefail
[ "$(uname -s)" = Linux ] || { echo "Phone Backerupper only works on Linux (it needs gvfs/MTP and FUSE)." >&2; exit 1; }

# ---- settings (override in ~/.config/phone-backup.conf) ----------------------------------------------
DEST="$HOME/Phone Media Backup"     # plain copy on this computer
RESERVE_GB=5                        # keep at least this much free on the computer after copying

BORG_MAJOR=1                        # 1 = stable Borg 1.x (default); 2 = EXPERIMENTAL Borg 2 (--borg2)
BORG1_BIN=borg                      # path to the Borg 1 binary
BORG1_REPO=""                       # Borg 1 repo (path or ssh://...)
BORG2_BIN=borg                      # path to the Borg 2 binary
BORG2_REPO=""                       # Borg 2 repo
NOTIFY=1                            # desktop notification when a run finishes or fails (needs notify-send)
BORG_UNENCRYPTED=0                  # 1 = the repo has no passphrase: no passphrase prompts/warnings
MIN_FREE_GB=20                      # refuse a Borg backup below this much free space on a local repo drive
MIN_UNALLOC_GB=10                   # btrfs repo drive: refuse if unallocated space is this low
KEEP=(--keep-daily 7 --keep-weekly 8 --keep-monthly 24 --keep-yearly 10)   # archive pruning

EXCLUDE_FILE=""                     # exclusions file (default ~/.config/phone-backup.exclude), see README
WORK_DIR=""                         # scratch space (archive mount point, temp files); default ~/.local/state/phone-backup
CACHE_DIR=""                        # Borg cache location (BORG_CACHE_DIR); default: Borg's own (~/.cache/borg)

HISTORY=""                          # "", reflink or hardlink (EXPERIMENTAL, see --history)
HISTORY_DIR=""                      # default: "$DEST-history"
HISTORY_KEEP=0                      # keep only the newest N history copies (0 = keep all)

# Image/video extensions (matched case-insensitively), from any folder on the phone
EXTS=(jpg jpeg png gif webp heic heif avif bmp tif tiff dng raw arw cr2 nef orf rw2
      mp4 mov m4v mkv avi 3gp 3gpp webm mpg mpeg ts wmv)
# ---------------------------------------------------------------------------------------------------
CONF="${PHONE_BACKUP_CONF:-${XDG_CONFIG_HOME:-$HOME/.config}/phone-backup.conf}"
# shellcheck disable=SC1090
[ -r "$CONF" ] && . "$CONF"

EXCLUDE_CLI=(); SHOWEX=0; TARGET=""
NEW_REPO=""; ENC=none; TO_REPO=""; TO_MAJOR=""; DELETE_SRC=0; CLI_REPO=""; STATUS=0; LISTARCH=0
MODE=""; ARCHREF=""; YES=0; COMPACT=0; PRUNE=1; PLAIN=0; FULL=0; FULL_SET=0
while [ $# -gt 0 ]; do
  case "$1" in
    --mode) MODE="${2:-}"; shift ;;
    --mode=*) MODE="${1#*=}" ;;
    --full) FULL=1; FULL_SET=1 ;;
    --archive) ARCHREF="${2:-}"; shift ;;
    --archive=*) ARCHREF="${1#*=}" ;;
    --yes|-y) YES=1 ;;
    --borg1) BORG_MAJOR=1 ;;
    --borg2) BORG_MAJOR=2 ;;
    --compact) COMPACT=1 ;;
    --no-prune) PRUNE=0 ;;
    --keep-last) KEEP=(--keep-last "${2:-1}"); shift ;;
    --history) HISTORY="${2:-}"; shift ;;
    --history=*) HISTORY="${1#*=}" ;;
    --plain) PLAIN=1 ;;
    --dest) DEST="${2:-}"; shift ;;
    --workdir) WORK_DIR="${2:-}"; shift ;;
    --exclude) EXCLUDE_CLI+=("${2:-}"); shift ;;
    --exclude-file) EXCLUDE_FILE="${2:-}"; shift ;;
    --show-excludes) SHOWEX=1 ;;
    --target) TARGET="${2:-}"; shift ;;
    --repo) CLI_REPO="${2:-}"; shift ;;
    --new-repo) NEW_REPO="${2:-}"; shift ;;
    --encryption) ENC="${2:-}"; shift ;;
    --to-repo) TO_REPO="${2:-}"; shift ;;
    --to-borg) TO_MAJOR="${2:-}"; shift ;;
    --delete-source) DELETE_SRC=1 ;;
    --status) STATUS=1 ;;
    --list-archives) LISTARCH=1 ;;
    -h|--help) sed -n '2,/^set -uo/p' "$0" | sed '$d'; exit 0 ;;
    *) echo "unknown option: $1 (try --help)" >&2; exit 64 ;;
  esac
  shift
done
case "$MODE" in computer|p2c) MODE=p2f ;; borg) MODE=p2b ;; both|p2cb) MODE=p2fb ;; c2b) MODE=f2b ;; c2p) MODE=f2p ;; b2c) MODE=b2f ;; esac
case "$HISTORY" in ""|reflink|hardlink) ;; *) echo "--history must be reflink or hardlink" >&2; exit 64 ;; esac
[ -n "$HISTORY_DIR" ] || HISTORY_DIR="$DEST-history"

GVFS="/run/user/$(id -u)/gvfs"
STATE="$HOME/.local/state/phone-backup"
[ -n "$EXCLUDE_FILE" ] || EXCLUDE_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/phone-backup.exclude"
WORK_DIR="${WORK_DIR:-$STATE}"
MNT_DIR="$WORK_DIR/archive-mount"
mkdir -p "$STATE" "$WORK_DIR/tmp" || exit 1
export TMPDIR="$WORK_DIR/tmp"
[ -z "$CACHE_DIR" ] || export BORG_CACHE_DIR="$CACHE_DIR"
LOG="$STATE/backup-$(date +%Y-%m-%d_%H-%M).log"

set_repo() {   # set_repo MAJOR PATH
  BORG_MAJOR=$1; REPO=$2
  if [ "$BORG_MAJOR" = 1 ]; then BORG=$BORG1_BIN; else BORG=$BORG2_BIN; fi
  export BORG_REPO="$REPO"
  LOCAL_REPO=""; case "$REPO" in ""|*://*|*:*) ;; *) LOCAL_REPO=$REPO ;; esac   # empty for ssh repos
  BORG_NAME="Borg $BORG_MAJOR"; [ "$BORG_MAJOR" = 2 ] && BORG_NAME="Borg 2 (experimental)"
}
if [ "$BORG_MAJOR" = 1 ]; then set_repo 1 "${CLI_REPO:-$BORG1_REPO}"; else set_repo 2 "${CLI_REPO:-$BORG2_REPO}"; fi
if [ "$BORG_UNENCRYPTED" = 1 ]; then
  export BORG_PASSPHRASE="" BORG_UNKNOWN_UNENCRYPTED_REPO_ACCESS_IS_OK=yes BORG_RELOCATED_REPO_ACCESS_IS_OK=yes
fi

log() { printf '%s %s\n' "$(date '+%F %T')" "$*"; }
notify() { [ "$NOTIFY" = 1 ] && command -v notify-send >/dev/null && notify-send -a "Phone backup" "$1" "${2:-}" || true; }
fail() { log "FAILED: $*"; notify "Phone backup failed" "$*"; exit 2; }
# Borg exit codes: 0 ok; 1 and (borg 2) 100-127 = warning; anything else = error.
is_warn() { [ "$1" -eq 1 ] || { [ "$1" -ge 100 ] && [ "$1" -le 127 ]; }; }

cleanup() {
  if mountpoint -q "$MNT_DIR" 2>/dev/null; then cd "$HOME" 2>/dev/null; fusermount3 -u "$MNT_DIR" 2>/dev/null || fusermount3 -uz "$MNT_DIR" 2>/dev/null; fi
}
trap cleanup EXIT

# ---- little TUI layer (gum if available, else plain prompts) ----------------------------------------
HAVE_GUM=0
if [ "$PLAIN" = 0 ] && [ -t 0 ] && [ -t 1 ] && command -v gum >/dev/null; then HAVE_GUM=1; fi
INTERACTIVE=0; [ -t 0 ] && [ -t 1 ] && INTERACTIVE=1

# choose "prompt" item...   -> prints the chosen item; returns 1 if cancelled
choose() {
  local prompt=$1; shift
  if [ $HAVE_GUM = 1 ]; then
    gum choose --header "$prompt" --height 15 --cursor "▶ " "$@"
  else
    local i=1 c
    echo "$prompt" >&2
    for it in "$@"; do printf '  %d) %s\n' $i "$it" >&2; i=$((i+1)); done
    while :; do
      read -rp "Choose 1-$#: " c || return 1
      [[ "$c" =~ ^[0-9]+$ ]] && [ "$c" -ge 1 ] && [ "$c" -le $# ] || continue
      eval "printf '%s\n' \"\${$c}\""; return 0
    done
  fi
}
confirm() {
  if [ $HAVE_GUM = 1 ]; then gum confirm --default=no "$1"
  else local a; read -rp "$1 [y/N] " a; [[ "$a" =~ ^[Yy] ]]; fi
}
banner() {
  local phone repo
  if ls -d "$GVFS"/mtp:* >/dev/null 2>&1; then phone="connected (MTP)"; else phone="not mounted (will try to mount)"; fi
  if [ -z "$REPO" ]; then repo="no repo set (see README)"
  elif [ -z "$LOCAL_REPO" ]; then repo="$REPO"
  elif [ -e "$REPO/config" ]; then repo="$REPO ($(df -BG --output=avail "$REPO" | tail -1 | tr -dc 0-9)G free)"
  else repo="NOT AVAILABLE ($REPO)"; fi
  if [ $HAVE_GUM = 1 ]; then
    gum style --border rounded --border-foreground 39 --padding "0 2" --margin "1 0" \
      "Phone Backerupper" "" "Phone:    $phone" "Folder:   $DEST" "$BORG_NAME: $repo"
  else
    printf '\n== Phone Backerupper ==\nPhone:    %s\nFolder:   %s\n%s: %s\n\n' "$phone" "$DEST" "$BORG_NAME" "$repo"
  fi
}

MENU_P2F="Phone → Folder      (rsync to the folder copy)"
MENU_P2B="Phone → Borg          (new archive, straight from the phone)"
MENU_P2FB="Phone → Folder + Borg"
MENU_F2B="Folder → Borg       (archive the folder copy)"
MENU_F2P="Folder → Phone      (copy back to the phone)"
MENU_B2F="Borg archive → Folder   (pick an archive)"
MENU_B2P="Borg archive → Phone      (pick an archive)"
MENU_X="More...  (repos, transfer between repos, maintenance)"
MENU_Q="Quit"

# ---- Borg helpers ---------------------------------------------------------------------------------------
borg_check_repo() {
  [ "$(id -u)" -ne 0 ] || fail "run as your normal user, not root"
  command -v "$BORG" >/dev/null || fail "borg not found ($BORG) - set BORG${BORG_MAJOR}_BIN in $CONF"
  [ -n "$REPO" ] || fail "no Borg repo set - set BORG${BORG_MAJOR}_REPO in $CONF"
  if [ -n "$LOCAL_REPO" ]; then
    [ -e "$REPO/config" ] || fail "no Borg repo at $REPO (is the drive mounted?)"
  fi
  local v; v=$("$BORG" --version 2>&1)
  case "$v" in *" $BORG_MAJOR."*) ;; *) fail "$BORG is '$v', expected borg $BORG_MAJOR" ;; esac
}

# prints "ref|description" lines, newest last
list_archives() {
  if [ "$BORG_MAJOR" = 1 ]; then
    "$BORG" list --glob-archives 'phone-*' --format '{archive}|{time}  {archive}|{archive}{NL}'
  else
    "$BORG" repo-list -a 'sh:phone-*' --sort-by timestamp --format 'aid:{id:.16}|{time}  {archive}  [{id:.8}]|{archive}{NL}'
  fi
}

pick_archive() {
  local lines items=() ref desc declare_map line
  declare -gA ARCH_MAP=()
  lines=$(list_archives 2>&1) || fail "could not list archives: $lines"
  [ -n "$lines" ] || fail "no phone-media / phone-full archives in $REPO yet"
  while IFS='|' read -r ref desc _; do ARCH_MAP["$desc"]=$ref; items=("$desc" "${items[@]}"); done <<< "$lines"
  local picked; picked=$(choose "Pick an archive (newest first)" "${items[@]}") || exit 0
  ARCHREF=${ARCH_MAP[$picked]}
}

# Mounts the chosen archive read-only at $MNT_DIR and sets ARCHROOT to the folder that holds "Internal storage" etc.
mount_archive() {
  mkdir -p "$MNT_DIR"
  mountpoint -q "$MNT_DIR" && fusermount3 -u "$MNT_DIR" 2>/dev/null
  log "mounting archive $ARCHREF ..."
  if [ "$BORG_MAJOR" = 1 ]; then "$BORG" mount "$REPO::$ARCHREF" "$MNT_DIR" || return 1
  else "$BORG" mount -a "$ARCHREF" "$MNT_DIR" || return 1; fi
  local i; for i in $(seq 1 30); do [ -n "$(ls -A "$MNT_DIR" 2>/dev/null)" ] && break; sleep 1; done
  # Borg 1 mounts the archive directly; Borg 2 shows a folder per archive. Find the folder with the media.
  ARCHROOT=$MNT_DIR
  if [ ! -d "$ARCHROOT/Internal storage" ]; then
    local d
    for d in "$MNT_DIR"/*/ "$MNT_DIR"/*/*/; do [ -d "${d}Internal storage" ] && { ARCHROOT=${d%/}; break; }; done
  fi
  ls -d "$ARCHROOT"/*/ >/dev/null 2>&1 || { log "archive appears empty ($ARCHROOT)"; return 1; }
}

# ---- phone helpers ---------------------------------------------------------------------------------------
find_mounts() { ls -d "$GVFS"/mtp:* 2>/dev/null; }
need_phone() {
  mounts=$(find_mounts)
  if [ -z "$mounts" ]; then
    local uri
    for uri in $(gio mount -li 2>/dev/null | grep -oE 'activation_root=mtp://[^ ]+' | cut -d= -f2 | sort -u); do
      log "mounting $uri"; gio mount "$uri" 2>&1 | grep -v '^$'
    done
    sleep 2; mounts=$(find_mounts)
  fi
  [ -n "$mounts" ] || fail "no phone found. Plug it in, unlock it and choose 'File transfer' in the USB notification."
}
dev_name() { local n; n=$(basename "$1"); echo "${n#*host=}"; }
# free bytes on the phone (empty if unknown)
phone_free() { gio info -a filesystem::free "mtp://$(dev_name "$1")/" 2>/dev/null | awk '/filesystem::free/ {print $2}'; }

# ---- include/exclude rules (media only by default, everything with --full) ---------------------------
RSYNC_FILTER=()
PAT="$STATE/patterns.txt"
# Exclusions file: one pattern per line; "#" comments. Sections: [all] (default), [folder], [borg].
#   name or glob without "/"  -> matches at any depth        (*.tmp   Screenshots   .thumbnails)
#   contains "/"              -> path from the storage root  (DCIM/Camera/old   Android/media/com.whatsapp)
#   trailing "/"              -> folders only (rsync only; Borg just ignores the slash)
EX_FOLDER=(); EX_BORG=()
ex_add() {   # ex_add SECTION PATTERN
  local sect=$1 pat=$2 dironly=0 anchored=0 r b
  case "$pat" in */) dironly=1; pat=${pat%/} ;; esac
  case "$pat" in /*) pat=${pat#/}; anchored=1 ;; esac
  case "$pat" in */*) anchored=1 ;; esac
  [ -n "$pat" ] || return 0
  if [ $anchored = 1 ]; then r="/$pat"; b="! sh:*/$pat"; else r="$pat"; b="! sh:**/$pat"; fi
  [ $dironly = 1 ] && r="$r/"
  case "$sect" in
    all) EX_FOLDER+=("--exclude=$r"); EX_BORG+=("$b") ;;
    folder) EX_FOLDER+=("--exclude=$r") ;;
    borg) EX_BORG+=("$b") ;;
  esac
}
load_excludes() {
  EX_FOLDER=(); EX_BORG=()
  local line sect=all x
  for x in "${EXCLUDE_CLI[@]}"; do ex_add all "$x"; done
  [ -r "$EXCLUDE_FILE" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    line="${line#"${line%%[![:space:]]*}"}"; line="${line%"${line##*[![:space:]]}"}"
    case "$line" in
      ''|'#'*) ;;
      '[all]') sect=all ;;  '[folder]') sect=folder ;;  '[borg]') sect=borg ;;
      '['*) echo "warning: unknown section $line in $EXCLUDE_FILE (use [all], [folder] or [borg])" >&2 ;;
      *) ex_add "$sect" "$line" ;;
    esac
  done < "$EXCLUDE_FILE"
}

build_filters() {
  local e extre x
  load_excludes
  if [ $FULL = 1 ]; then
    SERIES=phone-full
    RSYNC_FILTER=("${EX_FOLDER[@]}")
    : > "$PAT"                                   # only your exclusions: everything else is taken
    [ ${#EX_BORG[@]} -eq 0 ] || printf '%s\n' "${EX_BORG[@]}" >> "$PAT"
    return
  fi
  SERIES=phone-media
  extre=$(IFS='|'; echo "${EXTS[*]}")
  RSYNC_FILTER=(--prune-empty-dirs "${EX_FOLDER[@]}"
    --exclude='/Android/data/' --exclude='/Android/obb/'
    --exclude='.thumbnails/' --exclude='.trash*/' --exclude='.Trash*/'
    --exclude='.trashed-*' --exclude='.pending-*' --include='*/')
  for e in "${EXTS[@]}"; do RSYNC_FILTER+=(--include="*.$e" --include="*.${e^^}"); done
  RSYNC_FILTER+=(--exclude='*')
  {
    [ ${#EX_BORG[@]} -eq 0 ] || printf '%s\n' "${EX_BORG[@]}"
    cat <<EOF
! sh:**/Android/data
! sh:**/Android/obb
! sh:**/.thumbnails
! sh:**/.[Tt]rash*
! sh:**/.trashed-*
! sh:**/.pending-*
+ re:(?i)\.($extre)\$
- re:.
EOF
  } > "$PAT"
}

x_edit_excludes() {
  if [ ! -e "$EXCLUDE_FILE" ]; then
    mkdir -p "$(dirname "$EXCLUDE_FILE")"
    cat > "$EXCLUDE_FILE" <<'EOF'
# Phone Backerupper exclusions. One pattern per line.
#   name or glob without "/"  matches at any depth:   *.tmp     Screenshots
#   a pattern with "/" is a path from the storage root: DCIM/Camera/old    Android/media/com.whatsapp
#   a trailing "/" means folders only (rsync; Borg ignores the slash)
# Patterns here apply to BOTH the folder copy and Borg. For one only, use a section:
#   [folder]   only the rsync folder copy        [borg]   only Borg        [all]   both (the default)
#
# Examples:
# *.tmp
# Screenshots/
# Android/media/com.whatsapp/WhatsApp/Media/WhatsApp Video
EOF
  fi
  "${EDITOR:-nano}" "$EXCLUDE_FILE"
}

# ---- generic "copy a tree" with a space check ------------------------------------------------------------
# sync_tree SRC_ROOT DST_ROOT TARGET(computer|phone) FILTER(1|0)
# Copies each storage folder ("Internal storage", ...) under SRC_ROOT to the same name under DST_ROOT.
# Never overwrites an existing file at the target when TARGET=phone or the source is a restore.
sync_tree() {
  local src=$1 dst=$2 target=$3 filt=$4 s out need=0 avail opts=() f=() n r rc=0 stores=()
  if [ "$target" = phone ]; then
    # MTP: no permissions/times, rename not supported -> write in place, never overwrite what's there
    opts=(-r --no-perms --no-owner --no-group --inplace --omit-dir-times --ignore-existing)
  elif [ "$filt" = 1 ]; then
    # phone -> computer: MTP timestamps are unreliable, compare by size+name
    opts=(-rt --no-perms --no-owner --no-group --size-only --partial)
  else
    opts=(-rt --no-perms --no-owner --no-group --ignore-existing --partial)
  fi
  [ "$filt" = 1 ] && f=("${RSYNC_FILTER[@]}")

  for s in "$src"/*/; do
    [ -d "$s" ] || continue; s=$(basename "$s"); stores+=("$s")
  done
  [ ${#stores[@]} -gt 0 ] || { log "nothing to copy from $src"; return 1; }

  log "checking how much new data there is to copy ..."
  for s in "${stores[@]}"; do
    out="$dst/$s"; [ "$target" = computer ] && mkdir -p "$out"
    [ -d "$out" ] || out=$(ls -d "$dst"/*/ 2>/dev/null | head -1)   # phone has a differently named storage
    [ -n "$out" ] || { log "no matching storage on the target for '$s'"; return 1; }
    n=$(rsync "${opts[@]}" --dry-run --stats "${f[@]}" "$src/$s/" "$out/" 2>&1 \
        | awk -F': ' '/^Total transferred file size/ {gsub(/[^0-9]/,"",$2); print $2}')
    need=$((need + ${n:-0}))
  done
  if [ "$target" = computer ]; then avail=$(df -B1 --output=avail "$dst" | tail -1 | tr -dc 0-9)
  else avail=$(phone_free "$dst"); [ -n "$avail" ] || avail=-1; fi
  if [ "$avail" = -1 ]; then log "new data: $(numfmt --to=iec "$need") (free space on the phone is unknown)"
  else
    log "new data: $(numfmt --to=iec "$need"), free on $target: $(numfmt --to=iec "$avail")"
    if [ "$need" -gt $((avail - RESERVE_GB * 1073741824)) ]; then
      log "NOT ENOUGH SPACE on the $target for this copy."; return 3
    fi
  fi
  [ "$need" -gt 0 ] || { log "already up to date"; return 0; }

  for s in "${stores[@]}"; do
    out="$dst/$s"; [ -d "$out" ] || out=$(ls -d "$dst"/*/ 2>/dev/null | head -1)
    out=${out%/}
    log "copy $s -> $out"
    local errf="$WORK_DIR/tmp/rsync-err.$$"
    rsync "${opts[@]}" --info=progress2,stats1 --human-readable "${f[@]}" "$src/$s/" "$out/" 2> "$errf"
    r=$?
    # MTP can't chmod: rsync reports that for every new file even with --no-perms. Not a real failure.
    grep -v 'failed to set permissions' "$errf" | grep -v '^rsync error: some files/attrs' >&2
    if [ $r -eq 23 ] && ! grep '^rsync: ' "$errf" | grep -qv 'failed to set permissions'; then r=0; fi
    rm -f "$errf"
    # 24 = a file vanished while copying (harmless)
    if [ $r -ne 0 ] && [ $r -ne 24 ]; then
      log "rsync exit code $r"; [ $r -eq 11 ] && log "ran out of space."; rc=1
    fi
  done
  return $rc
}

# Folder on the computer for the connected (or only known) device
device_dir() {
  local name d dirs=()
  if [ -n "${mounts:-}" ]; then name=$(dev_name "$(echo "$mounts" | head -1)"); echo "$DEST/$name"; return; fi
  for d in "$DEST"/*/; do [ -d "$d" ] && dirs+=("$(basename "$d")"); done
  case ${#dirs[@]} in
    0) echo "$DEST/restored-phone" ;;
    1) echo "$DEST/${dirs[0]}" ;;
    *) echo "$DEST/$(choose 'Which device folder?' "${dirs[@]}")" ;;
  esac
}

# EXPERIMENTAL: dated copy of the folder after a sync. reflink = copy-on-write (btrfs/XFS),
# shares disk space until files change; hardlink = unchanged files share space on any Linux filesystem.
# Neither is a substitute for Borg (no compression/dedup of changed files), and the folder
# itself stays "latest sync only".
make_history() {
  [ -n "$HISTORY" ] || return 0
  local snap="$HISTORY_DIR/$(date +%Y-%m-%d_%H-%M)" cpopt old n
  case "$HISTORY" in reflink) cpopt=(-a --reflink=always) ;; *) cpopt=(-al) ;; esac
  mkdir -p "$HISTORY_DIR"
  if cp "${cpopt[@]}" "$DEST" "$snap" 2>/dev/null; then log "history copy ($HISTORY): $snap"
  else
    # only ever remove the dated folder we just tried to create
    case "$snap" in "$HISTORY_DIR"/????-??-??_??-??) [ -d "$snap" ] && [ ! -L "$snap" ] && rm -rf -- "${snap:?}" ;; esac
    log "history copy failed - does this filesystem support '$HISTORY'? (reflink: btrfs/XFS only; hardlink: same filesystem only)"
    return 1
  fi
  if [ "$HISTORY_KEEP" -gt 0 ]; then
    n=0
    for old in $(ls -1d "$HISTORY_DIR"/????-??-??_??-?? 2>/dev/null | sort -r); do
      n=$((n+1)); if [ $n -gt "$HISTORY_KEEP" ]; then
        case "$old" in "$HISTORY_DIR"/????-??-??_??-??) [ -d "$old" ] && [ ! -L "$old" ] \
          && { log "removing old history copy $old"; rm -rf -- "${old:?}"; } ;; esac
      fi
    done
  fi
}

# ---- operations ----------------------------------------------------------------------------------------------
op_phone_to_computer() {
  local mnt rc=0
  while IFS= read -r mnt; do
    log "device: $(dev_name "$mnt")"
    sync_tree "$mnt" "$DEST/$(dev_name "$mnt")" computer 1 || rc=$?
  done <<< "$mounts"
  if [ $rc -eq 0 ]; then log "phone -> computer finished: $DEST"; make_history || true; fi
  return $rc
}

# Create a Borg archive from SOURCE=phone|computer. Returns 0 ok, 1 warnings, 2 failed.
op_borg_create() {
  local source=$1 dirs=() d storage src=() rc=0 r name
  borg_check_repo_soft || return 2
  if [ "$source" = phone ]; then while IFS= read -r d; do dirs+=("$d"); done <<< "$mounts"
  else for d in "$DEST"/*/; do [ -d "$d" ] && dirs+=("${d%/}"); done; fi
  [ ${#dirs[@]} -gt 0 ] || { log "nothing to back up"; return 2; }

  # Run from inside the device folder so archive paths are "Internal storage/DCIM/..." for both sources.
  # --files-cache mtime,size: FUSE inodes aren't stable, so don't use them (else every run re-reads everything)
  local args=(--stats --show-rc --compression auto,zstd,3 --files-cache mtime,size
              --noctime --noflags --noacls --noxattrs --patterns-from "$PAT")
  for d in "${dirs[@]}"; do
    cd "$d" || continue
    src=(); for storage in */; do src+=("${storage%/}"); done
    [ ${#src[@]} -gt 0 ] || continue
    log "borg $BORG_MAJOR: archiving the $([ "$source" = computer ] && echo folder || echo phone) copy of $(basename "$d")"
    if [ "$BORG_MAJOR" = 1 ]; then
      "$BORG" create "${args[@]}" "::$SERIES-$(date +%Y-%m-%d_%H-%M)" "${src[@]}"
    else
      "$BORG" create "${args[@]}" --tags phone --comment "phone-backup.sh ($source)" "$SERIES" "${src[@]}"
    fi
    r=$?
    if [ $r -ne 0 ]; then if is_warn $r; then [ $rc -eq 0 ] && rc=1; else rc=2; fi; fi
  done
  cd "$HOME" || true
  [ $rc -ne 2 ] || { log "borg create failed"; return 2; }

  if [ $PRUNE = 1 ]; then
    log "prune old phone archives"
    if [ "$BORG_MAJOR" = 1 ]; then "$BORG" prune --glob-archives "$SERIES-*" "${KEEP[@]}" --show-rc
    else "$BORG" prune -a "$SERIES" "${KEEP[@]}" --show-rc; fi
    r=$?; if [ $r -ne 0 ] && ! is_warn $r; then rc=2; fi
  fi
  if [ $COMPACT = 1 ]; then
    log "compact"; "$BORG" compact --show-rc
    r=$?; if [ $r -ne 0 ] && ! is_warn $r; then rc=2; fi
  fi
  return $rc
}
# like borg_check_repo plus the free-space checks, but returns instead of exiting
borg_check_repo_soft() {
  ( borg_check_repo ) || return 1
  [ -n "$LOCAL_REPO" ] || return 0
  local free_gb unalloc_gb
  free_gb=$(df -BG --output=avail "$REPO" | tail -1 | tr -dc 0-9)
  [ "$free_gb" -ge "$MIN_FREE_GB" ] || { log "only ${free_gb}G free on the repo drive"; return 1; }
  unalloc_gb=$(btrfs filesystem usage -b "$REPO" 2>/dev/null | awk '/Device unallocated/ {printf "%d", $3/1073741824}')
  if [ -n "$unalloc_gb" ] && [ "$unalloc_gb" -lt "$MIN_UNALLOC_GB" ]; then
    log "the repo drive (btrfs) has only ${unalloc_gb}G unallocated; try: sudo btrfs balance start -dusage=30 $(dirname "$REPO")"
    return 1
  fi
}

op_computer_to_phone() {
  local mnt name srcdir rc=0
  while IFS= read -r mnt; do
    name=$(dev_name "$mnt"); srcdir="$DEST/$name"
    if [ ! -d "$srcdir" ]; then
      local others=(); for d in "$DEST"/*/; do [ -d "$d" ] && others+=("$(basename "$d")"); done
      [ ${#others[@]} -gt 0 ] || { log "no folder copy to send"; return 1; }
      log "no folder copy for device '$name'"
      srcdir="$DEST/$(choose "Which folder copy should go to this phone?" "${others[@]}")"
    fi
    sync_tree "$srcdir" "$mnt" phone 0 || rc=$?
  done <<< "$mounts"
  return $rc
}

# op_restore computer|phone  (archive in $ARCHREF)
op_restore() {
  local target=$1 mnt rc=0
  borg_check_repo
  mount_archive || { log "could not mount the archive (is FUSE/pyfuse3 working?)"; return 2; }
  if [ "$target" = computer ]; then
    local dd; dd=$(device_dir); mkdir -p "$dd"
    sync_tree "$ARCHROOT" "$dd" computer 0 || rc=$?
  else
    while IFS= read -r mnt; do sync_tree "$ARCHROOT" "$mnt" phone 0 || rc=$?; done <<< "$mounts"
  fi
  cleanup
  [ $rc -eq 0 ] && log "restore finished"
  return $rc
}

# ---- extras: repos, transfer, maintenance (optional; not needed for ordinary phone backups) -----------
ask_text() {   # ask_text "prompt" [default]
  if [ $HAVE_GUM = 1 ]; then gum input --header "$1" --value "${2:-}" --width 70
  else local v; read -rp "$1 [${2:-}]: " v; echo "${v:-${2:-}}"; fi
}
borg_bin_for() { if [ "$1" = 1 ]; then echo "$BORG1_BIN"; else echo "$BORG2_BIN"; fi; }

x_prune() {
  borg_check_repo
  local s
  log "prune phone archives ($BORG_NAME)"
  if [ "$BORG_MAJOR" = 1 ]; then
    for s in phone-media phone-full; do "$BORG" prune --glob-archives "$s-*" "${KEEP[@]}" --show-rc; done
  else
    for s in phone-media phone-full; do "$BORG" prune -a "$s" "${KEEP[@]}" --show-rc; done
  fi
  # Borg 1: prune also removes leftover ".checkpoint" archives of interrupted backups. Borg 2 has none.
}
x_compact() { borg_check_repo; log "compact"; "$BORG" compact --show-rc; }
x_check()   { borg_check_repo; log "check (this can take a while)"; "$BORG" check --show-rc; }
x_unlock() {
  borg_check_repo
  pgrep -f "$BORG" >/dev/null && pgrep -af "$BORG" | grep -qE 'create|prune|compact|check|delete' \
    && fail "a borg process seems to be running; not breaking the lock"
  log "break-lock"; "$BORG" break-lock
}

# x_init_repo MAJOR PATH none|passphrase
x_init_repo() {
  local m=$1 path=$2 enc=$3 bin mode
  bin=$(borg_bin_for "$m")
  command -v "$bin" >/dev/null || fail "borg $m not found ($bin)"
  [ -n "$path" ] || fail "no repo path given"
  if [ -d "$path" ] && [ -n "$(ls -A "$path" 2>/dev/null)" ]; then fail "$path already exists and is not empty"; fi
  case "$enc" in
    none) mode=none ;;
    passphrase) if [ "$m" = 1 ]; then mode=repokey-blake2; else mode=repokey-aes-ocb; fi
      log "Borg will ask for a passphrase. For unattended runs export BORG_PASSPHRASE (and keep a backup of the key: borg key export)." ;;
    *) fail "--encryption must be none or passphrase" ;;
  esac
  log "creating Borg $m repo at $path ($enc)"
  if [ "$m" = 1 ]; then env -u BORG_REPO -u BORG_PASSPHRASE "$bin" init -e "$mode" "$path"
  else env -u BORG_REPO -u BORG_PASSPHRASE "$bin" repo-create -r "$path" -e "$mode"; fi
}

# x_transfer DEST_MAJOR DEST_REPO DELETE(0|1) [archive refs...]   (no refs = all phone archives)
x_transfer() {
  local dm=$1 dr=$2 del=$3; shift 3
  local refs=("$@") dbin ref name base ts line lines copied=() failed=0
  dbin=$(borg_bin_for "$dm")
  borg_check_repo
  command -v "$dbin" >/dev/null || fail "borg $dm not found ($dbin)"
  [ -n "$dr" ] || fail "no destination repo"
  [ "$dr" != "$REPO" ] || fail "destination is the same as the source repo"
  if [ -z "$(BORG_REPO=$dr "$dbin" $([ "$dm" = 1 ] && echo info || echo repo-info) 2>&1 | grep -iE 'repository (id|location)|^Location')" ]; then
    fail "cannot open a Borg $dm repo at $dr - create it first (More... > Create a new Borg repo)"
  fi
  lines=$(list_archives) || fail "could not list archives"
  if [ ${#refs[@]} -eq 0 ]; then while IFS='|' read -r ref _; do [ -n "$ref" ] && refs+=("$ref"); done <<< "$lines"; fi
  [ ${#refs[@]} -gt 0 ] || fail "no archives to transfer"
  log "transferring ${#refs[@]} archive(s) from $REPO (Borg $BORG_MAJOR) to $dr (Borg $dm)"

  if [ "$BORG_MAJOR" = 2 ] && [ "$dm" = 2 ]; then
    log "Borg 2 -> Borg 2: trying native 'borg transfer' (keeps timestamps and dedup)"
    if BORG_REPO=$dr "$dbin" transfer --other-repo "$REPO" -a 'sh:phone-*' --show-rc; then
      copied=("${refs[@]}")
    else
      log "native transfer failed (e.g. different encryption keys) - falling back to extract + re-archive"
    fi
  fi
  if [ ${#copied[@]} -eq 0 ]; then
    for ref in "${refs[@]}"; do
      line=$(grep -F "$ref|" <<< "$lines" | head -1); name=${line##*|}
      base=$(sed -E 's/-[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}$//' <<< "$name")
      ARCHREF=$ref
      log "re-archiving $name ..."
      if ! mount_archive; then log "could not mount $ref"; failed=1; continue; fi
      cd "$ARCHROOT" || { failed=1; continue; }
      local src=() d; for d in */; do src+=("${d%/}"); done
      local common=(--stats --compression auto,zstd,3 --files-cache disabled --noctime --noflags --noacls --noxattrs)
      if [ "$dm" = 1 ]; then
        ts=$(date +%Y-%m-%d_%H-%M)
        BORG_REPO=$dr "$dbin" create "${common[@]}" "::$base-$ts" "${src[@]}" || failed=1
      else
        BORG_REPO=$dr "$dbin" create "${common[@]}" --tags phone --comment "copied from $REPO" "$base" "${src[@]}" || failed=1
      fi
      cd "$HOME" || true; cleanup
      [ $failed = 0 ] && copied+=("$ref")
    done
  fi
  [ $failed = 0 ] || { log "some archives failed to copy - nothing will be deleted from the source"; return 2; }

  if [ "$del" = 1 ] || { [ "$YES" = 0 ] && [ $INTERACTIVE = 1 ] && confirm "Copied ${#copied[@]} archive(s). Delete them from the OLD repo ($REPO)?"; }; then
    for ref in "${copied[@]}"; do
      log "deleting $ref from $REPO"
      if [ "$BORG_MAJOR" = 1 ]; then "$BORG" delete "$REPO::$ref"; else "$BORG" delete -a "$ref"; fi
    done
    log "deleted. Run a compact on the old repo to get the space back."
  fi
}

# Apply the exclusions to what is already backed up. DESTRUCTIVE: always asks (unless --yes).
x_apply_excludes_folder() {
  local st n total=0 out line rel dev err roots=() victims=() v moved=0 skipped=0
  load_excludes
  [ ${#EX_FOLDER[@]} -gt 0 ] || { log "no exclusions defined ($EXCLUDE_FILE)"; return 1; }
  command -v gio >/dev/null || fail "gio (trash) not found - refusing to delete without a trash"
  for dev in "$DEST"/*/; do for st in "$dev"*/; do [ -d "$st" ] && roots+=("${st%/}"); done; done
  [ ${#roots[@]} -gt 0 ] || { log "no folder copy in $DEST"; return 1; }
  # Find the matches with rsync's own matching (source = destination, dry run), so they are exactly
  # what a sync would have skipped. Files are only ever MOVED TO THE TRASH (gio trash), never rm'd.
  for st in "${roots[@]}"; do
    out=$(rsync -rn -i -8 --ignore-existing --delete-excluded "${EX_FOLDER[@]}" "$st/" "$st/" 2>/dev/null \
          | sed -n 's/^\*deleting  *//p' | grep -v '/$')
    n=0
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      rel=$(printf '%b' "$(sed 's/\\#\([0-7][0-7][0-7]\)/\\\1/g' <<< "$line")")   # rsync escapes odd bytes as \#ooo
      case "$rel" in /*|../*|*/../*|..|"") skipped=$((skipped+1)); continue ;; esac
      [ -f "$st/$rel" ] && [ ! -L "$st/$rel" ] || { skipped=$((skipped+1)); continue; }
      victims+=("$st/$rel"); n=$((n+1))
    done <<< "$out"
    total=$((total + n))
    log "$st: $n file(s) match the exclusions"
  done
  [ "$skipped" -eq 0 ] || log "$skipped listed item(s) could not be matched to a plain file and will be left alone"
  [ "$total" -gt 0 ] || { log "nothing in the folder copy matches the exclusions"; return 0; }
  for v in "${victims[@]:0:15}"; do log "    ${v#"$DEST"/}"; done
  [ "$total" -gt 15 ] && log "    ... and $((total-15)) more"
  if [ "$YES" = 0 ]; then
    [ $INTERACTIVE = 1 ] || fail "refusing to remove files without --yes"
    confirm "Move these $total file(s) to the Trash? (restorable; the phone is untouched)" || { log "cancelled"; return 0; }
  fi
  for v in "${victims[@]}"; do
    if err=$(gio trash -- "$v" 2>&1); then moved=$((moved+1)); else skipped=$((skipped+1)); log "could not trash ${v#"$DEST"/}: ${err#gio: }"; fi
  done
  for st in "${roots[@]}"; do find "$st" -mindepth 1 -type d -empty -delete 2>/dev/null; done   # empty folders only
  log "moved $moved file(s) to the Trash ($skipped left alone). Empty the Trash to get the disk space back."
  [ "$skipped" -eq 0 ]
}

# x_apply_excludes_borg [ref...]   (no refs = every phone archive)
x_apply_excludes_borg() {
  local refs=("$@") ref lines n want=0 pf="$STATE/exclude-only.txt" out sc
  load_excludes
  [ ${#EX_BORG[@]} -gt 0 ] || { log "no exclusions defined ($EXCLUDE_FILE)"; return 1; }
  printf '%s\n' "${EX_BORG[@]}" > "$pf"
  borg_check_repo
  if [ ${#refs[@]} -eq 0 ]; then
    lines=$(list_archives) || fail "could not list archives"
    while IFS='|' read -r ref _; do [ -n "$ref" ] && refs+=("$ref"); done <<< "$lines"
  fi
  [ ${#refs[@]} -gt 0 ] || { log "no phone archives in $REPO"; return 0; }
  log "checking ${#refs[@]} archive(s) in $REPO against the exclusions ..."
  for ref in "${refs[@]}"; do
    if [ "$BORG_MAJOR" = 1 ]; then out=$("$BORG" recreate -n --list --patterns-from "$pf" "$REPO::$ref" 2>&1)
    else out=$("$BORG" recreate -n --list -a "$ref" --patterns-from "$pf" 2>&1); fi
    n=$(grep -cE '^- ' <<< "$out")
    log "  $ref: $n item(s) would be removed"
    want=$((want + n))
  done
  [ "$want" -gt 0 ] || { log "no archive contains anything matching the exclusions"; return 0; }
  if [ "$YES" = 0 ]; then
    [ $INTERACTIVE = 1 ] || fail "refusing to rewrite archives without --yes"
    confirm "Rewrite ${#refs[@]} archive(s) without these files? This is permanent." || { log "cancelled"; return 0; }
  fi
  for ref in "${refs[@]}"; do
    log "recreating $ref"
    if [ "$BORG_MAJOR" = 1 ]; then "$BORG" recreate --stats --patterns-from "$pf" "$REPO::$ref" || return 1
    else "$BORG" recreate --stats -a "$ref" --patterns-from "$pf" || return 1; fi
  done
  log "archives rewritten (borg replaces the originals). The repo only shrinks after a compact."
  if [ $COMPACT = 1 ] || { [ "$YES" = 0 ] && [ $INTERACTIVE = 1 ] && confirm "Compact the repo now to free the space?"; }; then x_compact; fi
}

x_apply_excludes() {   # x_apply_excludes folder|borg|both [refs...]
  local t=$1 rc=0; shift
  case "$t" in folder|both) x_apply_excludes_folder || rc=1 ;; esac
  case "$t" in borg|both) x_apply_excludes_borg "$@" || rc=1 ;; esac
  return $rc
}

extras_menu() {
  local x m p enc to dm
  x=$(choose "More: repos, transfer, maintenance" \
      "Switch the Borg repo used in this session" \
      "Create a new Borg repo" \
      "Copy archives to another repo" \
      "Edit exclusions file" "Apply exclusions to existing backups" "Prune old archives" "Compact repo (free space)" "Check repo" "Break a stale lock" "Back") || return 0
  case "$x" in
    Switch*) m=$(choose "Borg version of that repo" "Borg 1 (stable)" "Borg 2 (experimental)") || return 0
      case "$m" in "Borg 1"*) m=1 ;; *) m=2 ;; esac
      p=$(ask_text "Repo path" "$([ "$m" = 1 ] && echo "$BORG1_REPO" || echo "$BORG2_REPO")")
      set_repo "$m" "$p" ;;
    "Create a new"*) m=$(choose "Borg version" "Borg 1 (stable)" "Borg 2 (experimental)") || return 0
      case "$m" in "Borg 1"*) m=1 ;; *) m=2 ;; esac
      p=$(ask_text "Where should the new repo go? (path)" "")
      enc=$(choose "Encryption" "none (no passphrase)" "passphrase") || return 0
      case "$enc" in none*) enc=none ;; *) enc=passphrase ;; esac
      x_init_repo "$m" "$p" "$enc" && confirm "Use the new repo for this session?" && set_repo "$m" "$p" ;;
    "Copy archives"*) m=$(choose "Borg version of the DESTINATION repo" "Borg 1 (stable)" "Borg 2 (experimental)") || return 0
      case "$m" in "Borg 1"*) dm=1 ;; *) dm=2 ;; esac
      to=$(ask_text "Destination repo path (must already exist)" "")
      local lines refs=() picked
      lines=$(list_archives) || { echo "could not list archives"; return 0; }
      if [ $HAVE_GUM = 1 ]; then
        local -A map=(); local items=() ref desc _
        while IFS='|' read -r ref desc _; do map["$desc"]=$ref; items+=("$desc"); done <<< "$lines"
        picked=$(gum choose --no-limit --header "Select archives to copy (space = select, enter = go; none = all)" "${items[@]}")
        while IFS= read -r desc; do [ -n "$desc" ] && refs+=("${map[$desc]}"); done <<< "$picked"
      fi
      x_transfer "$dm" "$to" 0 "${refs[@]}" ;;
    Edit*) x_edit_excludes; return 0 ;;
    Apply*) enc=$(choose "Apply the exclusions to..." "The folder copy" "Borg archives" "Both") || return 0
      case "$enc" in "The folder"*) to=folder ;; Borg*) to=borg ;; *) to=both ;; esac
      x_apply_excludes "$to" ;;
    Prune*) x_prune ;;
    Compact*) x_compact ;;
    Check*) x_check ;;
    Break*) x_unlock ;;
    *) return 0 ;;
  esac
  [ $HAVE_GUM = 1 ] && read -rp "Press Enter to continue " _
  return 0
}

# ---- choose what to do (before logging starts, so the menus own the terminal) -------------------------------
ASK=0
if [ -z "$MODE" ] && [ $STATUS = 0 ] && [ $LISTARCH = 0 ] && [ $SHOWEX = 0 ]; then
  [ $INTERACTIVE = 1 ] || fail "no terminal to ask on; pass --mode (see --help)"
  while :; do
    banner
    pick=$(choose "What do you want to do?" "$MENU_P2F" "$MENU_P2B" "$MENU_P2FB" "$MENU_F2B" "$MENU_F2P" "$MENU_B2F" "$MENU_B2P" "$MENU_X" "$MENU_Q") || exit 0
    case "$pick" in
      "$MENU_P2F") MODE=p2f ;; "$MENU_P2B") MODE=p2b ;; "$MENU_P2FB") MODE=p2fb ;;
      "$MENU_F2B") MODE=f2b ;; "$MENU_F2P") MODE=f2p ;; "$MENU_B2F") MODE=b2f ;; "$MENU_B2P") MODE=b2p ;;
      "$MENU_X") extras_menu; continue ;;
      *) exit 0 ;;
    esac
    break
  done
  ASK=1
fi

if [ $SHOWEX = 1 ]; then
  build_filters
  echo "# exclusions file: $EXCLUDE_FILE ($([ -r "$EXCLUDE_FILE" ] && echo found || echo none))"
  echo "# folder copy (rsync):"; [ ${#EX_FOLDER[@]} -eq 0 ] || printf '%s\n' "${EX_FOLDER[@]}"
  echo "# Borg:"; [ ${#EX_BORG[@]} -eq 0 ] || printf '%s\n' "${EX_BORG[@]}"
  exit 0
fi
# read-only info for scripts/agents
if [ $STATUS = 1 ]; then
  m=absent; ls -d "$GVFS"/mtp:* >/dev/null 2>&1 && m=connected
  ok=no; if [ -n "$REPO" ]; then if [ -n "$LOCAL_REPO" ]; then [ -e "$REPO/config" ] && ok=yes; else ok=unknown; fi; fi
  printf 'phone=%s\nfolder=%s\nfolder_exists=%s\nborg=%s\nborg_bin=%s\nrepo=%s\nrepo_available=%s\nconfig=%s\n' \
    "$m" "$DEST" "$([ -d "$DEST" ] && echo yes || echo no)" "$BORG_MAJOR" "$BORG" "$REPO" "$ok" "$CONF"
  exit 0
fi
if [ $LISTARCH = 1 ]; then borg_check_repo; list_archives | cut -d'|' -f1,2; exit 0; fi

case "$MODE" in prune|compact|check|unlock|init|transfer|apply-excludes) ;; p2f|p2b|p2fb|f2b|f2p|b2f|b2p) ;; *) fail "bad --mode '$MODE' (see --help)" ;; esac
if [ $ASK = 1 ] && [ $FULL_SET = 0 ] && [ "$MODE" != b2f ] && [ "$MODE" != b2p ]; then
  inc=$(choose "What should be included?" "Images & videos only (default)" "Everything (full backup - can be much bigger)") || exit 0
  case "$inc" in Everything*) FULL=1 ;; esac
fi
build_filters

if [ "$MODE" = b2f ] || [ "$MODE" = b2p ]; then
  borg_check_repo
  if [ -z "$ARCHREF" ]; then
    [ $INTERACTIVE = 1 ] || fail "pass --archive for b2f/b2p when not on a terminal"
    pick_archive
  fi
fi
if [ $ASK = 1 ] && [ $YES = 0 ]; then
  what="$MODE"; [ -n "$ARCHREF" ] && what="$MODE from $ARCHREF"
  confirm "Go ($what)?" || exit 0
fi

# ---- run ---------------------------------------------------------------------------------------------------
exec > >(tee -a "$LOG") 2>&1
log "mode: $MODE   (log: $LOG)"
mounts=""
overall=0
case "$MODE" in p2f|p2b|p2fb|f2p|b2p) need_phone ;; esac

borg_step=""   # set to phone|computer when a Borg backup should run
case "$MODE" in
  p2f|p2fb)
    op_phone_to_computer; r=$?
    if [ $r -eq 0 ]; then [ "$MODE" = p2fb ] && borg_step=phone
    else
      overall=1
      if [ "$MODE" = p2fb ]; then log "folder copy did not complete; continuing with Borg"; borg_step=phone
      else log "FALLBACK: the folder copy is incomplete, backing up to the Borg repo instead."; borg_step=phone; fi
    fi ;;
  p2b) borg_step=phone ;;
  f2b) borg_step=computer ;;
  f2p) op_computer_to_phone || overall=2 ;;
  b2f) op_restore computer || overall=2 ;;
  b2p) op_restore phone || overall=2 ;;
  prune) x_prune || overall=2 ;;
  compact) x_compact || overall=2 ;;
  check) x_check || overall=2 ;;
  unlock) x_unlock || overall=2 ;;
  init) x_init_repo "$BORG_MAJOR" "$NEW_REPO" "$ENC" || overall=2 ;;
  apply-excludes) case "$TARGET" in folder|borg|both) ;; *) fail "--target folder|borg|both is required" ;; esac
    x_apply_excludes "$TARGET" ${ARCHREF:+"$ARCHREF"} || overall=2 ;;
  transfer) x_transfer "${TO_MAJOR:-$BORG_MAJOR}" "$TO_REPO" "$DELETE_SRC" || overall=2 ;;
esac

if [ -n "$borg_step" ]; then
  op_borg_create "$borg_step"; r=$?
  if [ $r -eq 2 ]; then
    # the Borg step failed: only a partial failure if the folder copy succeeded
    if [ "$MODE" = p2fb ] && [ $overall -eq 0 ]; then overall=1; else overall=2; fi
  elif [ $r -eq 1 ] && [ $overall -eq 0 ]; then overall=1; fi
fi

find "$STATE" -name 'backup-*.log' -mtime +90 -delete
case $overall in
  0) log "done"; notify "Phone backup finished" "Log: $LOG" ;;
  1) log "done with warnings/fallback (see above)"; notify "Phone backup finished with warnings" "Log: $LOG" ;;
  *) log "FAILED - see above"; notify "Phone backup failed" "Log: $LOG" ;;
esac
exit $overall
