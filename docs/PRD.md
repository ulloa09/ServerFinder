# PRD: ServerFinder — instant filename search for SMB server shares

## Problem Statement

I connect to my office server's shared folders over Wi‑Fi every day (SMB shares mounted in Finder under `/Volumes`). When I need a specific file and only remember part of its name, Finder search doesn't help: Spotlight doesn't index network volumes, so searching the share either returns nothing or crawls the whole server live, which over Wi‑Fi takes forever. I end up clicking through folders by hand, which wastes time every day.

## Solution

A small native macOS app (Apple Silicon, menu bar) that keeps its **own local index of filenames** on the server shares I choose. It walks the mounted shares in the background, stores every file and folder name in a fast local database on my Mac, and gives me a Spotlight‑style search box (global hotkey) that returns matches instantly — even while the index is refreshing, and even when the share isn't currently mounted. From a result I can open the file, reveal it in Finder, or copy its path.

It only searches **names and paths**, not file contents. No server-side software, no admin rights on the server needed.

> **Step 0 — check before building:** if the server is a Mac, a Synology/QNAP NAS, or Samba ≥ 4.12, it may support *Spotlight over SMB* server-side. If IT/the NAS can enable it, Finder search would just work and this app isn't needed. If that's not possible (common on Windows servers and older NAS), build the app.

## User Stories

1. As a daily server user, I want to type part of a filename and see matching files from the server instantly, so that I don't have to browse folders by hand.
2. As a user, I want search to match anywhere in the name (e.g. `cotiz` finds `2024_Cotizacion_Final.xlsx`), so that I don't need to remember how the name starts.
3. As a user, I want search to ignore upper/lower case, so that `INFORME` and `informe` find the same files.
4. As a Spanish-speaking user, I want search to ignore accents, so that `cotizacion` finds `Cotización.pdf`.
5. As a user, I want to type several words (e.g. `acme plano 2024`) and get files whose path contains all of them, so that I can narrow results quickly.
6. As a user, I want words to match against the full path, not just the filename, so that typing a client or project folder name plus a filename fragment finds the file.
7. As a user, I want to filter by extension (e.g. `ext:pdf` or `.dwg`), so that I only see the file type I need.
8. As a user, I want folders to appear in results too, so that I can jump to a project folder by name.
9. As a user, I want results sorted with best matches first (filename match before path-only match, then most recently modified), so that the file I want is near the top.
10. As a user, I want to see each result's name, parent folder, size and modified date, so that I can tell apart files with similar names.
11. As a user, I want to open a global search window with a keyboard shortcut from any app, so that searching is as fast as Spotlight.
12. As a user, I want to navigate results with the arrow keys and press Enter to open the file, so that I never need the mouse.
13. As a user, I want a shortcut (⌘Enter) to reveal the result in Finder, so that I can see the files around it.
14. As a user, I want a shortcut (⌘C) to copy the full path of a result, so that I can paste it into emails or chats with colleagues.
15. As a user, I want to drag a result into another app (e.g. an email), so that I can attach it directly.
16. As a user, I want the app to live in the menu bar and start at login, so that it's always ready without managing it.
17. As a user, I want to pick which mounted shares (or subfolders of them) are indexed, so that I control what gets crawled.
18. As a user, I want to exclude folders (e.g. `#recycle`, `.snapshots`, backup folders), so that results aren't polluted and scans are faster.
19. As a user, I want the app to start indexing automatically when a chosen share is mounted, so that I don't have to remember to trigger it.
20. As a user, I want the index to refresh automatically on a schedule while the share is mounted (e.g. every 1–2 hours), so that new files show up without my intervention.
21. As a user, I want a "Rescan now" button, so that I can force a refresh after I know something changed.
22. As a user, I want to still search the last index when I'm not connected to the server, so that I can at least find where a file lives.
23. As a user, I want results from an unmounted share to be marked as offline, so that I understand why it won't open.
24. As a user, I want the app to try to mount the share when I open an offline result, so that I don't need to reconnect manually in Finder. *(nice-to-have)*
25. As a user, I want to see indexing progress (files found so far, current share) and when each share was last fully indexed, so that I know how fresh the results are.
26. As a user, I want indexing to run in the background at low priority, so that my Mac and network stay responsive while I work.
27. As a user, I want indexing to survive a Wi‑Fi drop or the share unmounting mid-scan without corrupting the index, so that I always keep the last good index.
28. As a user, I want files deleted on the server to disappear from results after the next scan, so that I don't chase files that no longer exist.
29. As a user, I want indexing to skip folders I don't have permission to read without failing the whole scan, so that one restricted folder doesn't break everything.
30. As a user, I want the app to never modify, move or delete anything on the server, so that it's safe to run on shared company data.
31. As a user, I want the app to be lightweight (small memory, no CPU when idle), so that it doesn't drain my laptop battery.
32. As a user, I want to choose in Settings which app opens each file type (e.g. `.pdf` → Adobe Acrobat, `.docx` → Microsoft Word), so that files from the server open in the app I work with.
33. As a user, I want the apps offered for a file type to be the ones on my Mac that can open it, so that I don't have to hunt through the Applications folder.
34. As a user, I want file types without a rule, and rules whose app was uninstalled, to open with the Mac's default app, so that opening a file never fails because of a setting.

## Implementation Decisions

