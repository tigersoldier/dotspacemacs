;;; funcs.el --- pi-coding-agent layer functions for Spacemacs.
;;
;; Small helpers that wire the `pi-coding-agent' Emacs frontend into
;; this Spacemacs setup. The heavy lifting (RPC process, rendering,
;; Evil keybindings, grammars) is all handled by the package itself.
;;
;;; License: GPLv3

;;; Code:

;; Absolute path to this layer's directory (resolved from funcs.el's
;; path). Used for the window layout file and PATH setup.
(defvar pi-coding-agent--dir
  (file-name-directory (or load-file-name buffer-file-name)))

(defun pi-coding-agent//add-pi-to-exec-path ()
  "Add directories containing the `pi' executable to `exec-path'.

GUI-launched Emacs may not inherit the interactive shell's PATH, so
the package's `executable-find' based dependency check could fail even
though `pi' works in a terminal.  Any directory found this way is also
appended to PATH for subprocesses spawned by Emacs (e.g. by pi itself
when it runs `bash' tool calls), so shell tool calls inside pi see the
same commands the user's shell does."
  (dolist (dir '("~/.local/bin" "~/bin" "/usr/local/bin"))
    (let ((expanded (expand-file-name dir)))
      (when (and (file-directory-p expanded)
                 (file-executable-p (expand-file-name "pi" expanded)))
        (unless (member expanded exec-path)
          (push expanded exec-path))
        (setenv "PATH" (mapconcat #'identity exec-path ":"))))))

(defun pi-coding-agent//ensure-purpose-config ()
  "Register the pi mode->purpose mappings and recompile purpose tables.

`purpose-buffer-purpose' consults the compiled hash tables built by
`purpose-compile-user-configuration' from the raw defcustoms, so
plain `add-to-list' on `purpose-user-mode-purposes' is not enough.
Runs from `purpose-mode-hook' once window-purpose is loaded, and
again from `pi-coding-agent/layout' — the hook does not re-fire when
layers are reloaded via `SPC f e R', which would leave the compiled
tables stale and the layout's buffer routing broken."
  (add-to-list 'purpose-user-mode-purposes
               '(pi-coding-agent-chat-mode . pi-chat))
  (add-to-list 'purpose-user-mode-purposes
               '(pi-coding-agent-input-mode . pi-input))
  (when (fboundp 'purpose-compile-user-configuration)
    (purpose-compile-user-configuration)))

(defun pi-coding-agent//non-dummy-buffers-with-purpose (purpose)
  "Return buffers with PURPOSE, excluding window-purpose dummy buffers.

`purpose-buffers-with-purpose' includes the placeholder buffers
window-purpose creates (e.g. `*pu-dummy-pi-chat*'), which are the
most recently created and therefore come first; they must not be
mistaken for real session buffers."
  (cl-remove-if (lambda (buf)
                  (string-prefix-p "*pu-dummy-" (buffer-name buf)))
                (purpose-buffers-with-purpose purpose)))

(defun pi-coding-agent/open-named-session (session)
  "Start or switch to a pi session named SESSION in the current project.

Unlike `pi-coding-agent' (which prompts for a name only with a prefix
arg), this always prompts, making multiple parallel sessions
convenient from a leader-key binding."
  (interactive "sSession name: ")
  (pi-coding-agent session))

(defun pi-coding-agent//most-recent-chat-buffer ()
  "Return the most recently used pi chat buffer, or nil."
  (cl-find-if (lambda (buf)
                (and (buffer-live-p buf)
                     (with-current-buffer buf
                       (derived-mode-p 'pi-coding-agent-chat-mode))))
              (buffer-list)))

(defun pi-coding-agent//live-session-buffers ()
  "Resolve the current session as (CHAT . INPUT), or nil.

Like `pi-coding-agent', prefers the session for the current directory
(project root).  If that lookup misses — e.g. directory/project
resolution differs from when the session was created — falls back to
the most recently used existing session instead of letting the layout
command spawn a second pi process.  Sessions whose process is dead are
not returned: `pi-coding-agent' should revive those.  Returns nil only
when no usable session exists at all."
  (let* ((dir (condition-case nil
                  (pi-coding-agent--session-directory)
                (error nil)))
         (chat (or (and dir (pi-coding-agent--find-session dir))
                   (pi-coding-agent//most-recent-chat-buffer))))
    (when chat
      (let ((proc (buffer-local-value 'pi-coding-agent--process chat)))
        (when (and (processp proc) (process-live-p proc))
          (cons chat (buffer-local-value 'pi-coding-agent--input-buffer chat)))))))

(defun pi-coding-agent//most-recent-non-pi-buffer ()
  "Return the most recently used buffer that is not a pi agent buffer.

Skips minibuffer and Emacs-internal (space-prefixed) buffers, window-
purpose dummy placeholders, and the pi chat/input buffers.  Used to
fill the layout's right pane when the buffer that was current before
the command cannot be restored there (e.g. the command was run from a
pi buffer)."
  (cl-find-if (lambda (buf)
                (let ((name (buffer-name buf)))
                  (and (buffer-live-p buf)
                       (not (minibufferp buf))
                       (not (string-prefix-p " " name))
                       (not (string-prefix-p "*pu-dummy-" name))
                       (not (with-current-buffer buf
                              (derived-mode-p 'pi-coding-agent-chat-mode
                                              'pi-coding-agent-input-mode))))))
              (buffer-list)))

(defun pi-coding-agent/layout ()
  "Start or focus a pi session and arrange it in the saved window layout.

Applies `pi-coding-agent.window-layout' (from this layer's directory):
chat buffer top-left, input buffer bottom-left, and a general-purpose
pane on the right that can hold any buffer.

The pi frontend uses raw `switch-to-buffer'/`split-window' calls, so
the session must be started first and the layout applied afterwards:
the purpose-based buffer routing in `purpose-set-window-layout' then
places the existing chat/input buffers into their dedicated windows."
  (interactive)
  (let ((saved-buffer (current-buffer))
        (session (pi-coding-agent//live-session-buffers)))
    ;; Recompile the purpose tables first: the layout's buffer routing
    ;; depends on them, and they can be stale (e.g. when layer files were
    ;; reloaded with `SPC f e R' after startup, the purpose-mode hook
    ;; that normally refreshes them never re-fires).
    (pi-coding-agent//ensure-purpose-config)
    ;; Reuse the existing session when there is one — never start a new
    ;; pi process just to arrange windows.  Only when no session exists
    ;; at all does `pi-coding-agent' create one.
    (unless session
      (pi-coding-agent))
    ;; Search the layer's own directory first (plus any other registered
    ;; layout dirs) — see `purpose-find-window-layout'.
    (purpose-load-window-layout
     "pi-coding-agent"
     (cons pi-coding-agent--dir purpose-layout-dirs))
    ;; Re-assert the session buffers in their panes and focus the input
    ;; window.  The purpose fill loop usually does this, but doing it
    ;; explicitly guarantees the panes show the current session's
    ;; buffers (and not dummy placeholders) regardless of fill-loop
    ;; timing.  Dummies are filtered out — see
    ;; `pi-coding-agent//non-dummy-buffers-with-purpose'.
    (let ((chat (or (car session)
                    (car (pi-coding-agent//non-dummy-buffers-with-purpose 'pi-chat))))
          (input (or (cdr session)
                     (car (pi-coding-agent//non-dummy-buffers-with-purpose 'pi-input)))))
      (dolist (w (window-list (selected-frame) nil (frame-first-window (selected-frame))))
        (cond ((eq (purpose-window-purpose w) 'pi-chat)
               (when chat (set-window-buffer w chat)))
              ((eq (purpose-window-purpose w) 'pi-input)
               (when input (set-window-buffer w input)))
              ;; Right (general) pane: restore the buffer the user was
              ;; looking at before this command replaced it.  When that
              ;; buffer is unusable (dead or one of the pi buffers),
              ;; show the most recently used non-pi buffer instead —
              ;; this also replaces the `*pu-dummy-general*'
              ;; placeholder window-purpose may have created when no
              ;; `general'-purpose buffer exists.
              ((eq (purpose-window-purpose w) 'general)
               (let ((cur-buf (window-buffer w)))
                 (cond ((and (buffer-live-p saved-buffer)
                             (not (eq cur-buf saved-buffer))
                             (not (with-current-buffer saved-buffer
                                    (derived-mode-p 'pi-coding-agent-chat-mode
                                                    'pi-coding-agent-input-mode))))
                        (set-window-buffer w saved-buffer))
                       ((not (eq cur-buf saved-buffer))
                        (when-let* ((recent (pi-coding-agent//most-recent-non-pi-buffer)))
                          (set-window-buffer w recent))))))))
      ;; Drop dummy placeholder buffers that are no longer displayed.
      (dolist (dummy '("*pu-dummy-general*" "*pu-dummy-pi-chat*"
                       "*pu-dummy-pi-input*"))
        (let ((buf (get-buffer dummy)))
          (when (and buf (not (get-buffer-window buf t)))
            (kill-buffer buf))))
      (when (and input (get-buffer-window input nil))
        (select-window (get-buffer-window input nil))))))

;;; funcs.el ends here
