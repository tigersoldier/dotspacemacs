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
not returned: the launch path (`pi-coding-agent//launch-directory' +
`pi-coding-agent--setup-session') should revive those.  Returns nil
only when no usable session exists at all."
  (let* ((dir (condition-case nil
                  (pi-coding-agent--session-directory)
                (error nil)))
         (chat (or (and dir (pi-coding-agent--find-session dir))
                   (pi-coding-agent//most-recent-chat-buffer))))
    (when chat
      (let ((proc (buffer-local-value 'pi-coding-agent--process chat)))
        (when (and (processp proc) (process-live-p proc))
          (cons chat (buffer-local-value 'pi-coding-agent--input-buffer chat)))))))

(defun pi-coding-agent//terminal-buffer-p ()
  "Return non-nil when the current buffer is a terminal emulator.

Covers vterm, term/ansi-term (incl. multi-term), eshell and shell-mode
buffers — all of which keep `default-directory' in sync with the
shell's current working directory."
  (derived-mode-p 'vterm-mode 'term-mode 'eshell-mode 'shell-mode))

(defun pi-coding-agent//vterm-process-directory (proc)
  "Return vterm process PROC's real working directory, or nil.
Reads the `/proc/<pid>/cwd' symlink (Linux), which always reflects
the shell's actual directory regardless of whether the shell emits
OSC 7.  Returns nil on non-Linux systems or when the link is
unusable, letting the caller fall back to `default-directory'."
  (when-let* ((pid (and (processp proc) (process-id proc)))
              (dir (file-symlink-p (format "/proc/%d/cwd" pid)))
              (dir (file-name-as-directory dir))
              ((file-directory-p dir)))
    dir))

(defun pi-coding-agent//terminal-directory ()
  "Return the current terminal buffer's working directory, or nil.

Terminal modes keep the buffer's `default-directory' in sync with the
shell's cwd: term-mode via `term-command-hook'/`term-handle-ansi-\
terminal-message', shell-mode via dirtrack, eshell natively.  vterm,
however, only updates `default-directory' from OSC 7, which many
shells (e.g. plain zsh) never emit, leaving it stale; for vterm the
shell's real cwd is read from the process's `/proc/<pid>/cwd' symlink
instead.

When the real cwd cannot be determined — vterm without a readable
`/proc/<pid>/cwd', or a dead terminal process — the user is prompted
to choose the launch directory (`pi-coding-agent//read-launch-directory'),
defaulting to the buffer's `default-directory', rather than silently
using a possibly-stale directory.  Cancelling the prompt returns nil
and aborts the launch."
  (if-let* ((proc (get-buffer-process (current-buffer)))
            (_ (process-live-p proc)))
      (if (derived-mode-p 'vterm-mode)
          (or (pi-coding-agent//vterm-process-directory proc)
              (pi-coding-agent//read-launch-directory))
        (pi-coding-agent--route-preserving-expand-file-name default-directory))
    (pi-coding-agent//read-launch-directory)))

(defun pi-coding-agent//read-launch-directory ()
  "Prompt for the directory to launch a pi agent in.

Defaults to the current buffer's directory: the directory of the
visited file when there is one, else the buffer's `default-directory'."
  (let* ((default-dir (or (and buffer-file-name
                               (file-name-directory buffer-file-name))
                          default-directory))
         (dir (read-directory-name "Launch pi agent in directory: "
                                   default-dir default-dir t)))
    (pi-coding-agent--route-preserving-expand-file-name dir)))

(defun pi-coding-agent//launch-directory ()
  "Determine the directory for a new pi agent session.

Called only when no live session could be found.  Inside pi chat/input
buffers, uses the package's own session-directory logic (reviving the
session in its recorded directory); inside a terminal buffer, uses the
terminal's current working directory; elsewhere, prompts the user,
defaulting to the current buffer's directory."
  (cond
   ((derived-mode-p 'pi-coding-agent-chat-mode 'pi-coding-agent-input-mode)
    (pi-coding-agent--session-directory))
   ((pi-coding-agent//terminal-buffer-p)
    (pi-coding-agent//terminal-directory))
   (t
    (pi-coding-agent//read-launch-directory))))

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

(defun pi-coding-agent//window-layout-plist ()
  "Build the pi window layout from `pi-coding-agent/layout-width-ratio'.

Returns a window-purpose layout plist in the same format as
`pi-coding-agent.window-layout': chat buffer over input buffer on the
left, taking `pi-coding-agent/layout-width-ratio' of the frame width
(0.7 of the height for chat, 0.3 for input), and a general-purpose
`edit' pane on the right that can hold any buffer."
  (let* ((ratio (max 0.0 (min 1.0 pi-coding-agent/layout-width-ratio)))
         ;; Reference size for the root and left-column nodes: leaf
         ;; :width/:height are frame fractions, inner nodes are sized
         ;; from their :edges relative to the root's (see
         ;; `purpose--set-window-layout-1').
         (ref (list 0 0 100 100))
         (left (list 0 0 (* ratio 100) 100)))
    (list nil
          ref
          (list t left
                (list :purpose 'pi-chat :purpose-dedicated t
                      :width ratio :height 0.7
                      :edges (list 0.0 0.0 ratio 0.7))
                (list :purpose 'pi-input :purpose-dedicated t
                      :width ratio :height 0.3
                      :edges (list 0.0 ratio 0.7 1.0)))
          (list :purpose 'edit :purpose-dedicated nil
                :width (- 1.0 ratio) :height 1.0
                :edges (list ratio 0.0 1.0 1.0)))))

(defun pi-coding-agent/layout ()
  "Start or focus a pi session and arrange it in the pi window layout.

Applies the layout generated by `pi-coding-agent//window-layout-plist'
(chat buffer top-left, input buffer bottom-left, and a
general-purpose pane on the right that can hold any buffer); the left
column takes `pi-coding-agent/layout-width-ratio' of the frame width.

The pi frontend uses raw `switch-to-buffer'/`split-window' calls, so
the session must be started first and the layout applied afterwards:
the purpose-based buffer routing in `purpose-set-window-layout' then
places the existing chat/input buffers into their dedicated windows.

When no live session exists, a new one is launched in the directory
chosen by `pi-coding-agent//launch-directory': inside pi chat/input
buffers the session's recorded directory is reused (reviving a dead
process), inside a terminal buffer the terminal's current working
directory is used, and elsewhere the user is prompted, defaulting to
the current buffer's directory."
  (interactive)
  ;; The package is lazy-loaded via autoloads and the layer's init does
  ;; not require it, so in a fresh Emacs the `pi-coding-agent--*'
  ;; internals below may be undefined until an autoloaded command has
  ;; run.  Load it explicitly to avoid void-function errors on the
  ;; launch path.
  (unless (featurep 'pi-coding-agent)
    (require 'pi-coding-agent))
  (let ((saved-buffer (current-buffer))
        (session (pi-coding-agent//live-session-buffers)))
    ;; Recompile the purpose tables first: the layout's buffer routing
    ;; depends on them, and they can be stale (e.g. when layer files were
    ;; reloaded with `SPC f e R' after startup, the purpose-mode hook
    ;; that normally refreshes them never re-fires).
    (pi-coding-agent//ensure-purpose-config)
    ;; Reuse the existing session when there is one — never start a new
    ;; pi process just to arrange windows.  Only when no session exists
    ;; at all is a new one launched, in the directory chosen by
    ;; `pi-coding-agent//launch-directory' (the session's own directory
    ;; inside pi buffers, the terminal's cwd in terminal buffers, a user
    ;; prompt elsewhere).  `pi-coding-agent--setup-session' revives dead
    ;; sessions and reuses existing ones for the chosen directory.
    ;; Any error in the launch path is reported verbatim (not swallowed)
    ;; so the real failure surfaces in the minibuffer/*Messages*.
    (unless session
      (let ((dir (condition-case err
                     (pi-coding-agent//launch-directory)
                   (error
                    (user-error "pi-coding-agent/layout: %s"
                                (error-message-string err))))))
        (if (null dir)
            (user-error "pi-coding-agent/layout: no directory chosen")
          (condition-case err
              (let ((chat (pi-coding-agent--setup-session dir)))
                (setq session (cons chat
                                    (buffer-local-value
                                     'pi-coding-agent--input-buffer chat))))
            (error
             (user-error "pi-coding-agent/layout: %s"
                         (error-message-string err)))))))
    ;; Apply the generated layout (chat/input left, edit right); the
    ;; purpose-based buffer routing then places the existing chat/input
    ;; buffers into their dedicated windows.
    (purpose-set-window-layout (pi-coding-agent//window-layout-plist))
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
              ;; Right (edit) pane: restore the buffer the user was
              ;; looking at before this command replaced it.  When that
              ;; buffer is unusable (dead or one of the pi buffers),
              ;; show the most recently used non-pi buffer instead —
              ;; this also replaces the `*pu-dummy-edit*' placeholder
              ;; window-purpose may have created when no `edit'-purpose
              ;; buffer existed.
              ((eq (purpose-window-purpose w) 'edit)
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
      (dolist (dummy '("*pu-dummy-edit*" "*pu-dummy-pi-chat*"
                       "*pu-dummy-pi-input*"))
        (let ((buf (get-buffer dummy)))
          (when (and buf (not (get-buffer-window buf t)))
            (kill-buffer buf))))
      (when (and input (get-buffer-window input nil))
        (select-window (get-buffer-window input nil))))))

;;; funcs.el ends here
