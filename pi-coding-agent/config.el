;;; config.el --- pi-coding-agent layer configuration for Spacemacs.
;;
;; Layer-level configuration for the `pi-coding-agent' Emacs frontend.
;; Package options (`pi-coding-agent-evil-integration',
;; `pi-coding-agent-project-trust-policy', ...) are set in the package's
;; init function in `packages.el'; this file only handles things that
;; belong to the layer itself.
;;
;;; License: GPLv3

;;; Code:

(defcustom pi-coding-agent/layout-width-ratio 0.5
  "Fraction of the frame width taken by the pi left column (chat + input).
Used by `pi-coding-agent/layout' when applying the window layout; the
right edit pane takes the remaining width.  Must be between 0 and 1."
  :type 'number
  :group 'pi-coding-agent)

(defcustom pi-coding-agent/workspace-root "~/work"
  "Root directory for worktree and workspace sessions.

`pi-coding-agent/new-worktree-session' (SPC a i w) creates worktrees
directly under this directory; `pi-coding-agent/new-workspace-session'
(SPC a i W) creates one subdirectory per workspace, holding the
worktrees under its `repos' subdirectory.  Created on demand when it
does not exist yet."
  :type 'directory
  :group 'pi-coding-agent)

;; Make sure Emacs can find the `pi' binary (also adds it to PATH for
;; pi's own shell tool calls). No-op if `pi' is already on exec-path.
(pi-coding-agent//add-pi-to-exec-path)

;; ---------------------------------------------------------------------
;; window-purpose integration
;;
;; The layer ships a window layout (pi-coding-agent.window-layout) with
;; dedicated chat/input panes and a free pane for any buffer.  The
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

(add-to-list 'purpose-layout-dirs pi-coding-agent--dir)

;; Re-assert the mode->purpose mappings and recompile the purpose
;; hash tables once window-purpose is loaded (purpose-mode is turned on
;; by the spacemacs-purpose layer, which runs after this file loads).
(add-hook 'purpose-mode-hook #'pi-coding-agent//ensure-purpose-config)

;; ---------------------------------------------------------------------
;; Emacs bridge (pi sessions driving Emacs)
;;
;; The layer's pi-bridge-extension.ts adds tools to every pi session
;; started by this Emacs (wired in packages.el through
;; `pi-coding-agent-extra-args').  The tools talk to Emacs via
;; `emacsclient -e', which requires an Emacs server; when the bridge
;; is enabled the layer ensures one is running at startup.  The server
;; socket path is exported to pi processes as PI_EMACS_SERVER (see the
;; advice in `pi-coding-agent//install-package-advices'), so
;; emacsclient targets exactly this Emacs instance — safe with
;; daemons or several Emacs running.

(defcustom pi-coding-agent/enable-bridge t
  "When non-nil, let pi sessions started by this Emacs drive Emacs.
Ensures an Emacs server (emacsclient channel) and adds the pi bridge
extension to every pi command, providing tools such as
`emacs_new_session' (open a new session in another directory, creating
its perspective and switching to it)."
  :type 'boolean
  :group 'pi-coding-agent)

(when (and pi-coding-agent/enable-bridge
           (not noninteractive)
           (not (daemonp)))
  (require 'server)
  (unless (server-running-p)
    (server-start)))

;;; config.el ends here
