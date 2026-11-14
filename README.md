# NiceBrowser

A full replacement for the KOReader library view – tuned for a Calibre ePub
library, with **performance as the top priority** and a **minimalist, modern
design**.

## Features

- **Tabbed navigation:** Authors (default), Genres, Tags – with drill-down all
  the way to the book list.
- **Book row view:** cover, title, series + volume, year, page count and a
  progress bar (length = page count, fill = reading progress) in tidy rows.
- **Calibre metadata:** read automatically from each EPUB's OPF (author,
  genre, tags, series, year, page count, read status).
- **Powerful search** (author + title, current level or whole library) with
  an **A–Z register**.
- **Index-based & fast:** SQLite index, cover thumbnails, lazy rendering, no
  animations – smooth even on low-end eInk hardware.
- **Customisable theme:** **SourceSerif4** (serif) as the default font,
  **SourceSans3** (sans-serif) as the alternative; colour mode switchable
  between greyscale (default) / colour / black & white.
- **Configurable:** double-tap option, sorting, density settings; optionally
  replaces the home screen on start.

## Getting started

1. Put the plugin into KOReader's `plugins/` folder.
2. Enable NiceBrowser in KOReader's plugin menu.
3. The bundled fonts (**SourceSerif4**, **SourceSans3**) are installed
   automatically into KOReader's `fonts/` directory on first start (if not
   present yet). A **restart of KOReader** after installation makes sure the
   fonts are picked up.
4. On first launch, NiceBrowser offers to scan the library folder (the first
   KOReader library path) whenever the index is still empty. The index menu
   in the top bar provides a full scan, an update for new books only, and
   cover-cache maintenance.

## Documentation

- **[SPEC.md](SPEC.md)** – full specification (requirements, design,
  performance, settings).
- **[IMPLEMENTATION.md](IMPLEMENTATION.md)** – implementation plan (phases,
  modules, acceptance criteria).
- **[VALIDATION.md](VALIDATION.md)** – test guide (emulator, busted suites)
  and a log of the defects found and fixed.

## License

NiceBrowser is licensed under the **GNU AGPL v3** (see [LICENSE](LICENSE)),
matching KOReader. The bundled fonts **SourceSerif4** and **SourceSans3** are
licensed under the **SIL Open Font License** (OFL); they are installed
automatically into KOReader's `fonts/` directory when needed.

### SIL Open Font License (OFL) – notice

The SourceSerif4 and SourceSans3 fonts come from
[Adobe Fonts](https://github.com/adobe-fonts) and are licensed under the
[SIL Open Font License 1.1](https://openfontlicense.org). They may be used,
modified and redistributed freely as long as the license and copyright
notices are kept intact. The full license is available at
<https://openfontlicense.org>.
