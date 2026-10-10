# Phone Backerupper

One bash script that backs up the photos and videos on an Android phone plugged in over USB
(**"File transfer" / MTP mode**) to a plain folder, a [Borg](https://www.borgbackup.org/)
repo, or both - and gets them back onto the computer or the phone again. It has a small menu
(uses [`gum`](https://github.com/charmbracelet/gum) if installed, plain prompts otherwise).

**Linux only.** It relies on gvfs (MTP), FUSE and rsync. It will not work on Windows or macOS
(including WSL, which has no USB MTP access).

> **Status:** written for and tested on one machine (Arch, Samsung phone, Borg 2). The Borg 1 code
> path is written but has had less testing. Read the script before pointing it at data you care about -
> it never deletes anything, but it does write to your phone, folder and Borg repo.

## What it does

| Menu item | What happens |
|---|---|
| Phone → Folder | `rsync` into a folder; only new/changed files are copied |
| Phone → Borg | new archive in the repo, read straight from the phone (no copy needed first) |
| Phone → Folder + Borg | both. If the folder's drive lacks space, the rsync is skipped/abandoned and Borg still runs, so the media always ends up somewhere |
| Folder → Borg | archive the folder from the previous sync |
| Folder → Phone | copy the folder back to the phone |
| Borg archive → Folder / Phone | pick an archive from a list; it is mounted read-only and rsynced out, so no temporary copy is needed |

* Default scope is **images & videos** from every folder on the phone (DCIM, Pictures, Download, WhatsApp media, ...), folder structure kept. `--full` (or the menu question) takes everything visible over MTP, in its own archive series (`phone-full`).
* Nothing is ever deleted. Restores never overwrite a file that already exists at the target.
* Re-runs are incremental. Files are compared by name and size (MTP timestamps aren't reliable).
* Works with the phone in **File transfer** mode. "Transferring images" (PTP) needs `gvfs-gphoto2` and only exposes DCIM-type folders; it isn't supported by the script.

## Requirements

`bash` 4.4+, `rsync`, `gio` (gvfs) with MTP support (`gvfs-mtp` on Arch, `gvfs-backends` on Debian/Ubuntu), `fusermount3`, and for Borg: Borg 1.x (stable) or Borg 2 (experimental). Optional: `gum` for the nicer menu.

## Setup

```sh
git clone https://github.com/Scronch953/phone-backerupper
cd phone-backerupper
mkdir -p ~/.config
cat > ~/.config/phone-backup.conf <<'CONF'
DEST="$HOME/Phone Media Backup"      # plain copy on this computer
BORG1_BIN=borg
BORG1_REPO=/path/to/borg-repo        # an existing Borg 1 repo (borg init ...)
CONF
./phone-backup.sh
```

Borg 1 is the default. For **Borg 2 (experimental)**, set `BORG_MAJOR=2`, `BORG2_BIN` and `BORG2_REPO` in the config (or use `--borg2`). Archives are called `phone-media-<date>` on Borg 1 and form a `phone-media` series on Borg 2. If your repo has no passphrase, set `BORG_UNENCRYPTED=1`. See the top of the script for every setting.

Plug the phone in, unlock it, pick **File transfer** in the USB notification, then run the script. For unattended runs use `--mode p2fb --yes` (modes: `p2f p2b p2fb f2b f2p b2f b2p`; restores also need `--archive`).

## Experimental: history copies of the folder

By default the folder is simply the latest sync; if you want a series of backups, use Borg.
If you don't want Borg but do want dated copies, `--history reflink|hardlink` makes a dated copy of the folder
after each Phone → Folder sync in `<folder>-history/`:

* `reflink` - copy-on-write copies; nearly free on **btrfs** or **XFS**. Not available on ext4.
* `hardlink` - unchanged files share disk space on any Linux filesystem (`cp -al`). Since synced files are never modified in place, history copies stay intact.
* Without either, each dated copy would be a full duplicate and eat disk space - which is why it is off by default.
* `HISTORY_KEEP=N` in the config keeps only the newest N copies (it deletes older ones from the history folder only).

## Exclusions

Skip files or folders with an exclusions file, `~/.config/phone-backup.exclude` (or `EXCLUDE_FILE=` in the config, `--exclude-file FILE`, or `--exclude PATTERN` on the command line). Menu: **More... > Edit exclusions file** creates a commented template and opens it in `$EDITOR`.

```
# one pattern per line
*.tmp                         # no "/" : matches at any depth
Screenshots/                  # trailing "/" : folders only (rsync; Borg ignores the slash)
DCIM/Camera/old               # contains "/" : path from the storage root
Android/media/com.whatsapp/WhatsApp/Media/WhatsApp Video

[folder]                      # only the rsync folder copy
Download/
[borg]                        # only Borg
*.mp4
[all]                         # back to both (the default at the top of the file)
```

Example - skip TV episodes, which have an `S01E02`-style marker in the name (any case, any folder):

```
*[Ss][0-9][0-9][Ee][0-9][0-9]*
```

The same file feeds both, so the folder copy and the Borg archives match by default; use `[folder]` / `[borg]` sections only if you want them to differ. Patterns are shell globs and are case-sensitive (`*.TMP` is not `*.tmp`). Exclusions apply when backing up from the phone or the folder (not to restores), in both the default images-and-videos mode and `--full`. `--show-excludes` prints what will be passed to rsync and Borg. Excluding something does not remove it from existing archives or the folder.

### Applying exclusions to what you already have (extra)

Menu: **More... > Apply exclusions to existing backups**, or `--mode apply-excludes --target folder|borg|both [--archive REF] [--compact] [--yes]`.

* **Folder copy:** files matching the exclusions are moved to your **Trash** (`gio trash`), never `rm`'d, so you can put them back. It uses rsync's own matching, so the result is exactly what a fresh sync would have skipped. Only plain files inside the folder copy are touched, anything it can't map to such a file is left alone, and if there's no usable Trash it removes nothing. Empty folders left behind are tidied. The phone is never touched. Empty the Trash to get the space back.
* **Borg:** archives are rewritten with `borg recreate` (Borg 1 and 2). Borg **replaces** the original archives itself, so there's nothing to delete afterwards, but this is permanent: the files are gone from those archives for good. The repo only shrinks after a `compact`, which it offers (or `--compact`). It first previews how many items each archive would lose, and asks before doing anything; unattended use needs `--yes`.

## Extras (optional)

None of this is needed for ordinary phone backups. In the menu: **More...**

* **Switch repo** - use a different Borg repo (Borg 1 or 2) for this session. Or pass `--repo PATH`.
* **Create a new Borg repo** - guided `borg init` / `borg repo-create` (no encryption, or passphrase). `--mode init --new-repo PATH [--encryption none|passphrase]`.
* **Copy archives to another repo** - `--mode transfer --to-repo PATH --to-borg 1|2 [--delete-source]`. Borg 2 → Borg 2 uses native `borg transfer`; any other combination (e.g. Borg 1 → Borg 2) extracts each archive temporarily via a read-only mount and re-archives it - slower, but works between any versions, and archive timestamps become "now". Afterwards it offers to delete the copied archives from the old repo (never without asking, or `--delete-source`).
* **Maintenance** - `--mode prune|compact|check|unlock`. Prune applies the retention in `KEEP` to the `phone-media` and `phone-full` series (on Borg 1 it also clears leftover `.checkpoint` archives from interrupted backups; Borg 2 doesn't make them). `unlock` runs `break-lock` and refuses if a Borg process is running.

## For scripts and agents

Everything the menu does is available as flags, with no prompts when `--mode` and `--yes` are given:

```sh
phone-backup.sh --status                 # key=value lines: phone, folder, borg, repo, repo_available
phone-backup.sh --list-archives          # ref|description lines (ref is what --archive takes)
phone-backup.sh --mode p2fb --yes        # back up phone to folder + Borg
phone-backup.sh --mode b2f --archive aid:1a2b3c4d --yes
```

Exit codes: `0` ok, `1` finished with warnings or a fallback, `2` failed, `64` bad usage. Logs go to `~/.local/state/phone-backup/`. Set `NOTIFY=0` in the config to turn off desktop notifications. See `--help` for every option.

## Notes

* Borg is read from the phone with `--files-cache mtime,size`, because FUSE inode numbers aren't stable. The first Borg run reads everything over USB (~10 MB/s); later runs only read changed files.
* Logs: `~/.local/state/phone-backup/`.
* Scratch space: no full copies are ever staged - restores stream from a read-only archive mount - so temporary use is tiny (mount point, temp files; `WORK_DIR` / `--workdir`, default `~/.local/state/phone-backup`). Borg's own cache can be moved with `CACHE_DIR` (e.g. onto the repo drive if your home is small).
* Pruning (Borg): 7 daily / 8 weekly / 24 monthly / 10 yearly by default; `--no-prune` disables it. `borg compact` is only run with `--compact`.

MIT licensed.
