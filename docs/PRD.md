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
35a. As a user, I want to press Space on a result to see a Quick Look preview (PDF, image, Office document, video…), so that I can check it's the right file without opening an app.
35b. As a user, I want Space to keep typing spaces while I'm writing my search, and to preview only once I've moved through the results with the arrow keys, so that multi-word searches still work.
35c. As a user, I want ⌘Y to preview at any time and ↑/↓ to move to the previous or next result while the preview is open, like in Finder.

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
- **Quick Look**: the search panel provides the shared `QLPreviewPanel` with the selected result. Space previews only after the user has used ↑/↓ since typing ("browsing"); typing any character returns to typing mode. ⌘Y always previews. While the preview is open, ↑/↓ change the selected result and the preview follows; the search panel stays open behind it.
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

- Searching inside file contents in phase 1 — now planned as **Phase 2: Content search** below.
- Live/instant detection of changes on the server (only periodic rescans).
- Any server-side component or agent, and any write operation on the server.
- Integrating results into Finder's own search or Spotlight.
- Previews/Quick Look, tags, or file management (rename, move, delete).
- Windows/iOS versions, App Store distribution, multiple users.

## Further Notes

- **Expected scan speed:** over Wi‑Fi, SMB enumeration is latency-bound; expect roughly a few thousand entries per second. A share with ~500k files may take 5–20 minutes for the first scan; search works on the previous index meanwhile. Wired Ethernet / 5 GHz Wi‑Fi help a lot.
- **Possible v2 optimization** if scans are too slow: an incremental scan that only re-lists folders whose modification date changed since the last scan (SMB servers generally update a folder's mtime when entries are added/removed/renamed inside it), with the nightly full scan as a safety net.
- **Server:** Windows Server 2022 over SMB. Windows does not support Spotlight over SMB, so Step 0 doesn't apply and the app is needed. Default exclusions should include Windows system folders (`$RECYCLE.BIN`, `System Volume Information`, `~snapshot`) and junk files (`Thumbs.db`, `desktop.ini`, `~$*` Office lock files).
- **Measured (2026-10-29):** the user's Wi-Fi scans ~123k items in about a minute.

---

# Phase 2: Content search

## Problem Statement

Often I don't remember a file's name, only what's written in it: a student's name in an exam, a phrase from a guideline, a code in a report. Name search can't find those files, and Finder can't search inside files on the server either.

## Solution

ServerFinder also reads the text inside documents on the indexed folders — PDF, Word, PowerPoint, plain text, CSV, RTF and XML, plus scanned PDFs through macOS's built-in text recognition (OCR) — and stores it in the same local index. Reading happens slowly in the background after each name scan, and afterwards only new or changed files are read again. In the search panel, name matches stay on top; a separate **Inside files** section lists documents whose text contains every typed word, each with a short preview of the matching passage with the words in bold.

Sizing (2 of the user's shares, 36k files): ~10.4k PDF (1.6 GB), ~670 .docx, ~330 .txt, ~20k small .xml — about 2 GB to read once.

## User Stories

35. As a user, I want to find a document by words written inside it, so that I can find files whose name I don't remember.
36. As a user, I want content matches in their own **Inside files** section below name matches, so that I can tell why each file was found.
37. As a user, I want a short preview of the matching text with my words in bold, so that I can pick the right document without opening it.
38. As a user, I want content search to ignore case and accents and to require all my words, like name search, so that it behaves predictably.
39. As a user, I want a word to match its beginning too (`cotiz` finds "cotización"), so that I don't need to type whole words.
40. As a user, I want the file-type filter (`.pdf`, `ext:docx`) to apply to content matches too, so that I can narrow them down.
41. As a user, I want the text of PDF files to be searchable.
42. As a user, I want the text of Word files (.docx and .doc) to be searchable.
43. As a user, I want the text of PowerPoint files (.pptx) to be searchable.
44. As a user, I want plain text, CSV, RTF and XML files to be searchable.
45. As a user, I want scanned PDFs (images of pages) to be readable through text recognition, in Spanish and English, so that old scanned documents are searchable too.
46. As a user, I want files larger than 20 MB to be skipped for content (still found by name), so that reading doesn't take forever over Wi-Fi.
47. As a user, I want content reading to happen in the background at low priority after names are indexed, so that name search is ready first and my Mac stays responsive.
48. As a user, I want only new or changed files to be read again on later scans, so that keeping contents fresh is cheap.
49. As a user, I want content of deleted files to disappear from results, so that I don't chase files that no longer exist.
50. As a user, I want reading to pause when a share disconnects and continue where it left off when it reconnects or the app restarts, so that no work is lost.
51. As a user, I want to see content-reading progress (e.g. "Reading contents… 1,234 of 10,400") in the panel, the menu and Settings, so that I know how complete content search is.
52. As a user, I want to turn content search, each file type, and OCR on or off in Settings, so that I control what is read.
53. As a user, I want files that couldn't be read (damaged, password-protected) to be skipped without stopping the rest.
54. As a user, I want the text of Excel workbooks (.xlsx) to be searchable. *(added later: #20)*
55. As a user, I want the text of older Excel workbooks (.xls) to be searchable. *(added later: #21)*
56. As a user, I want text in pictures (photos and scans saved as .jpg, .png, .heic or .tiff) to be recognized, so that photographed documents are searchable too. *(added later: #22)*

## Implementation Decisions

- **TextExtractor** (deep module) — `text(of fileURL, type) throws -> Extraction` where `Extraction` is `.text(String)`, `.needsOCR` (a PDF with no text layer) or `.unsupported`. PDF via PDFKit; Word/RTF via `NSAttributedString` document readers; PowerPoint by reading the slide XML inside the .pptx archive; Excel by reading the shared strings and inline strings inside the .xlsx archive, and the shared string table and label records of an Excel 97–2003 .xls (a Compound File read by a small built-in reader; .xls files that are really exported web pages are read as HTML); numbers and formulas aren't read; pictures go straight to `.needsOCR` without being opened; text/CSV/XML by decoding UTF-8 with a Windows-1252 fallback (files from a Windows server), stripping XML tags. Stored text is capped (~500k characters per file) to bound the index size.
- **OCRReader** — renders each page of a text-less PDF, or decodes a picture with ImageIO (turned upright, every page of a multi-page TIFF), and runs Vision text recognition (`VNRecognizeTextRequest`, accurate, languages es + en). A separate, lower-priority pass after normal text reading; can be turned off in Settings.
- **ContentStore** (inside the existing SQLite index) — an FTS5 table of document text using the `unicode61 remove_diacritics 2` tokenizer (word-based, much smaller than trigram), plus a per-file state table (share, path, size, modified date, outcome: indexed / no text / needs OCR / too big / failed). Interface: list files that need reading (new or changed since last read, of enabled types, under the size limit), store text or an outcome, drop state for files that no longer exist, and `searchContent(Query, limit) -> [ContentResult]` returning a preview snippet via FTS5 `snippet()`. Terms are matched as word prefixes; the extension filter applies.
- **ContentIndexer** — runs after each successful name scan of a folder: reads candidates one by one at utility priority, stores results file by file (so it resumes after a restart or disconnect), stops when the share unmounts, and reports progress to the model. Never writes to the server.
- **UI** — "Inside files" section in the search panel with preview lines; progress in the panel footer, the menu bar menu and Settings; a **Contents** settings tab with content search on/off, file types, OCR on/off, and the size limit (default 20 MB).

## Testing Decisions

- **TextExtractor**: fixture documents generated in the tests (text, CSV, XML, RTF/Word written with `NSAttributedString`, PDF drawn with Core Graphics, a minimal .pptx archive, an .xlsx with shared and inline strings, .xls files built byte by byte in the tests) — the expected words come out; accents preserved; a PDF without text reports `.needsOCR`; a damaged file throws.
- **ContentStore**: against a temporary database — finds documents by words and word prefixes, ignoring case and accents; requires all words; applies the extension filter; snippet contains the words; changed files are listed again and unchanged ones aren't; deleted files' content is removed; files above the size limit are not listed.
- **OCRReader**: a test PDF made from an image of text is recognized (Spanish and English sample); so are a PNG, every page of a two-page TIFF and a sideways JPEG; tiny pictures have no text; damaged ones throw.
- ContentIndexer scheduling and UI: manual testing on the real shares, including timing the first full read.

## Out of Scope

- Excel 95 and older workbooks (.xls saved before Excel 97). (Excel 97–2003 .xls was added in #21, .xlsx in #20.)
- Audio and video. (Pictures were added in #22.)
- Searching for exact phrases or with operators (OR, NOT) — every word must appear, in any order.
- Reading files larger than 20 MB by default.

## Privacy

- **Never read the contents of**: a second pattern list (defaults `*contraseña*`, `*contrasena*`, `*password*`, `*passwd*`, `*clave*`). Matching files stay findable by name, but their text is never read or stored; text already stored is deleted as soon as a pattern is added, and at every launch.

