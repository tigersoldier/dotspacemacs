;;; keybindings.el --- pi-coding-agent layer keybindings for Spacemacs.
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

(spacemacs/declare-prefix "ai" "pi-coding-agent")
(spacemacs/set-leader-keys
  "aip" 'pi-coding-agent                    ; start or focus session
  "aii" 'pi-coding-agent/switch-session     ; list sessions: open or switch
  "aiS" 'pi-coding-agent/open-named-session ; start named session
  "ail" 'pi-coding-agent/layout             ; apply window layout
  "ain" 'pi-coding-agent/start-new-session  ; new session (always asks dir)
  "aiN" 'pi-coding-agent-new-session        ; reset / new session (current dir)
  "aid" 'pi-coding-agent/close-session      ; close session + kill its buffers
  "air" 'pi-coding-agent-reload             ; restart pi process
  "ais" 'pi-coding-agent-open-session-file  ; open a JSONL session file
  "ait" 'pi-coding-agent-toggle             ; show/hide session windows
  "aig" 'pi-coding-agent-install-grammars   ; tree-sitter grammar status
  "aim" 'pi-coding-agent-menu               ; full transient menu
  )

(spacemacs/declare-prefix-for-mode 'pi-coding-agent-chat-mode "mp" "pi")
(spacemacs/declare-prefix-for-mode 'pi-coding-agent-input-mode "mp" "pi")

(spacemacs/set-leader-keys-for-major-mode 'pi-coding-agent-chat-mode
  "p" 'pi-coding-agent-menu
  "P" 'pi-coding-agent/open-named-session
  "i" 'pi-coding-agent/switch-session
  "n" 'pi-coding-agent-new-session
  "r" 'pi-coding-agent-reload
  "t" 'pi-coding-agent-toggle
  "c" 'pi-coding-agent-run-command
  "s" 'pi-coding-agent-skills-menu
  "T" 'pi-coding-agent-templates-menu ; t is toggle in chat; templates on T
  "e" 'pi-coding-agent-extensions-menu)

(spacemacs/set-leader-keys-for-major-mode 'pi-coding-agent-input-mode
  "p" 'pi-coding-agent-menu
  "P" 'pi-coding-agent/open-named-session
  "i" 'pi-coding-agent/switch-session
  "c" 'pi-coding-agent-run-command
  "s" 'pi-coding-agent-skills-menu
  "t" 'pi-coding-agent-templates-menu
  "e" 'pi-coding-agent-extensions-menu)

;;; keybindings.el ends here