**Platform & stack**
- Native Swift + SwiftUI app for macOS 15+ on Apple Silicon (M4 Pro). Menu bar app (`MenuBarExtra`) with a floating search panel (`NSPanel`) — no Dock icon.
- Personal use, not distributed via the App Store: not sandboxed (needs to read `/Volumes/...` freely), ad‑hoc/personal signing. Launch at login via `SMAppService`.
- Index stored in **SQLite** in Application Support, using **FTS5 with the `trigram` tokenizer** (substring matching) over a normalized (lowercased, accent‑folded) copy of name and path. Accessed via GRDB.swift or the raw SQLite C API.
- Global hotkey via the `KeyboardShortcuts` package (user-configurable, default ⌥Space or similar).

**Modules** (the first three are deep, pure, and testable in isolation)

1. **ShareScanner** — given a root folder URL and an exclusion list, walks the tree and emits batches of `FileRecord { relativePath, name, isDirectory, size, modifiedAt }`. Hides all SMB quirks: uses bulk directory attribute reads (`getattrlistbulk`/`FileManager` enumerator with prefetched keys) because per-file `stat` calls are very slow over SMB; enumerates a few directories in parallel to hide network latency; skips unreadable folders and records them as warnings; supports cancellation. Interface: `scan(root, exclusions) -> AsyncThrowingStream<[FileRecord]>`.
2. **IndexStore** — owns the SQLite database. Interface is tiny:
   - `beginGeneration(share) -> GenerationID`, `insert(batch, generation)`, `commitGeneration(share, generation)` — a scan writes into a new generation; only on successful completion are older rows for that share removed atomically. An interrupted scan leaves the previous complete index intact (story 27/28).
   - `search(Query, limit) -> [SearchResult]`
   - `stats(share) -> { fileCount, lastCompletedScan }`
3. **QueryParser** — turns the typed string into a `Query { terms[], extensions[] }`: splits words, folds case and accents, recognizes `ext:pdf` / `.pdf`. Pure function.
4. **ShareMonitor** — watches `NSWorkspace` mount/unmount notifications, knows which configured shares are currently online, and asks the **ScanScheduler** to start a scan on mount and every N hours while mounted. Guarantees at most one scan per share at a time and cancels a scan when its share unmounts.
5. **Settings** — list of indexed share roots (stored as the share's SMB URL `smb://server/share` + subpath, so it survives being mounted at a different `/Volumes` name), exclusions, rescan interval, hotkey.
6. **OpenWithRules** — maps file extensions (lowercased, without the dot) to an app's bundle identifier and answers "which app opens this file name?", or nothing for "use the Mac's default". Pure and stored in the app's preferences; only affects files opened from ServerFinder, never Finder's own defaults.
7. **UI** — search panel (text field + results list, keyboard navigation, open / reveal / copy path / drag), menu bar menu (status, last indexed, Rescan now, Settings, Quit), settings window.

**Key behaviours**
- Changes made by *other* people on the server are not reported to the Mac (FSEvents doesn't work for remote changes on SMB), so freshness comes from **periodic full rescans**, not live watching. v1 keeps it simple: full rescan per share on mount + every N hours (default 2h).
- Results ranking: exact filename match > filename contains all terms > path-only match; ties broken by most recently modified. Limit to ~200 results; search runs on every keystroke (debounced ~50 ms).
- Offline results: if a result's share is not mounted, show it greyed; on open, attempt to mount via its `smb://` URL (`NSWorkspace.open`) and then open the file.
- Opening a file uses the matching **Open With** rule (`NSWorkspace.open(_:withApplicationAt:configuration:)`); with no rule, or when the rule's app is no longer installed, it falls back to the Mac's default app.
- The app only ever reads from the server.

## Testing Decisions

- Good tests check external behaviour through each module's public interface (what a scan emits, what a search returns), never internal SQL or private helpers.
- **QueryParser**: table-driven unit tests — accents, case, multiple terms, `ext:`/`.ext` forms, empty/whitespace input.
- **IndexStore**: tests against a temporary on-disk SQLite file — substring matches, accent-insensitive matches, multi-term AND, extension filter, ranking order, generation swap (old rows removed only after commit; interrupted generation leaves old index searchable), multiple shares isolated from each other.
- **OpenWithRules**: extension matching is case-insensitive and ignores the dot, files without an extension and folders have no rule, replacing and removing rules, and rules survive saving and loading.
- **ShareScanner**: tests against a temporary local directory tree built in the test — all files/folders found, exclusions respected, unreadable folder skipped with a warning, cancellation stops emission. (SMB itself is not simulated; a manual check against the real share covers that.)
- ShareMonitor and UI: manual testing only for v1.
- No prior art in this repo (new project); use Swift Testing.

## Out of Scope

- Searching inside file contents (text in PDFs, Word, etc.).
- Live/instant detection of changes on the server (only periodic rescans).
- Any server-side component or agent, and any write operation on the server.
- Integrating results into Finder's own search or Spotlight.
- Previews/Quick Look, tags, or file management (rename, move, delete).
- Windows/iOS versions, App Store distribution, multiple users.

## Further Notes

- **Expected scan speed:** over Wi‑Fi, SMB enumeration is latency-bound; expect roughly a few thousand entries per second. A share with ~500k files may take 5–20 minutes for the first scan; search works on the previous index meanwhile. Wired Ethernet / 5 GHz Wi‑Fi help a lot.
- **Possible v2 optimization** if scans are too slow: an incremental scan that only re-lists folders whose modification date changed since the last scan (SMB servers generally update a folder's mtime when entries are added/removed/renamed inside it), with the nightly full scan as a safety net.
- **Server:** Windows Server 2022 over SMB. Windows does not support Spotlight over SMB, so Step 0 doesn't apply and the app is needed. Default exclusions should include Windows system folders (`$RECYCLE.BIN`, `System Volume Information`, `~snapshot`) and junk files (`Thumbs.db`, `desktop.ini`, `~$*` Office lock files).
- **Open question:** approximate number of files on the shares.
