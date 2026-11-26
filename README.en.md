# org-flow-table

Renders Org tables as responsive, pixel-aligned widgets inside ordinary Org
buffers. It needs nothing but Emacs and Org: cells are measured with
`window-text-pixel-size`, laid out by this package, and drawn with overlays.

## Upstream project

This project was previously `org-table-widget` (originally by
[yibie](https://github.com/yibie)), which laid tables out with
[TextUI](https://github.com/yibie/textui).

## Why the rename

As of 0.4.0 the TextUI dependency is gone: tables are measured and laid out by
this package on Emacs alone, so it is no longer a "TextUI widget". The old name
carried the upstream name and pointed at a repository path that never existed;
`org-flow-table` reflects the responsive wrapping and reflowing layout instead.

## Main differences from upstream

- **TextUI dependency removed**: `Package-Requires` lists only Emacs (29.1+) and
  Org (9.6+); no third-party library has to be installed or cloned, and nothing
  extra has to be added to `load-path`.
- **Keeps the Org source table's own look**: rows render as `| cell | cell |`
  and rules as `|---+---|`, with bold header rows and whole-row zebra striping;
  the drawn frame and Unicode box-drawing characters are gone.
- **Row-by-row rendering and in-place editing**: each row is drawn with its own
  overlay, and the row under point stays as source so it can be edited directly,
  with no key to press first; the other rows stay rendered while you type.
- **Sticky header and terminal rendering**: a scrolled-off table header can stay
  in the window's header line, and terminal rendering is optional
  (`org-flow-table-enable-in-terminal`).
- **Every public name uses the `org-flow-table-` prefix**: the library, mode,
  commands, options, and faces are renamed, with no aliases kept for the old names.

## Installation

Not on MELPA yet. Install with `package-vc`:

```elisp
(require 'package-vc)
(package-vc-install "https://github.com/TomoeMami/org-flow-table" "v0.4.0")
```

Or clone the repository and add its directory to `load-path` manually:

```elisp
(add-to-list 'load-path "/path/to/org-flow-table")
(require 'org-flow-table)
```
