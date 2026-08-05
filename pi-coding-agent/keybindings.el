;;; keybindings.el --- pi-coding-agent layer keybindings for Spacemacs.
;;
;; Leader-key access to the pi coding agent. Global bindings live
;; under `SPC a i' (applications -> ai/pi); within the package's own
;; chat/input buffers, `SPC m p' mirrors the most useful actions on
;; the major-mode leader.
;;
;; Note: `SPC a p' cannot be used — it is already bound to
;; `list-processes' in Spacemacs.
;;
;;; License: GPLv3

;;; Code:

(spacemacs/declare-prefix "ai" "pi-coding-agent")
(spacemacs/set-leader-keys
  "aip" 'pi-coding-agent                    ; start or focus session
  "aiS" 'pi-coding-agent/open-named-session ; start named session
  "ail" 'pi-coding-agent/layout             ; apply saved window layout
  "ain" 'pi-coding-agent-new-session        ; reset / new session
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
  "n" 'pi-coding-agent-new-session
  "r" 'pi-coding-agent-reload
  "t" 'pi-coding-agent-toggle)

(spacemacs/set-leader-keys-for-major-mode 'pi-coding-agent-input-mode
  "p" 'pi-coding-agent-menu
  "P" 'pi-coding-agent/open-named-session)

;;; keybindings.el ends here
