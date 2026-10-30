# Prototype → code map

Figma file `GrvVYMZQvBs11vwtYNfYvH`, Prototype page `1:10` (120 Khmer screens; English via the Typography mode switch).
Build each screen against its **Regular 1280×900** frame, then check Compact (C-), Large (L-), Wide (W-) and Desktop (D-, 1512×982 with menu bar).

## Window shell — done (scaffold)

| Figma | Swift | Status |
| --- | --- | --- |
| Title Bar 102:39 (44) | `TitleBarView` | Layout done; traffic-light alignment differs (see gaps) |
| Toolbar 103:776 Full/Compact (50) | `ToolbarView` | Done; Compact shows sidebar toggle |
| Workspace Tabs 98:331 (44) | `WorkspaceTabBar` | Done |
| Sidebar 105:115 Pages | `PageSidebarView` | Placeholder thumbnails; PDFKit next |
| Document Canvas 109:197, Page Navigation 107:120 | `DocumentCanvasPlaceholder`, `PageNavigationPill` | Placeholder page; PDFKit `PDFView` next |
| Inspector Panel 159:554 (Read) | `ReadInspectorView` | Done (static) |
| Status Bar 101:82, Theme Switch 179:606, Language Switch 179:633 (36) | `StatusBarView`, `ThemeSwitch`, `LanguageSwitch` | Done and live |
| Responsive page 1:6 | `WindowSizeClass` (1024/1280/1440/1920; sidebar –/120/140/160, inspector 280/296/320/360) | Done |

Reference renders: `Tools/render_snapshots.sh` → compare with "KM · 01 Read" (164:6246).

## Screens (Regular · Desktop IDs)

| # | Screen | Workspace / presentation | Main components |
| --- | --- | --- | --- |
| 01 · D-01 | Read | Read workspace | Inspector (search, select/copy, rotate, OCR prompt) |
| 24 · D-24 | Read · search results | Read | Search Results Panel 142:87, Search Result 142:86 |
| 02 · D-02 | Organize pages | Organize workspace | Page Organizer 110:350, Organize Panel 110:351, Drop Indicator |
| 19–23 | Merge PDFs, Delete pages?, Split, New PDF saved, Pages deleted | Dialogs/toasts over Organize | Merge PDFs Sheet 145:98, File List Item, Dialog 135:230 Delete pages, Toast 143:68 |
| 03 · D-03 | Annotate | Annotate workspace | Annotate Tools 125:135, Added Text Box 125:23, Highlight 125:26, Comment Pin/Card 122:*, Text Properties Panel 123:292 |
| 04 · D-04 | Khmer OCR review | OCR workspace, side-by-side canvas | OCR Review Panel 129:111, Uncertain Region 129:14, Recognition Settings 129:231 |
| 12, 39, 41 | Recognizing…, Recognize again?, invalid page range | Progress dialog / confirm / field error | Dialog Progress, Progress Bar 100:74, Text Field Error |
| 05–09 (+a) | Export Word / Excel / Word+Excel / Searchable PDF / Plain text, format menu | Export workspace | Export Options 132:409, Format Suggestion 132:36, Export Preview 133:399, Table Editor 131:*, Review Issue 133:44 |
| 17, 18, 36, 37, 38, 40, 14 | No tables, Export finished, File exists, Exporting…, partial success, pages changed, could not save | Dialogs/toasts/banners | Dialog, Toast, Banner 141:101 |
| 11, 44, 35, 13, 15, 16, 42, 43 | Open a document, drag over, invalid PDF, password, recovered work, save before closing, save work, work saved | Start screen + dialogs | File Drop Zone 134:46, Recent File 134:94, Dialog (Password/Recovery/Save changes), Toast |
| 10, 10k–10o | Preferences, Keyboard Shortcuts, add shortcut states | Fixed 656×711 card | Setting Row 140:37, Switch 140:36, Dropdown 94:74, Keyboard Shortcuts Panel 251:284, Add Shortcut Sheet 251:935 |
| 25, 26 | Print, Printing… | Print Sheet 188:179 | — |
| D-27–D-34a | About, Shortcuts, Privacy & Licenses, Help, Developer, Release Notes, Report a Problem, Send Feedback | Secondary windows (see gaps) | About Window 146:343, Help Window 198:990, Developer/Release/Report/Feedback Windows |

## Component library → Swift

Done: `DSButton` (Button 86:390), `DSIconButton` (86:511), `DSSearchField` (142:76), `LanguageSwitch`, `ThemeSwitch`, `DSDivider`, `DSIcon` (all 70 Figma icons).
Next, in roughly the order screens need them: Tab 98:64 (segmented), Text Field 93:186, Dropdown/Menu 94:*, Checkbox/Radio 95:*, Switch 140:36, Badge 89:32, Tooltip 91:30, Toast 143:68, Banner 141:101, Dialog 135:230, Progress Bar/Spinner 100:*, Empty State 144:74, Page Thumbnail 104:113, Panel Header/Resize Handle 105:4/159:411, then the feature components (Page Organizer, Annotate, OCR Review, Table Editor, Export).
Before building each one, read its variants with `get_design_context` and match sizes, paddings and states exactly; the shell's button heights and paddings were set by eye from screenshots and still need that check.
