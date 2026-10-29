# ServerFinder

Find files on your office server instantly, by name.

Finder can't search shared server folders (SMB) well: Spotlight doesn't index network
volumes, so searches come back empty or take forever. ServerFinder keeps its own list of
the file names on the folders you choose, on your Mac, and searches that list as you type.

It only reads file names. It never changes, moves or deletes anything on the server.

See [docs/PRD.md](docs/PRD.md) for the full plan.

## Using it

1. Connect to the server in Finder as usual (**Go → Connect to Server…**).
2. Open ServerFinder. The first time, Settings opens: click **Add** next to the connected
   server folders you want to search (or **Add Folder…** to pick a subfolder).
3. Press **⌥ Space** in any app (or click the magnifying glass in the menu bar) and type
   part of a file name. You can change the shortcut, and turn on **Open ServerFinder when
   you log in**, in **Settings → General**.
   - Accents and capitals don't matter: `cotizacion` finds `Cotización.xlsx`.
   - Type several words to narrow down: `acme 2024 plano`. Words can also be folder names
     anywhere in the path, including the shared folder itself (`1a examen`).
   - Limit to file types with `.pdf` or `ext:pdf` (several: `ext:pdf,docx`). Folders show up
     as results too; opening one opens it in Finder.
   - Exact names come first, then names containing every word, then files found through
     their folders; newer files first within each group.
   - Each result shows where it lives, when it was last modified and its size.
   - **↑ / ↓** to pick a result, **Return** to open it, double-click works too.
   - **⌘Return** shows it in Finder, **⌘C** copies its full path, and you can drag a result
     into Mail or any other app. Right-click a result for the same options.
   - **Esc** clears the text; press it again to close.
   - Right-click the menu bar icon to see each folder's status (items, when it was last
     indexed, problems), and for **Rescan Now**, **Settings…** and **Quit**. The icon
     pulses while indexing.

To open a file type with a specific app (e.g. `.pdf` with Adobe Acrobat instead of Preview),
add it in **Settings → Open With**. This only affects files opened from ServerFinder; types
without a rule, and rules whose app was uninstalled, use the Mac's default app.

Some files are left out on purpose: Windows system folders (`$RECYCLE.BIN`,
`System Volume Information`), `Thumbs.db`, `desktop.ini` and Office lock files (`~$…`).
Edit the list in **Settings → Excluded**; `*` and `?` work as wildcards, and a pattern with
`/` (e.g. `Backups/Old`) leaves out one folder inside a shared folder.

The list refreshes on its own: when ServerFinder starts, whenever a server folder connects,
and every 2 hours while it stays connected (change it in **Settings → General**). Disconnecting
mid-scan keeps the previous list. **Rescan Now** refreshes everything right away. If macOS
mounts a share under a different name (e.g. `Projects-1`), ServerFinder still recognizes it.
On a folder's first scan, results appear while it's still indexing.

The app follows your Mac's language (Spanish or English).

## Building

Requires macOS 15 or later on Apple Silicon and the Swift toolchain (Xcode, or just the
Command Line Tools: `xcode-select --install`).

```sh
scripts/build-app.sh            # builds build/ServerFinder.app
scripts/build-app.sh --install  # also copies it to /Applications
scripts/test.sh                 # runs the tests
```

During development, `swift run ServerFinder` starts the app without bundling it (in English,
since translations are only added to the bundle).

## Where data lives

- Index: `~/Library/Application Support/ServerFinder/index.sqlite` (safe to delete; it's rebuilt on the next scan)
- Settings: the `com.ulloa09.ServerFinder` preferences domain
