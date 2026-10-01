# dupefind

![CI](https://github.com/Jammore1203/dupefind/actions/workflows/ci.yml/badge.svg)

Find duplicate files fast. Written in Zig with no dependencies, and builds to a single static binary.

```console
$ dupefind ~/Pictures
3 copies of 4.2 MiB  (8.4 MiB reclaimable)
  2023/holiday/IMG_0412.jpg
  backup/IMG_0412.jpg
  phone-dump/IMG_0412 (1).jpg

2 copies of 812.0 KiB  (812.0 KiB reclaimable)
  scans/passport.pdf
  documents/passport-scan.pdf

2318 files scanned, 2 duplicate groups, 9.2 MiB reclaimable (21.6 MiB read)
```

It never deletes anything itself. To act on the results, pipe the redundant copies (every file except the first in each group) to something else:

```bash
dupefind -0 ~/Downloads | xargs -0 ls -l        # review
dupefind -0 ~/Downloads | xargs -0 trash        # then bin them
```

## Usage

```
dupefind [options] [DIR...]

  -m, --min-size N   ignore files smaller than N bytes (k/m/g suffixes ok)
  -a, --all          include hidden files and directories (.git, .cache, ...)
  -s, --summary      print only the totals
  -0, --null         print duplicate paths NUL-separated, for xargs -0
```

## How it works

Hashing every file would be slow, so files are narrowed down in three passes and most are never opened:

1. **Size.** The directory walk records each file's size. A file with a unique size can't have a duplicate.
2. **First 4 KiB.** Files that share a size get a BLAKE3 hash of their first block. This separates most look-alikes, such as same-sized photos, after reading very little.
3. **Full content.** Only files whose first block matches get hashed completely.

Groups are sorted by reclaimable space, largest first.

**Hard links** to the same inode are recognised and counted once: deleting a hard link frees nothing, so they aren't reported as duplicates. Hidden directories are skipped by default, so `.git` objects don't flood the results.

The summary line reports how much was actually read, so you can see the passes working.

## Build

Needs [Zig 0.13](https://ziglang.org/download/).

```bash
zig build -Doptimize=ReleaseFast    # binary in zig-out/bin/dupefind
zig build test --summary all        # unit tests (use real temp dirs)
```

The tests build real directory trees in a temp folder. They cover nested dirs, same-size files with different content, files that only differ after the first 4 KiB (so the partial hash collides and the full hash has to split them), hidden dirs, size filtering and hard links.
