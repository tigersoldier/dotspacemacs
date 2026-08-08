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

;;; config.el ends here
