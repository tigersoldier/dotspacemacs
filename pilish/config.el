;;; config.el --- pilish layer configuration for Spacemacs. -*- lexical-binding: t; -*-
;;
;; Layer-level configuration for the `pilish' Emacs frontend.
;; Package options (`pilish-evil-integration',
;; `pilish-project-trust-policy', ...) are set in the package's
;; init function in `packages.el'; this file only handles things that
;; belong to the layer itself.
;;
;;; License: GPLv3

;;; Code:

;; Read by `packages.el' while it declares the package, before this file
;; is loaded; the gitignored `local/config.el' is what actually sets it.
(defcustom pilish/use-local-checkout nil
  "Whether to load pilish from the local checkout in `local/pilish'.
When non-nil the checkout symlinked there must contain `pilish.el';
the layer then loads it with `:location local' and installs no
package.  Otherwise `packages.el' installs the fork's `downstream'
branch with quelpa.

Set this in the gitignored `local/config.el', not in the tracked
dotfile: `packages.el' reads the flag while declaring packages, which
happens before this file (and the rest of the layer) is loaded."
  :type 'boolean
  :group 'pilish)

(defcustom pilish/layout-width-ratio 0.5
  "Fraction of the frame width taken by the pi left column (chat + input).
Used by `pilish/layout' when applying the window layout; the
right edit window takes the remaining width.  Must be between 0 and 1."
  :type 'number
  :group 'pilish)

(defcustom pilish/workspace-root "~/work"
  "Root directory for worktree and workspace sessions.

`pilish/new-worktree-session' (SPC a i w) creates worktrees
directly under this directory; `pilish/new-workspace-session'
(SPC a i W) creates one subdirectory per workspace, holding the
worktrees under its `repos' subdirectory.  Created on demand when it
does not exist yet."
  :type 'directory
  :group 'pilish)

(defcustom pilish/repo-roots '("~/code")
  "Directories scanned one level deep for git repos.

The repos found here — plus `projectile-known-projects' when
projectile is loaded, plus the current context directory — are
offered as candidates by the git repo pickers of
`pilish/new-worktree-session' (SPC a i w) and
`pilish/new-workspace-session' (SPC a i W).  Any directory
can still be typed in directly; only the quick-pick candidates come
from these roots."
  :type '(repeat directory)
  :group 'pilish)

(defcustom pilish/repo-mark-key "C-;"
  "Key that marks/unmarks a candidate in the pi repo pickers.
`helm-map' binds C-SPC/C-@ to marking, which commonly conflicts with
input method activation keys; the pickers unbind those and mark with
this key instead (C-; is deliberately undefined in `helm-map')."
  :type 'key-sequence
  :group 'pilish)

;; Make sure Emacs can find the `pi' binary (also adds it to PATH for
;; pi's own shell tool calls). No-op if `pi' is already on exec-path.
(pilish//add-pi-to-exec-path)

;; ---------------------------------------------------------------------
;; window-purpose integration
;;
;; The layer ships a window layout (pilish.window-layout) with
;; dedicated chat/input windows and a free window for any buffer.  The
;; layout directory is registered below, and the package's modes are
;; mapped to the layout's purposes so buffers are routed to the right
;; windows.  These defcustoms may not be bound yet (the dotfile's
;; custom-set-variables block runs before window-purpose is loaded and
;; skips undeclared variables), so declare them here before touching
;; them — `defvar' keeps an existing value if the dotfile already set
;; one.

(defvar purpose-layout-dirs nil
  "List of directories containing purpose window layout files.")

(defvar purpose-user-mode-purposes nil
  "Alist mapping major modes to window purposes.")

(add-to-list 'purpose-layout-dirs pilish--dir)

;; Re-assert the mode->purpose mappings and recompile the purpose
;; hash tables once window-purpose is loaded (purpose-mode is turned on
;; by the spacemacs-purpose layer, which runs after this file loads).
(add-hook 'purpose-mode-hook #'pilish//ensure-purpose-config)

;; ---------------------------------------------------------------------
;; Emacs bridge (pi sessions driving Emacs)
;;
;; The layer's pi-bridge-extension.ts adds tools to every pi session
;; started by this Emacs (wired in packages.el through
;; `pilish-extra-args').  The tools talk to Emacs via
;; `emacsclient -e', which requires an Emacs server; when the bridge
;; is enabled the layer ensures one is running at startup.  The server
;; socket path is exported to pi processes as PI_EMACS_SERVER (see the
;; advice in `pilish//install-package-advices'), so
;; emacsclient targets exactly this Emacs instance — safe with
;; daemons or several Emacs running.

(defcustom pilish/enable-bridge t
  "When non-nil, let pi sessions started by this Emacs drive Emacs.
Ensures an Emacs server (emacsclient channel) and adds the pi bridge
extension to every pi command, providing tools such as
`emacs_new_session' (open a new session in another directory, creating
its perspective and switching to it)."
  :type 'boolean
  :group 'pilish)

(when (and pilish/enable-bridge
           (not noninteractive)
           (not (daemonp)))
  (require 'server)
  (unless (server-running-p)
    (server-start)))

;;; config.el ends here
