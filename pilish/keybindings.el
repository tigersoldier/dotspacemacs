;;; keybindings.el --- pilish layer keybindings for Spacemacs. -*- lexical-binding: t; -*-
;;
;; Leader-key access to the pi coding agent. Global bindings live
;; under `SPC a i' (applications -> ai/pi); within the package's own
;; chat/input buffers, `SPC m p' mirrors the most useful actions on
;; the major-mode leader, and the `, c' / `, s' / `, t' / `, e'
;; bindings run pi commands, skills, templates, and extensions
;; directly.
;;
;; Note: `SPC a p' cannot be used — it is already bound to
;; `list-processes' in Spacemacs.
;;
;;; License: GPLv3

;;; Code:

;; Referenced from the C-<return> binding below; defined by the package
;; at load time (see the with-eval-after-load block).
(defvar pilish-input-mode-map)
(declare-function pilish-send "pilish-input")

(spacemacs/declare-prefix "ai" "pilish")
(spacemacs/set-leader-keys
  "aip" 'pilish                    ; start or focus session
  "aii" 'pilish/switch-session     ; list sessions: local live, per-host remote, then closed
  "aiI" 'pilish/switch-session-in-dir ; switch current dir's sessions
  "aiS" 'pilish/open-named-session ; start named session
  "aiw" 'pilish/new-worktree-session ; worktree from a repo + session
  "aiW" 'pilish/new-workspace-session ; workspace of worktrees + session
  "ail" 'pilish/layout             ; apply window layout
  "ain" 'pilish/start-new-session  ; new session (always asks dir)
  "aiN" 'pilish-new-session        ; reset / new session (current dir)
  "aim" 'pilish/start-remote-session ; new session on an ssh-config host (TRAMP)
  "aid" 'pilish/close-session      ; close session + kill its buffers
  "aiD" 'pilish/delete-session     ; delete (prompts; default = current)
  "air" 'pilish-reload             ; restart pi process
  "ais" 'pilish-open-session-file  ; open a JSONL session file
  "ait" 'pilish-toggle             ; show/hide session windows
  "aig" 'pilish-install-grammars   ; tree-sitter grammar status
  "ai?" 'pilish-menu               ; full transient menu
  )

(spacemacs/declare-prefix-for-mode 'pilish-chat-mode "mp" "pi")
(spacemacs/declare-prefix-for-mode 'pilish-input-mode "mp" "pi")

(spacemacs/set-leader-keys-for-major-mode 'pilish-chat-mode
  "p" 'pilish-menu
  "P" 'pilish/open-named-session
  "i" 'pilish/switch-session
  "I" 'pilish/switch-session-in-dir
  "n" 'pilish-new-session
  "m" 'pilish/start-remote-session ; new session on an ssh-config host (TRAMP)
  "r" 'pilish-reload
  "t" 'pilish-toggle
  "c" 'pilish-run-command
  "s" 'pilish-skills-menu
  "T" 'pilish-templates-menu ; t is toggle in chat; templates on T
  "e" 'pilish-extensions-menu)

(spacemacs/set-leader-keys-for-major-mode 'pilish-input-mode
  "p" 'pilish-menu
  "P" 'pilish/open-named-session
  "i" 'pilish/switch-session
  "I" 'pilish/switch-session-in-dir
  "m" 'pilish/start-remote-session ; new session on an ssh-config host (TRAMP)
  "c" 'pilish-run-command
  "s" 'pilish-skills-menu
  "t" 'pilish-templates-menu
  "e" 'pilish-extensions-menu)

;; C-<return> submits the prompt, matching Ctrl+Enter in other coding
;; agents.  The package's own send binding (C-c C-c) and the Evil
;; normal-state RET keep working; RET in Evil insert state (the
;; default input state) stays a literal newline so multi-line prompts
;; remain possible.  The input mode map is defined by the package at
;; load time, so the binding is installed after pilish loads.
(with-eval-after-load 'pilish
  (define-key pilish-input-mode-map
              (kbd "C-<return>") #'pilish-send))

;;; keybindings.el ends here
