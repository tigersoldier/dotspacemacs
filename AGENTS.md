# AGENTS.md

Guidance for coding agents working in this repository.

## What this repo is

Personal Spacemacs configuration — the **private directory** of a Spacemacs
install, cloned to `~/.emacs.d/private`. `init.el` is symlinked to
`~/.spacemacs` (see README.md for setup). It is synced across devices via
git; push straight to `origin/master` (no PR flow, no CI).

## Layout

- `init.el` — the dotspacemacs file. Mostly layer declarations
  (`dotspacemacs-configuration-layers`) and `custom-set-variables`.
  **`custom-set-variables` is machine-managed**: Emacs rewrites it on every
  `customize-save-variable` (some layer code saves state there, e.g.
  `pilish/remote-executables`). Edit those sections carefully and
  expect the running Emacs to re-save the file and race hand edits.
- `pilish/` — the largest and most active custom layer. Wraps the
  `pilish` Emacs frontend (the renamed `pi-coding-agent` package).
  The package is installed with quelpa from
  `tigersoldier/pi-coding-agent` branch `downstream` — never from MELPA.
  A development device opts into a local checkout by setting
  `pilish/use-local-checkout` in the gitignored
  `pilish/local/config.el` and symlinking the checkout to
  `pilish/local/pilish` (see `pilish/packages.el`).  Requires Emacs
  29.1+ (tree-sitter) and the `pi` CLI.
- Other layers: `my-persp/`, `markdown-it/` (its preview shells out to
  `render.cjs`), `myconfigs/`, `bazel/`, `templates/` (yasnippet),
  `layouts/` (window-purpose layouts), `snippets/`.
- Installed packages live in `~/.emacs.d/elpa/develop/<pkg>-<version>/` —
  **outside this repo**; never add package sources here.  `pilish` is the
  exception: it comes from the local checkout symlink, not from an ELPA
  directory.

## Spacemacs layer file conventions

Each layer directory follows the standard split:

- `layers.el` — `configuration-layer/declare-layer-dependencies`
- `packages.el` — `configuration-layer/package` declarations + package
  init customization
- `config.el` — layer defcustoms and configuration
- `funcs.el` — all command/helper functions
- `keybindings.el` — spacemacs leader/mode-leader bindings

Every `.el` file — including new ones — must set lexical binding on its
first line: `;;; <name>.el --- <description>. -*- lexical-binding: t; -*-`
(or `;; -*- lexical-binding: t; -*-` for `init.el`). This is what makes
byte-compilation and dynamic `defvar` rebinding behave correctly.

Style: `lexical-binding: t`, one-sentence first docstring line, and comments
that explain **why** (several files carry long rationale records, e.g. why a
TRAMP workaround exists — preserve them when refactoring). Declared-but-
unbound variables (e.g. `tramp-connection-timeout`,
`pilish-executable`) must keep their `defvar` declarations at the
top of `funcs.el`: with lexical binding, byte-compiled dynamic rebinding of
undeclared variables silently does nothing.

## pilish layer specifics

- `DESIGN.org` records numbered decision sections (D6 session state
  machine, D14 remote/TRAMP sessions, D15 session-list scope …). Add a new
  decision section there for architectural changes; keep it honest about
  rejected alternatives.
- Session identity flows through the registry
  (`pilish//registry`) keyed by perspective name; the live/closed
  session lists derive from active chat buffers, not the registry.
- **Command references**: the user writes layer commands as `a i <key>` —
  the leader sequence `SPC a i <key>` defined in `keybindings.el`
  (mirrored on `SPC m p <key>` inside pi chat/input buffers). When a
  request says "`a i i` hangs" or "make `a i m` …", resolve the key
  through that table:

  | key | command |
  |-----|---------|
  | `a i p` | `pilish` (start or focus session) |
  | `a i i` | `pilish/switch-session` (list sessions) |
  | `a i I` | `pilish/switch-session-in-dir` |
  | `a i S` | `pilish/open-named-session` |
  | `a i w` / `a i W` | `…/new-worktree-session` / `…/new-workspace-session` |
  | `a i n` / `a i N` | `…/start-new-session` / `pilish-new-session` |
  | `a i m` | `pilish/start-remote-session` (TRAMP/ssh host) |
  | `a i d` / `a i D` | `…/close-session` / `…/delete-session` |
  | `a i r` | `pilish-reload` (restart pi process) |
  | `a i s` | `pilish-open-session-file` |
  | `a i t` | `pilish/toggle` (show/hide windows) |
  | `a i l` | `pilish/layout` |
  | `a i g` | `pilish-install-grammars` |
  | `a i ?` | `pilish-menu` (transient menu) |

  `keybindings.el` is the source of truth; keep it in sync when adding
  commands.
- **Remote (TRAMP) rule**: never start remote file I/O from a listing or
  picker unless the TRAMP connection is already established
  (`pilish//tramp-connection-alive-p`). TRAMP's own timeouts do
  not fire inside its wait loop, so an unreachable host hangs Emacs
  forever; use the bounded ssh probe
  (`pilish//remote-host-probe` / `//remote-probe-async`)
  instead. See D14/D15 in DESIGN.org.

## Verifying changes

No CI. Before committing Elisp changes, byte-compile and compare warnings
against the baseline (many "function not known to be defined" warnings are
expected — functions resolve at runtime inside Spacemacs):

```sh
emacs --batch -Q -L . \
  -L ~/.emacs.d/private/pilish/local/pilish \
  --eval '(progn (setq byte-compile-warnings (quote (not free-vars unresolved-obsolete)))
                 (byte-compile-file "pilish/funcs.el"))'
```

Check for read/syntax errors and *new* warnings only. `*.elc` is
gitignored — delete it after compiling. For behavioral checks, a headless
`emacs --batch -l test.el` harness with stubs for the package functions and
persp-mode works well (see the remote-scope work in git history for the
pattern). Reload the running config with `SPC f e R` after layer edits.

## Commit style

Imperative subject line, prefixed for layer work: `pilish: <what
changed>` (e.g. "pilish: fail open when deleting a session whose
directory is gone"). Body optional; explain non-obvious whys.
