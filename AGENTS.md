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
  `pi-coding-agent/remote-executables`). Edit those sections carefully and
  expect the running Emacs to re-save the file and race hand edits.
- `pi-coding-agent/` — the largest and most active custom layer. Wraps the
  `pi-coding-agent` MELPA package (the pi coding agent's Emacs frontend).
  Requires Emacs 29.1+ (tree-sitter) and the `pi` CLI.
- Other layers: `my-persp/`, `markdown-it/` (its preview shells out to
  `render.cjs`), `myconfigs/`, `bazel/`, `templates/` (yasnippet),
  `layouts/` (window-purpose layouts), `snippets/`.
- Installed packages live in `~/.emacs.d/elpa/develop/<pkg>-<version>/` —
  **outside this repo**; never add package sources here. The `javacomp`
  entries in `.gitmodules` are stale (layer removed).

## Spacemacs layer file conventions

Each layer directory follows the standard split:

- `layers.el` — `configuration-layer/declare-layer-dependencies`
- `packages.el` — `configuration-layer/package` declarations + package
  init customization
- `config.el` — layer defcustoms and configuration
- `funcs.el` — all command/helper functions
- `keybindings.el` — spacemacs leader/mode-leader bindings

Style: `lexical-binding: t`, one-sentence first docstring line, and comments
that explain **why** (several files carry long rationale records, e.g. why a
TRAMP workaround exists — preserve them when refactoring). Declared-but-
unbound variables (e.g. `tramp-connection-timeout`,
`pi-coding-agent-executable`) must keep their `defvar` declarations at the
top of `funcs.el`: with lexical binding, byte-compiled dynamic rebinding of
undeclared variables silently does nothing.

## pi-coding-agent layer specifics

- `DESIGN.org` records numbered decision sections (D6 session state
  machine, D14 remote/TRAMP sessions, D15 session-list scope …). Add a new
  decision section there for architectural changes; keep it honest about
  rejected alternatives.
- Session identity flows through the registry
  (`pi-coding-agent//registry`) keyed by perspective name; the live/closed
  session lists derive from active chat buffers, not the registry.
- **Command references**: the user writes layer commands as `a i <key>` —
  the leader sequence `SPC a i <key>` defined in `keybindings.el`
  (mirrored on `SPC m p <key>` inside pi chat/input buffers). When a
  request says "`a i i` hangs" or "make `a i m` …", resolve the key
  through that table:

  | key | command |
  |-----|---------|
  | `a i p` | `pi-coding-agent` (start or focus session) |
  | `a i i` | `pi-coding-agent/switch-session` (list sessions) |
  | `a i I` | `pi-coding-agent/switch-session-in-dir` |
  | `a i S` | `pi-coding-agent/open-named-session` |
  | `a i w` / `a i W` | `…/new-worktree-session` / `…/new-workspace-session` |
  | `a i n` / `a i N` | `…/start-new-session` / `pi-coding-agent-new-session` |
  | `a i m` | `pi-coding-agent/start-remote-session` (TRAMP/ssh host) |
  | `a i d` / `a i D` | `…/close-session` / `…/delete-session` |
  | `a i r` | `pi-coding-agent-reload` (restart pi process) |
  | `a i s` | `pi-coding-agent-open-session-file` |
  | `a i t` | `pi-coding-agent/toggle` (show/hide windows) |
  | `a i l` | `pi-coding-agent/layout` |
  | `a i g` | `pi-coding-agent-install-grammars` |
  | `a i ?` | `pi-coding-agent-menu` (transient menu) |

  `keybindings.el` is the source of truth; keep it in sync when adding
  commands.
- **Remote (TRAMP) rule**: never start remote file I/O from a listing or
  picker unless the TRAMP connection is already established
  (`pi-coding-agent//tramp-connection-alive-p`). TRAMP's own timeouts do
  not fire inside its wait loop, so an unreachable host hangs Emacs
  forever; use the bounded ssh probe
  (`pi-coding-agent//remote-host-probe` / `//remote-probe-async`)
  instead. See D14/D15 in DESIGN.org.

## Verifying changes

No CI. Before committing Elisp changes, byte-compile and compare warnings
against the baseline (many "function not known to be defined" warnings are
expected — functions resolve at runtime inside Spacemacs):

```sh
emacs --batch -Q -L . \
  -L ~/.emacs.d/elpa/develop/<package-dir> \
  --eval '(progn (setq byte-compile-warnings (quote (not free-vars unresolved-obsolete)))
                 (byte-compile-file "pi-coding-agent/funcs.el"))'
```

Check for read/syntax errors and *new* warnings only. `*.elc` is
gitignored — delete it after compiling. For behavioral checks, a headless
`emacs --batch -l test.el` harness with stubs for the package functions and
persp-mode works well (see the remote-scope work in git history for the
pattern). Reload the running config with `SPC f e R` after layer edits.

## Commit style

Imperative subject line, prefixed for layer work: `pi-coding-agent: <what
changed>` (e.g. "pi-coding-agent: fail open when deleting a session whose
directory is gone"). Body optional; explain non-obvious whys.
