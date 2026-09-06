;;; funcs.el --- pi-coding-agent layer functions for Spacemacs. -*- lexical-binding: t; -*-
;;
;; Small helpers that wire the `pi-coding-agent' Emacs frontend into
;; this Spacemacs setup. The heavy lifting (RPC process, rendering,
;; Evil keybindings, grammars) is all handled by the package itself.
;;
;;; License: GPLv3

;;; Code:

;; Tramp connection variables that `pi-coding-agent/start-remote-session'
;; let-binds around its connection.  This file is byte-compiled with
;; `lexical-binding', and Tramp reads these variables dynamically deep
;; inside its connection code — without these declarations the byte
;; compiler would create lexical (ineffective) bindings for them.
(defvar tramp-connection-timeout)
(defvar tramp-connection-properties)
(defvar tramp-process-connection-type)
(defvar tramp-remote-path)
(defvar pi-coding-agent-executable)
;; Package variable read dynamically inside the package's spawn path
;; (`pi-coding-agent--pi-command'); the remote flow let-binds it (and
;; `pi-coding-agent--start-process' advice rebinds it) to drop local-only
;; `-e' extensions.  Same lexical-binding caveat as above.
(defvar pi-coding-agent-extra-args)
(declare-function tramp-make-tramp-file-name "tramp")

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

(defun pi-coding-agent//most-recent-non-pi-buffer (&optional restrict-to-persp)
  "Return the most recently used buffer that is not a pi agent buffer.

Skips minibuffer and Emacs-internal (space-prefixed) buffers, window-
purpose dummy placeholders, and the pi chat/input buffers.  When
RESTRICT-TO-PERSP is non-nil, only buffers of the current perspective
are considered.  Used to fill the layout's right pane when the buffer
that was current before the command cannot be restored there (e.g. the
command was run from a pi buffer)."
  (cl-find-if (lambda (buf)
                (let ((name (buffer-name buf)))
                  (and (buffer-live-p buf)
                       (not (minibufferp buf))
                       (not (string-prefix-p " " name))
                       (not (string-prefix-p "*pu-dummy-" name))
                       (not (with-current-buffer buf
                              (derived-mode-p 'pi-coding-agent-chat-mode
                                              'pi-coding-agent-input-mode)))
                       (or (not restrict-to-persp)
                           (and (bound-and-true-p persp-mode)
                                (persp-contain-buffer-p buf))))))
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
    (pi-coding-agent//apply-pi-layout (car session) (cdr session)
                                      saved-buffer nil)))

(defun pi-coding-agent//apply-pi-layout (chat input saved-buffer
                                              &optional restrict-to-persp)
  "Arrange the pi windows and focus the input buffer.

Applies the layout generated by `pi-coding-agent//window-layout-plist'
(chat buffer top-left, input buffer bottom-left, and a general-purpose
pane on the right that can hold any buffer); the left column takes
`pi-coding-agent/layout-width-ratio' of the frame width.  CHAT and INPUT
fall back to the current pi-chat/pi-input purpose buffers when nil.

SAVED-BUFFER is restored to the right (edit) pane when usable; when it
is a pi buffer or dead, the most recently used non-pi buffer is shown
instead — restricted to the current perspective when RESTRICT-TO-PERSP
is non-nil (used when opening a session into a fresh perspective, so
buffers from other workspaces never leak into the session).  The chat
and input panes are soft-dedicated to their buffers (the `side'
window-dedicated value the package itself uses for the input window),
so `display-buffer' never steals them; `switch-to-buffer' and `C-x o'
keep working."
  ;; Recompile the purpose tables first: the layout's buffer routing
  ;; depends on them, and they can be stale (e.g. when layer files were
  ;; reloaded with `SPC f e R' after startup, the purpose-mode hook
  ;; that normally refreshes them never re-fires).
  (pi-coding-agent//ensure-purpose-config)
  (purpose-set-window-layout (pi-coding-agent//window-layout-plist))
  ;; Re-assert the session buffers in their panes and focus the input
  ;; window.  The purpose fill loop usually does this, but doing it
  ;; explicitly guarantees the panes show the current session's
  ;; buffers (and not dummy placeholders) regardless of fill-loop
  ;; timing.  Dummies are filtered out — see
  ;; `pi-coding-agent//non-dummy-buffers-with-purpose'.
  (let ((chat (or chat
                  (car (pi-coding-agent//non-dummy-buffers-with-purpose 'pi-chat))))
        (input (or input
                   (car (pi-coding-agent//non-dummy-buffers-with-purpose 'pi-input)))))
    (dolist (w (window-list (selected-frame) nil (frame-first-window (selected-frame))))
      (cond ((eq (purpose-window-purpose w) 'pi-chat)
             (when chat
               (set-window-buffer w chat)
               ;; Soft-lock the pane to this session's chat buffer so
               ;; `display-buffer' never targets it (help, magit,
               ;; compilation, ...).  `side' is the soft form the package
               ;; itself uses for the input window: `set-window-buffer'
               ;; and `switch-to-buffer' still work, so re-applying the
               ;; layout and `C-x o' are unaffected.
               (set-window-dedicated-p w 'side)))
            ((eq (purpose-window-purpose w) 'pi-input)
             (when input
               (set-window-buffer w input)
               (set-window-dedicated-p w 'side)))
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
                      (when-let* ((recent (pi-coding-agent//most-recent-non-pi-buffer
                                           restrict-to-persp)))
                        (set-window-buffer w recent))))))))
    ;; Drop dummy placeholder buffers that are no longer displayed.
    (dolist (dummy '("*pu-dummy-edit*" "*pu-dummy-pi-chat*"
                     "*pu-dummy-pi-input*"))
      (let ((buf (get-buffer dummy)))
        (when (and buf (not (get-buffer-window buf t)))
          (kill-buffer buf))))
    (when (and input (get-buffer-window input nil))
      (select-window (get-buffer-window input nil)))))

;; ---------------------------------------------------------------------
;; Session management
;;
;; Each opened pi session is a persp-mode perspective (spacemacs-layouts
;; layer).  A registry maps perspective name -> session file plus buffer
;; specs captured through persp's own save/load dispatch.  See
;; DESIGN.org for the full decision record.

(defcustom pi-coding-agent/session-root "~/.pi/agent/sessions/"
  "Directory containing pi session JSONL files, organized by directory."
  :type 'directory
  :group 'pi-coding-agent)

(defun pi-coding-agent//session-root ()
  "Return the pi session root, following PI_AGENT_DIR when set.
pi resolves its agent directory from the PI_AGENT_DIR environment
variable; sessions then live under <PI_AGENT_DIR>/sessions instead of
the `pi-coding-agent/session-root' default, so the session scan follows
the same environment."
  (if-let* ((agent-dir (getenv "PI_AGENT_DIR"))
            ((not (string-empty-p agent-dir))))
      (expand-file-name "sessions" agent-dir)
    (expand-file-name pi-coding-agent/session-root)))

(defcustom pi-coding-agent/session-sort-opened 'dir-then-name
  "Sort order for live sessions in the switch-session list.
Live sessions are the active pi chat buffers.  `dir-then-name' sorts
by session directory, then by title (the default); `alpha' sorts by
title only, `chrono' by last modification (newest first)."
  :type '(choice (const :tag "Directory, then name" dir-then-name)
                 (const :tag "Alphabetical" alpha)
                 (const :tag "Chronological" chrono))
  :group 'pi-coding-agent)

(defcustom pi-coding-agent/session-sort-closed 'chrono
  "Sort order for closed sessions in the switch-session list.
`chrono' sorts by last modification, newest first (descending — the
default); `alpha' sorts by title (lexical)."
  :type '(choice (const :tag "Chronological (newest first)" chrono)
                 (const :tag "Alphabetical" alpha))
  :group 'pi-coding-agent)

(defcustom pi-coding-agent/ssh-config-file "~/.ssh/config"
  "SSH configuration file scanned for remote-host candidates.
`pi-coding-agent/start-remote-session' reads the plain (non-wildcard)
`Host' entries from this file — following `Include' directives — and
turns each into a TRAMP directory (/ssh:HOST:~)."
  :type 'file
  :group 'pi-coding-agent)

(defcustom pi-coding-agent/remote-executables nil
  "Per-host mapping of verified remote pi and node executables.
Alist of (HOST . (PI-PATH . NODE-PATH)): PI-PATH is the absolute
path of the pi binary on that remote host, NODE-PATH the node
binary that pi's shebang (`#!/usr/bin/env node') resolves through —
nil when node only needs to be found through PATH.  The mapping is
filled in automatically by `pi-coding-agent/start-remote-session'
once the executables have been located and verified working on the
host (the user is asked to locate them when the search fails), and
is consulted again on later sessions to skip the search.  Sessions
started through `pi-coding-agent/start-remote-session' — and every
remote spawn of `pi-coding-agent--start-process' (see
`pi-coding-agent//remote-spawn-start-process') — bind
`pi-coding-agent-executable' to a wrapper that exports NODE-PATH's
directory into the spawn PATH, making the pi spawn independent of
the remote PATH (both for finding pi and for resolving pi's
`#!/usr/bin/env node' shebang)."
  :type '(alist :key-type (string :tag "host")
                :value-type (cons (string :tag "pi executable")
                                  (choice (string :tag "node executable")
                                          (const :tag "found through PATH" nil))))
  :group 'pi-coding-agent)

(defcustom pi-coding-agent/remote-connect-timeout 20
  "Timeout in seconds for remote connections in
`pi-coding-agent/start-remote-session'.
Before opening TRAMP, the host is probed with an asynchronous `ssh'
that is hard-killed after this many seconds; this bounds failure
modes that TRAMP cannot, because TRAMP's wait loop suspends timer
dispatch (its timeouts never fire) whenever ssh stays alive but
silent — notably mDNS names (`.local') hanging in name-resolution
retries.  An ssh `ConnectTimeout' option is additionally added to
the TRAMP connection (and `tramp-connection-timeout' bound to the
same value), so an unreachable or unresponsive host fails with a
clear error instead of hanging on \"Opening connection ...\".  nil
keeps TRAMP's own defaults."
  :type '(choice (const :tag "TRAMP defaults" nil) natnum)
  :group 'pi-coding-agent)

(defvar pi-coding-agent//registry nil
  "Alist mapping perspective name to a session-entry plist.
Each entry is (PERSP-NAME . (:session-file FILE :label-locked BOOL
:buffers SPECS)).  SPECS are persp savelist specs captured through
`persp-save-buffer-functions'.")

(defvar pi-coding-agent//registry-file
  (expand-file-name "pi-coding-agent/registry.el" spacemacs-cache-directory)
  "File the session registry is persisted to (runtime state, not dotfiles).")

(defvar pi-coding-agent//session-cache (make-hash-table :test 'equal)
  "Cache of session-file -> (mtime . metadata plist).")

(defvar pi-coding-agent//renaming-self nil
  "Non-nil while this layer renames a perspective itself.")

(defvar pi-coding-agent-session-history nil
  "History of sessions selected by the pi session pickers.")

(defun pi-coding-agent//registry-load ()
  "Load the session registry from `pi-coding-agent//registry-file'.
Fail-open: any read/parse error yields an empty registry with a message."
  (setq pi-coding-agent//registry
        (condition-case err
            (let ((data (and (file-exists-p pi-coding-agent//registry-file)
                             (with-temp-buffer
                               (insert-file-contents pi-coding-agent//registry-file)
                               (ignore-errors (read (buffer-string)))))))
              (pcase data
                (`(pi-coding-agent-registry 1 ,entries)
                 (if (and (listp entries)
                          (cl-every (lambda (e)
                                      (and (consp e) (stringp (car e))
                                           (listp (cdr e))))
                                    entries))
                     entries
                   (message "pi: registry file ignored (unexpected format)")
                   nil))
                (_ nil)))
          (error
           (message "pi: registry file unreadable: %s"
                    (error-message-string err))
           nil))))

(defun pi-coding-agent//registry-save ()
  "Persist the session registry atomically (temp file + rename)."
  (condition-case err
      (let ((tmp (concat pi-coding-agent//registry-file ".tmp")))
        (make-directory (file-name-directory pi-coding-agent//registry-file) t)
        (with-temp-file tmp
          (prin1 (list 'pi-coding-agent-registry 1 pi-coding-agent//registry)
                 (current-buffer)))
        (rename-file tmp pi-coding-agent//registry-file t))
    (error
     (message "pi: failed to save registry: %s"
              (error-message-string err)))))

(defun pi-coding-agent//registry-put (persp-name &rest plist)
  "Add or update the registry entry for PERSP-NAME with PLIST."
  (let ((entry (assoc persp-name pi-coding-agent//registry)))
    (if entry
        (setcdr entry plist)
      (push (cons persp-name plist) pi-coding-agent//registry))))

(defun pi-coding-agent//registry-remove (persp-name)
  "Remove the registry entry for PERSP-NAME."
  (setq pi-coding-agent//registry
        (cl-delete-if (lambda (e) (equal (car e) persp-name))
                      pi-coding-agent//registry)))

(defun pi-coding-agent//registry-persp-name-for-file (file)
  "Return the perspective name registered for session FILE, or nil."
  (car (cl-find-if (lambda (e)
                     (equal (plist-get (cdr e) :session-file) file))
                   pi-coding-agent//registry)))

;; ---------------------------------------------------------------------
;; Perspective naming and label sync

(defun pi-coding-agent//truncate (string width)
  "Truncate STRING to WIDTH columns with an ellipsis."
  (if (> (length string) width)
      (truncate-string-to-width string width nil nil t)
    string))

(defun pi-coding-agent//session-file-cwd (file)
  "Return FILE's recorded cwd, or nil.
Remote (TRAMP) FILEs are only read over an already-established
connection (`pi-coding-agent//tramp-connection-alive-p', an I/O-free
check) — an unreachable host must never block a listing; nil is
returned then."
  (condition-case nil
      (and (or (not (pi-coding-agent--remote-prefix-for-path file))
               (pi-coding-agent//tramp-connection-alive-p file))
           (pi-coding-agent--session-file-cwd-or-error file))
    (error nil)))

(defun pi-coding-agent//file-uuid-prefix (file)
  "Return a short (8-char) uuid prefix for session FILE, or nil."
  (when (string-match "_\\([0-9a-f-]\\{8\\}\\)" file)
    (match-string 1 file)))

(defun pi-coding-agent//make-persp-label (title file)
  "Build a perspective label \"TITLE · abbrev-path\" for session FILE."
  (let ((abbrev (and file
                     (when-let* ((dir (pi-coding-agent//session-file-cwd file)))
                       (abbreviate-file-name (directory-file-name dir))))))
    (if abbrev
        (format "%s · %s" title abbrev)
      title)))

(defun pi-coding-agent//unique-persp-name (base &optional file)
  "Return BASE, uniquified with a short uuid/timestamp suffix on collision.
`persp-get-by-name-and-exists' returns an (EXISTS . PERSP) cons."
  (if (car (persp-get-by-name-and-exists base))
      (format "%s %s" base
              (or (and file (pi-coding-agent//file-uuid-prefix file))
                  (format-time-string "%H:%M:%S")))
    base))

(defun pi-coding-agent//rename-persp (old-name new-name)
  "Rename perspective OLD-NAME to NEW-NAME, updating the registry key."
  (when-let* ((persp (persp-get-by-name old-name))
              ((persp-p persp)))
    (let ((pi-coding-agent//renaming-self t))
      (persp-rename new-name persp))
    (pi-coding-agent//registry-save)))

(defun pi-coding-agent//on-persp-renamed (_persp old-name new-name)
  "Keep the registry key in sync when a pi perspective is renamed.
A rename not done by this layer (i.e. the user via SPC l r) locks the
label so the session title no longer auto-syncs to it."
  (when-let* ((entry (assoc old-name pi-coding-agent//registry)))
    (unless pi-coding-agent//renaming-self
      (setcdr entry (plist-put (cdr entry) :label-locked t)))
    (setcar entry new-name)
    (pi-coding-agent//registry-save)))

(defun pi-coding-agent//desired-label-title (file)
  "Return the title a session label should have, or nil when undecidable.
Session /name wins, then the first-message snippet, then \"New session\".
Whitespace runs are collapsed (see `pi-coding-agent//collapse-whitespace')
so perspective names never contain newlines."
  (when-let* ((meta (pi-coding-agent//session-metadata-cached file)))
    (or (let ((name (pi-coding-agent//collapse-whitespace
                     (plist-get meta :session-name))))
          (and (stringp name) name))
        (let ((fm (pi-coding-agent//collapse-whitespace
                   (plist-get meta :first-message))))
          (and (stringp fm) (pi-coding-agent//truncate fm 40)))
        "New session")))

(defun pi-coding-agent//registry-fill-session-file (persp-name plist)
  "Return PLIST's :session-file, resolving and persisting it when nil.
Fresh sessions register with :session-file nil because pi creates the
JSONL file only on the first assistant response; once the perspective's
pi chat buffer settles on a file, it is recorded in the registry entry
and persisted, so the session can be listed as opened and switched to
instead of re-opened.  Returns nil while still unresolvable."
  (or (plist-get plist :session-file)
      (when-let* ((persp (persp-get-by-name persp-name))
                  ((perspective-p persp))
                  (chat (pi-coding-agent//chat-buffer-in-persp persp))
                  (f (plist-get (buffer-local-value 'pi-coding-agent--state chat)
                                :session-file))
                  ((stringp f))
                  ((not (string-empty-p f))))
        (setcdr (assoc persp-name pi-coding-agent//registry)
                (plist-put plist :session-file f))
        (pi-coding-agent//registry-save)
        f)))

(defun pi-coding-agent//sync-labels ()
  "Lazily sync perspective labels with their session titles.
Sessions without a /name keep the first-message snippet; perspectives
renamed by the user are skipped.  Fresh sessions whose registry
:session-file is still nil are resolved from their chat buffer state
first, so the placeholder label updates to the first-message snippet.
Called from the session list and before switching."
  (dolist (entry pi-coding-agent//registry)
    (let ((name (car entry)) (plist (cdr entry)))
      (pi-coding-agent//registry-fill-session-file name plist)
      (when (and (not (plist-get plist :label-locked))
                 (perspective-p (persp-get-by-name name))
                 (plist-get plist :session-file)
                 ;; Never rename from a remote file whose connection is
                 ;; down: the metadata guard would fall back to a stale
                 ;; title while `pi-coding-agent//make-persp-label'
                 ;; loses the directory part (its cwd read is
                 ;; connection-gated too), and the next connected
                 ;; listing would rename the label right back.
                 (or (not (pi-coding-agent--remote-prefix-for-path
                           (plist-get plist :session-file)))
                     (pi-coding-agent//tramp-connection-alive-p
                      (plist-get plist :session-file))))
        (when-let* ((title (pi-coding-agent//desired-label-title
                            (plist-get plist :session-file)))
                    (new-name (pi-coding-agent//make-persp-label
                               title (plist-get plist :session-file)))
                    ((not (string= new-name name))))
          (pi-coding-agent//rename-persp name new-name))))))

(defun pi-coding-agent//after-set-session-name (&rest args)
  "Immediately sync the current perspective label after a session rename.
The lazy scan in `pi-coding-agent//sync-labels' is the backstop (e.g.
renames done via the /name slash command)."
  (let ((name (car args)))
    (when (and (stringp name)
               (not (string-empty-p (string-trim name)))
               (bound-and-true-p persp-mode))
      (let* ((persp-name (safe-persp-name (get-current-persp)))
             (entry (assoc persp-name pi-coding-agent//registry)))
        (when (and entry (not (plist-get (cdr entry) :label-locked))
                   (pi-coding-agent//registry-fill-session-file
                    (car entry) (cdr entry)))
          (let ((new-name (pi-coding-agent//make-persp-label
                           (string-trim name)
                           (plist-get (cdr entry) :session-file))))
            (unless (string= new-name persp-name)
              (pi-coding-agent//rename-persp persp-name new-name))))))))

;; ---------------------------------------------------------------------
;; Session-change sync (package commands that switch the session file)
;;
;; Several package commands switch the live pi session to a DIFFERENT
;; session file without telling the layer:
;;
;; - `pi-coding-agent-new-session' (SPC a i N, , n, menu "new", /new):
;;   resets in place -> new_session RPC -> brand-new file;
;; - `pi-coding-agent-resume-session' (menu "r", C-c C-r, /resume):
;;   switch_session RPC -> selected file;
;; - `pi-coding-agent--execute-fork' (menu "f", fork-at-point, /fork):
;;   fork RPC -> forked file (the frontend branches to a new session);
;; - `pi-coding-agent-open-session-file' (SPC a i s): switch_session RPC
;;   to the chosen file;
;; - `pi-coding-agent-compact' (menu "c", /compact): compact RPC —
;;   pi rewrites the same file today, but if a future pi changes the
;;   file this keeps the registry honest; otherwise it is a no-op.
;;
;; Without the advice below the registry keeps pointing at the OLD
;; session file after any of these.  That staleness would:
;;
;; - list the old file as opened (●) and the new one as closed (○) in
;;   `pi-coding-agent/switch-session';
;; - make `pi-coding-agent//switch-to-session' re-resume the old file
;;   into the shared per-directory process when the stale "current"
;;   entry is picked, undoing the switch;
;; - freeze the perspective label on the old session's title (the lazy
;;   label scan only re-reads the registry's file).
;;
;; The switch completes asynchronously (the session-changing RPC, then a
;; get_state refresh in the response callback), so the advice asks for
;; the state itself and syncs the registry once the process has settled
;; on the new file.  RPC ordering guarantees the state our get_state
;; returns reflects the switch: the session-changing RPC is written to
;; the process before the advice's get_state, and pi processes RPCs in
;; order.  Cancelled/failed/no-op paths (completing-read cancelled,
;; transition not ready, layer's own open flow which already registry-
;; put the file) and no-registry-entry paths are no-ops.

(defun pi-coding-agent//persp-containing-buffer (buf)
  "Return the first live perspective containing BUFFER, or nil.
The nil (Default) pseudo-perspective must be excluded explicitly:
`persp-get-by-name' returns nil for it, `persp-p' treats nil as a valid
perspective, and `safe-persp-buffers' of nil is the full buffer list —
with the nil-tolerant `persp-p' predicate, `Default' (first in
`persp-names') would match every buffer and the function would always
return nil.  The strict `perspective-p' predicate excludes it."
  (when (bound-and-true-p persp-mode)
    (when-let* ((name (cl-find-if
                       (lambda (name)
                         (let ((persp (persp-get-by-name name)))
                           (and (perspective-p persp)
                                (memq buf (safe-persp-buffers persp)))))
                       (persp-names))))
      (persp-get-by-name name))))

(defun pi-coding-agent//sync-registry-after-session-change (&rest _)
  "Re-sync the registry + label after a package session switch.

Runs as :after advice on the package commands that switch the live pi
session to another session file (`pi-coding-agent-new-session',
`pi-coding-agent-resume-session', `pi-coding-agent--execute-fork',
`pi-coding-agent-open-session-file', `pi-coding-agent-compact').

Resolves the owning perspective from the session's chat buffer (not
the current one — an async switch can move the user elsewhere before
the get_state response returns), updates its `:session-file' to the
file the process has actually settled on, and re-derives the
perspective label.  The chat buffer may be shared by several
perspectives of one directory (D6); the owning perspective's entry is
updated because that is the perspective whose session identity the
buffer carries, while the other perspectives' entries are the existing
drift case handled by `pi-coding-agent//switch-to-session'."
  (when (bound-and-true-p persp-mode)
    (let* ((chat (pi-coding-agent--get-chat-buffer))
           (proc (and chat (buffer-local-value 'pi-coding-agent--process chat))))
      (when (and (bufferp chat) (buffer-live-p chat)
                 (processp proc) (process-live-p proc))
        (let ((source (pi-coding-agent//persp-containing-buffer chat)))
          (pi-coding-agent--rpc-async proc '(:type "get_state")
            (lambda (response)
              (when (and (eq (plist-get response :success) t)
                         (buffer-live-p chat)
                         (process-live-p proc)
                         (bound-and-true-p persp-mode))
                (let* ((dir (pi-coding-agent--chat-session-directory chat))
                       (file (plist-get
                              (pi-coding-agent--extract-state-from-response
                               response dir)
                              :session-file)))
                  (when (and (stringp file) (not (string-empty-p file)))
                    (let* ((persp (or source (get-current-persp)))
                           (name (and (perspective-p persp)
                                      (safe-persp-name persp)))
                           (entry (assoc name pi-coding-agent//registry)))
                      (when (and entry
                                 (not (equal
                                       (plist-get (cdr entry) :session-file)
                                       file)))
                        (pi-coding-agent//registry-put
                         name
                         :session-file file
                         :label-locked (plist-get (cdr entry) :label-locked)
                         :buffers (plist-get (cdr entry) :buffers))
                        (pi-coding-agent//registry-save)
                        ;; Re-derive the label from the settled file's
                        ;; metadata: a brand-new session returns to the
                        ;; "New session · path" placeholder (first
                        ;; message re-syncs it via the lazy scan), a
                        ;; resumed/forked session takes its title.
                        (pi-coding-agent//sync-labels)))))))))))))

;; ---------------------------------------------------------------------
;; Session scanning and the switch-session list

(defun pi-coding-agent//session-scan-info (file)
  "Return package-scanned session info for FILE, or nil.
Delegates to the installed package's canonical session scanner and
normalizes to (:first-message :message-count :session-name :cwd).
The scanner moved between releases — `pi-coding-agent-jsonl-read-
session-info' in intermediate versions, `pilish-jsonl-read-session-
info' after the pilish rename, `pi-coding-agent--session-metadata'
(whose plist already is the layer dialect) in older ones — so the
name is resolved at runtime with `fboundp'; calling a missing name
directly would make EVERY metadata read fail and silently empty the
closed-session lists.  nil when no scanner exists or FILE is not a
pi session (the scanners fail open internally)."
  (cond
   ((fboundp 'pi-coding-agent-jsonl-read-session-info)
    (let ((info (pi-coding-agent-jsonl-read-session-info file)))
      (and info
           (list :first-message (plist-get info :firstMessage)
                 :message-count (plist-get info :messageCount)
                 :session-name (plist-get info :name)
                 :cwd (plist-get info :cwd)))))
   ((fboundp 'pilish-jsonl-read-session-info)
    (let ((info (pilish-jsonl-read-session-info file)))
      (and info
           (list :first-message (plist-get info :firstMessage)
                 :message-count (plist-get info :messageCount)
                 :session-name (plist-get info :name)
                 :cwd (plist-get info :cwd)))))
   ((fboundp 'pi-coding-agent--session-metadata)
    (let ((meta (pi-coding-agent--session-metadata file)))
      (and meta
           (list :first-message (plist-get meta :first-message)
                 :message-count (plist-get meta :message-count)
                 :session-name (plist-get meta :session-name)
                 :cwd (plist-get meta :cwd)))))))

(defun pi-coding-agent//session-metadata-cached (file)
  "Return cached metadata for session FILE, re-parsing when mtime changed.
Metadata uses the layer's dialect — (:modified-time TIME :first-message
TEXT :message-count COUNT :session-name NAME :cwd DIR) — parsed with
the package's canonical session scanner (see
`pi-coding-agent//session-scan-info'; :modified-time comes from
FILE's own mtime, matching the oldest scanner's behavior).  Fail-open:
a vanished or unreadable FILE — e.g. one whose directory no longer
exists — yields nil with a message instead of an error, so session
listing and deletion never abort on stale or missing session files.

Remote (TRAMP) FILEs are only read over an already-established
connection (`pi-coding-agent//tramp-connection-alive-p', an I/O-free
check): an unreachable host must never block a listing.  A
disconnected remote file falls back to its stale cache entry
(unchecked mtime) and yields nil without one."
  (condition-case err
      (let* ((remote (pi-coding-agent--remote-prefix-for-path file))
             (connected (or (not remote)
                            (pi-coding-agent//tramp-connection-alive-p file)))
             (attrs (and connected (file-attributes file)))
             (mtime (and attrs (file-attribute-modification-time attrs)))
             (cached (gethash file pi-coding-agent//session-cache)))
        (cond
         ;; Normal path: cache hit with matching mtime.
         ((and cached (equal (car cached) mtime)) (cdr cached))
         ;; Disconnected remote: use the stale cache without mtime
         ;; validation; without a cache entry, fail open (nil) — never
         ;; touch the file.
         ((and remote (not connected) cached) (cdr cached))
         (connected
          (let* ((info (pi-coding-agent//session-scan-info file))
                 (meta (and info
                            (plist-put (copy-sequence info)
                                       :modified-time mtime))))
            (puthash file (cons mtime meta) pi-coding-agent//session-cache)
            meta))))
    (error
     (message "pi: cannot read session metadata for %s: %s"
              (abbreviate-file-name file) (error-message-string err))
     nil)))

(defun pi-coding-agent//live-session-mappings ()
  "Return ((PERSP-NAME . SESSION-FILE) ...) for perspectives showing
pi chat buffers.
Each real perspective contributes its registry session file (fresh
entries with :session-file nil are resolved from the chat buffer state
and persisted) plus the settled session file of every pi chat buffer it
displays.  This covers sessions started outside the registry flow
(named sessions via `pi-coding-agent/open-named-session', plain
`pi-coding-agent' in an unregistered perspective) and fresh sessions
whose JSONL file pi creates only on the first assistant response.  A
chat buffer shared by several perspectives of one directory (D6) maps
to each perspective that displays it.

Used by `pi-coding-agent//open-or-switch' to resolve the perspective
to switch to for a session file when the registry misses.  The session
LISTS determine liveness from the active pi chat buffers instead (see
`pi-coding-agent//opened-session-files' / `pi-coding-agent//session-targets')."
  (when (bound-and-true-p persp-mode)
    (let (pairs)
      (dolist (name (persp-names))
        (when-let* ((persp (persp-get-by-name name))
                    ((persp-p persp)))
          (when-let* ((entry (assoc name pi-coding-agent//registry))
                      (f (pi-coding-agent//registry-fill-session-file
                          name (cdr entry))))
            (push (cons name f) pairs))
          (dolist (buf (safe-persp-buffers persp))
            (when (with-current-buffer buf
                    (derived-mode-p 'pi-coding-agent-chat-mode))
              (when-let* ((state (buffer-local-value
                                  'pi-coding-agent--state buf))
                          (f (plist-get state :session-file))
                          ((stringp f))
                          ((not (string-empty-p f))))
                (push (cons name f) pairs))))))
      (nreverse pairs))))

(defun pi-coding-agent//opened-session-files ()
  "Return session files loaded by an active pi chat buffer.
Live sessions are defined by their chat buffers, not by the registry
or the perspective mapping: every active pi chat buffer (mode
`pi-coding-agent-chat-mode', live process) is a live session, and its
loaded session file — when pi has written one yet — is that session's
file.  Session files on disk not loaded by an active buffer are
closed."
  (delete-dups
   (cl-loop for buf in (pi-coding-agent//active-chat-buffers)
            for file = (plist-get (buffer-local-value
                                   'pi-coding-agent--state buf)
                                  :session-file)
            when (and (stringp file) (not (string-empty-p file)))
            collect file)))

;; ---------------------------------------------------------------------
;; Remote-session scope and non-blocking remote access
;;
;; Session lists are scoped by the current session's host: a local
;; context lists local sessions only, a remote (TRAMP) session adds its
;; own host's sessions.  Remote files are never touched over a
;; connection that is not already established — all checks are I/O-free
;; — so an unreachable host can no longer hang the listing; it is
;; probed in the background instead and its sessions reappear in a
;; later listing once it answers.

(defun pi-coding-agent//tramp-connection-alive-p (path)
  "Return non-nil when TRAMP has an established connection for PATH.
Checked without any I/O: `tramp-dissect-file-name' parses purely and
`tramp-get-connection-process' only looks up the connection's ssh
process, so callers can tell whether remote work would be fast (no
reconnection) or would block on an unreachable host.  Non-remote
PATHs return nil."
  (and (pi-coding-agent--remote-prefix-for-path path)
       (when-let* ((vec (ignore-errors (tramp-dissect-file-name path)))
                   (proc (tramp-get-connection-process vec)))
         (process-live-p proc))))

(defun pi-coding-agent//buffer-remote-prefix (buf)
  "Return the TRAMP remote prefix of BUF's session directory, or nil.
nil means the buffer's session is local.  Purely syntactic — no
connection is made."
  (condition-case nil
      (pi-coding-agent--remote-prefix-for-path
       (with-current-buffer buf
         (pi-coding-agent--chat-session-directory)))
    (error nil)))

(defun pi-coding-agent//current-session-remote-prefix ()
  "Return the TRAMP remote prefix of the current session, or nil.
The current session is the current perspective's pi chat buffer; nil
when there is none (default perspective, no session) or it is local —
the state in which session lists must not contain, or ever touch,
remote sessions."
  (when-let* ((persp (get-current-persp))
              ((perspective-p persp))
              (chat (pi-coding-agent//chat-buffer-in-persp persp)))
    (pi-coding-agent//buffer-remote-prefix chat)))

(defvar pi-coding-agent//remote-probes-in-flight
  (make-hash-table :test 'equal)
  "Hosts with a background reachability probe running.
Guards `pi-coding-agent//remote-probe-async' against stacking probes
when session lists are invoked repeatedly while a host is down.
Entries are host name strings; they are removed by the probe's
sentinel.")

(defun pi-coding-agent//remote-probe-async (prefix)
  "Probe PREFIX's remote host over ssh in the background; return nil.
Listing sessions must not block on an unreachable host, so instead of
connecting synchronously this fires a bounded `ssh' probe (BatchMode,
ConnectTimeout — the same recipe as
`pi-coding-agent//remote-host-probe') and reports the outcome in the
echo area: reachable — the next session listing includes the host's
remote sessions; exit 255 — the host answered but BatchMode
authentication failed, TRAMP will prompt interactively when a remote
session is opened; anything else — unreachable, its remote sessions
stay out of the lists.  Probes are throttled per host
(`pi-coding-agent//remote-probes-in-flight')."
  (let ((host (file-remote-p prefix 'host))
        (timeout (max 1 (or pi-coding-agent/remote-connect-timeout 20))))
    (when (and host
               (not (gethash host pi-coding-agent//remote-probes-in-flight)))
      (puthash host t pi-coding-agent//remote-probes-in-flight)
      (message "pi: %s is not connected — probing in the background; its remote sessions reappear in the session list once it answers"
               host)
      (condition-case err
          (make-process
           :name "pi-remote-probe-async"
           :buffer (generate-new-buffer " *pi-remote-probe async*")
           :command (list "ssh" "-o" "BatchMode=yes"
                          "-o" (format "ConnectTimeout=%d" timeout)
                          host "true")
           :connection-type 'pipe
           :noquery t
           :sentinel
           (lambda (proc _event)
             (when (memq (process-status proc) '(exit signal))
               (remhash host pi-coding-agent//remote-probes-in-flight)
               (pcase (process-exit-status proc)
                 (0 (message "pi: %s is reachable — re-run the session list to include its remote sessions"
                             host))
                 (255 (message "pi: %s answers but ssh authentication was refused: %s"
                               host
                               (string-trim
                                (with-current-buffer (process-buffer proc)
                                  (buffer-string)))))
                 (_ (message "pi: %s is unreachable — its remote sessions stay out of the session lists"
                             host)))
               (ignore-errors
                 (kill-buffer (process-buffer proc))))))
        (file-error
         (remhash host pi-coding-agent//remote-probes-in-flight)
         (message "pi: background probe for %s failed: %s"
                  host (error-message-string err))))
    nil)))

(defun pi-coding-agent//remote-scan-root (prefix)
  "Return the session root to scan for remote PREFIX, or nil.
Remote sessions of PREFIX's host are listed only over an
already-established TRAMP connection, so an unreachable host never
blocks a listing: with the connection down, a background probe is
fired (`pi-coding-agent//remote-probe-async') and nil is returned —
the host's closed sessions reappear in a later listing once it
answers.  nil PREFIX (local context) returns nil: the local session
root is scanned by default."
  (cond
   ((null prefix) nil)
   ((pi-coding-agent//tramp-connection-alive-p prefix)
    (concat prefix "~/.pi/agent/sessions/"))
   (t
    (pi-coding-agent//remote-probe-async prefix)
    nil)))

(defun pi-coding-agent//remote-executable-entry-for (file)
  "Return the verified (PI-PATH . NODE-PATH) mapping for FILE's host, or nil.
Reads the mapping `pi-coding-agent/remote-executables' that
`pi-coding-agent/start-remote-session' fills in after locating and
verifying the host's pi.  nil for local files and hosts without a
mapping (the default executable is used, as before)."
  (when-let* ((prefix (pi-coding-agent--remote-prefix-for-path file))
              (host (file-remote-p prefix 'host))
              (entry (alist-get host pi-coding-agent/remote-executables
                                nil nil #'string-equal))
              ((stringp (car entry))))
    entry))

(defun pi-coding-agent//remote-executable-for (file)
  "Return the verified remote pi executable for FILE's host, or nil.
The pi part of `pi-coding-agent//remote-executable-entry-for'."
  (when-let* ((entry (pi-coding-agent//remote-executable-entry-for file)))
    (car entry)))

(defun pi-coding-agent//remote-spawn-executable (entry)
  "Return a `pi-coding-agent-executable' value that runs ENTRY's pi remotely.
ENTRY is a (PI-PATH . NODE-PATH) mapping as recorded in
`pi-coding-agent/remote-executables'.  With NODE-PATH, the value is a
\"sh -c\" wrapper that exports node's bin directory into PATH before
exec'ing pi: the TRAMP spawn shell is a non-interactive login shell
whose rc files are skipped on purpose (see
`pi-coding-agent/start-remote-session'), so `node' — typically
installed under ~/.local/share/pi-node/… and only put on PATH by the
interactive shell's rc file — is invisible to it, and pi's
`#!/usr/bin/env node' shebang dies with exit 127 (\"env: node: No such
file or directory\") right after the ready marker.  The wrapper gives
the spawn the same treatment `pi-coding-agent//remote-verify-pi'
gives its verification run, making the spawn independent of the
remote PATH entirely.  It composes with the package's own remote
wrapper (ready marker + `exec \"$0\" \"$@\"'): that wrapper's \"$0\" is
our \"sh\".  Without NODE-PATH (node found through the remote PATH),
the plain absolute pi path is returned."
  (let ((pi-path (car entry))
        (node-dir (and (cdr entry) (file-name-directory (cdr entry)))))
    (if node-dir
        (list "sh" "-c"
              (concat "PATH="
                      (shell-quote-argument
                       (directory-file-name node-dir))
                      ":$PATH; export PATH; exec \"$0\" \"$@\"")
              pi-path)
      (list pi-path))))

(defun pi-coding-agent//ensure-remote-reachable (file)
  "Bound the connection cost of opening remote session FILE.
Local files and already-established TRAMP connections return
immediately.  Otherwise probe the host with the bounded ssh deadline
(`pi-coding-agent//remote-host-probe'): reachable and auth results
fall through to the open (TRAMP handles interactive authentication),
while an unreachable host signals a clear `user-error' instead of
leaving TRAMP waiting forever on a silent ssh — the same failure mode
`pi-coding-agent/start-remote-session' guards against."
  (when-let* ((prefix (pi-coding-agent--remote-prefix-for-path file))
              ((not (pi-coding-agent//tramp-connection-alive-p file))))
    (let* ((host (file-remote-p prefix 'host))
           (timeout pi-coding-agent/remote-connect-timeout)
           (probe (progn
                    (message "pi: connecting to %s (ssh probe timeout %ds)..."
                             host (or timeout 20))
                    (pi-coding-agent//remote-host-probe host timeout))))
      (pcase probe
        (`(reachable . ,_) nil)
        (`(auth . ,diag)
         (message "%s is reachable; ssh authentication will be handled by TRAMP%s"
                  host (if (string-empty-p diag) ""
                         (format " (%s)" diag))))
        (`(unreachable . ,diag)
         (user-error "Cannot reach %s via ssh within %ds%s — remote session not opened"
                     host (or timeout 20)
                     (if (string-empty-p diag) ""
                       (format ": %s" diag))))))))

(defun pi-coding-agent//normalized-dir (dir)
  "Return DIR expanded (route-preserving) with a trailing slash.
Matches the normalization `pi-coding-agent--session-file-cwd-or-error'
applies to recorded cwds.  Remote (TRAMP) DIRs are additionally
canonicalized through TRAMP (`~' home components expanded), so one
remote directory compares equal regardless of `~' spelling."
  (if (pi-coding-agent--remote-prefix-for-path dir)
      (file-name-as-directory (expand-file-name dir))
    (file-name-as-directory
     (pi-coding-agent--route-preserving-expand-file-name dir))))

(defun pi-coding-agent//entry-cwd (file cwd)
  "Return session entry CWD anchored for its session FILE.
Local files keep CWD as-is; remote (TRAMP) FILES anchor the
process-local CWD (as recorded in the session header) with the file's
remote prefix, so directory comparisons via
`pi-coding-agent//normalized-dir' work across the remote/local
boundary."
  (if (and cwd (pi-coding-agent--remote-prefix-for-path file))
      (pi-coding-agent--emacs-directory cwd file)
    cwd))

(defun pi-coding-agent//session-entries-in-dir (dir &optional root)
  "Return session entries whose recorded cwd is DIR (exact match).
DIR is compared expanded and with a trailing slash, matching the
normalization `pi-coding-agent--session-file-cwd-or-error' applies to
recorded cwds.  ROOT overrides the scanned session root (see
`pi-coding-agent//session-entries')."
  (let ((dir (pi-coding-agent//normalized-dir dir)))
    (cl-remove-if-not
     (lambda (entry)
       (let ((cwd (plist-get entry :cwd)))
         (and (stringp cwd)
              (equal (pi-coding-agent//normalized-dir cwd) dir))))
     (pi-coding-agent//session-entries root))))

(defun pi-coding-agent//file-in-opened-p (file opened)
  "Return non-nil when FILE is one of the opened session files OPENED.
Remote files are compared in TRAMP-canonical form (`~' home
components expanded), so scan results and live-session state can
differ in `~' spelling and still match; local files are compared
plainly."
  (if (pi-coding-agent--remote-prefix-for-path file)
      (let ((canon (expand-file-name file)))
        (cl-some (lambda (f) (equal (expand-file-name f) canon)) opened))
    (member file opened)))

(defun pi-coding-agent//session-entries (&optional root)
  "Return plist entries for all sessions under ROOT.
ROOT defaults to the pi session root: `pi-coding-agent/session-root',
overridden by the PI_AGENT_DIR environment variable when set (pi then
stores sessions under <PI_AGENT_DIR>/sessions).  A remote (TRAMP) ROOT
is scanned best-effort: connection failures yield an empty list
instead of signalling, so an unreachable host degrades to no closed
sessions rather than blocking the caller.  Each entry carries an
:opened flag (non-nil when the file is loaded by an active pi chat
buffer — see `pi-coding-agent//opened-session-files')."
  (let* ((root (or root (pi-coding-agent//session-root)))
         (remote-p (pi-coding-agent--remote-prefix-for-path root))
         (files (if remote-p
                    (condition-case nil
                        (and (file-directory-p root)
                             (directory-files-recursively root "\\.jsonl$"))
                      (error nil))
                  (and (file-directory-p root)
                       (directory-files-recursively root "\\.jsonl$"))))
         (opened (pi-coding-agent//opened-session-files))
         entries)
    (dolist (file files)
      (when-let* ((meta (pi-coding-agent//session-metadata-cached file)))
        (push (list :file file
                    :cwd (pi-coding-agent//entry-cwd file (plist-get meta :cwd))
                    :first-message (plist-get meta :first-message)
                    :name (plist-get meta :session-name)
                    :count (plist-get meta :message-count)
                    :modified (plist-get meta :modified-time)
                    :opened (pi-coding-agent//file-in-opened-p file opened))
              entries)))
    ;; Drop cache entries for deleted files — only within the scanned
    ;; ROOT's scope: a local scan cannot see remote files (their
    ;; sessions live on their hosts), so it must not evict their cached
    ;; metadata, and a remote scan conversely must not evict local
    ;; entries.  Without the scope check, every disconnected-host
    ;; listing would wipe the remote cache (forcing a full re-read once
    ;; the host answers again).
    (maphash (lambda (file _)
               (unless (member file files)
                 (let ((file-remote
                        (pi-coding-agent--remote-prefix-for-path file)))
                   (when (if remote-p
                             (and file-remote
                                  (equal file-remote
                                         (pi-coding-agent--remote-prefix-for-path
                                          root)))
                           (not file-remote))
                     (remhash file pi-coding-agent//session-cache)))))
             pi-coding-agent//session-cache)
    (nreverse entries)))

(defun pi-coding-agent//disambiguated-label (label n file)
  "LABEL, suffixed with a short uuid when seen N (>0) times before.
Two sessions can render identically (same title and directory); the
second and later ones get a uuid suffix so each candidate stays
selectable.  FILE supplies the uuid prefix; \"?\" when unavailable."
  (if (> n 0)
      (format "%s  (%s)" label
              (or (pi-coding-agent//file-uuid-prefix file) "?"))
    label))

(defun pi-coding-agent//session-buffer-dir-p (buf dir)
  "Return non-nil when pi chat buffer BUF's session directory is DIR.
The buffer's session directory is read like
`pi-coding-agent//context-directory' reads it (via
`pi-coding-agent--chat-session-directory') and compared with the same
normalization `pi-coding-agent//normalized-dir' applies to recorded
cwds."
  (when-let* ((buf-dir (condition-case nil
                           (with-current-buffer buf
                             (pi-coding-agent--chat-session-directory))
                         (error nil)))
              ((stringp buf-dir))
              ((equal (pi-coding-agent//normalized-dir buf-dir)
                      (pi-coding-agent//normalized-dir dir))))
    t))

(defun pi-coding-agent//remote-scope-entries (remote-scope dir)
  "Return closed-session entries contributed by REMOTE-SCOPE's hosts.
A TRAMP prefix string scopes to that one host; `t' (the close/delete
scope) to every host with an active pi chat buffer plus the current
session's host.  Each host's root is scanned only over an
already-established connection (`pi-coding-agent//remote-scan-root':
a disconnected host gets a background probe and contributes nothing
instead of blocking).  nil when DIR is given — directory-scoped lists
come from their own root — or when REMOTE-SCOPE admits no remote
host (nil or `local`)."
  (when (null dir)
    (let ((prefixes
           (cond
            ((stringp remote-scope) (list remote-scope))
            ((eq remote-scope t)
             (delete-dups
              (delq nil
                    (cons (pi-coding-agent//current-session-remote-prefix)
                          (mapcar #'pi-coding-agent//buffer-remote-prefix
                                  (pi-coding-agent//active-chat-buffers)))))))))
      (apply #'append
             (delq nil
                   (mapcar
                    (lambda (prefix)
                      (let ((root (pi-coding-agent//remote-scan-root prefix)))
                        (and root (pi-coding-agent//session-entries root))))
                    prefixes))))))

(defun pi-coding-agent//session-targets (&optional dir include-closed
                                        exclude-current root remote-scope)
  "Return (LIVE . CLOSED) candidate alists for the session pickers.

LIVE lists the active pi chat buffers — the ground truth for live
sessions — most recently used first, each mapped to a target plist
\(:buffer BUF :file FILE :entry ENTRY :label LABEL :opened t), where
ENTRY is the session's file metadata when pi has written its JSONL
file yet (nil for fresh sessions).  CLOSED lists the session files on
disk not loaded by an active buffer, each mapped to (:entry ENTRY
:label LABEL :opened nil); it is empty when INCLUDE-CLOSED is nil.

When DIR is given, only sessions of that directory are listed.  When
EXCLUDE-CURRENT is non-nil, the current perspective's session is
dropped: its live chat buffers from LIVE, its session file from
CLOSED.

REMOTE-SCOPE decides which hosts' sessions are listed — the only
remote axis, shared by every picker (`a i i' passes the current
session's host or `local'; close/delete pass t to reach every host,
including a dead remote one):
- nil (no scoping) and `local' keep LOCAL sessions only — a local
  context must not even touch remote state, so an unreachable host
cannot block the list;
- a TRAMP prefix string keeps local sessions plus that host's, and
- t keeps local sessions plus every active remote host's.
A scoped host contributes BOTH its live chat buffers and its closed
session files, the files scanned only over an already-established
connection (`pi-coding-agent//remote-scan-root': a disconnected host
gets a background probe and contributes nothing instead of blocking
the listing).

Each alist maps a candidate string to its target; duplicate labels
(same title and directory) are disambiguated with a uuid suffix
\(`pi-coding-agent//disambiguated-label').  LIVE always precedes
CLOSED, and the pickers keep that order (see
`pi-coding-agent//pick-session')."
  (let* ((entries (append
                   (if dir (pi-coding-agent//session-entries-in-dir dir root)
                     (pi-coding-agent//session-entries root))
                   ;; A scoped host adds its closed sessions, scanned
                   ;; only over an established connection (nil root ->
                   ;; no scan -> no blocking).
                   (pi-coding-agent//remote-scope-entries remote-scope
                                                          dir)))
         (by-file (make-hash-table :test 'equal))
         (seen (make-hash-table :test 'equal))
         (current-persp (get-current-persp))
         (current-buffers (and exclude-current
                               (perspective-p current-persp)
                               (safe-persp-buffers current-persp)))
         (current-file (and exclude-current
                            (pi-coding-agent//current-session-file)))
         live closed)
    (dolist (entry entries)
      (puthash (plist-get entry :file) entry by-file))
    ;; LIVE: active pi chat buffers (live process), most recently used
    ;; first.  The registry/perspective mapping is not consulted: it can
    ;; be stale (a killed perspective still registered) or miss sessions
    ;; started outside the registry flow, while the chat buffers always
    ;; reflect what is actually running.
    (dolist (buf (pi-coding-agent//active-chat-buffers))
      (let ((buf-prefix (pi-coding-agent//buffer-remote-prefix buf)))
        (when (and
               ;; Local sessions are always in scope; remote ones when
               ;; the scope admits their host (t = every host, a
               ;; prefix = that host, nil/'local = none).
               (or (null buf-prefix)
                   (eq remote-scope t)
                   (and (stringp remote-scope)
                        (string-equal buf-prefix remote-scope)))
               (or (null dir) (pi-coding-agent//session-buffer-dir-p buf dir))
               (or (null current-buffers)
                   (not (memq buf current-buffers))))
          (let* ((file (plist-get (buffer-local-value
                                   'pi-coding-agent--state buf)
                                  :session-file))
                 (file (and (stringp file) (not (string-empty-p file)) file))
                 (entry (and file (gethash file by-file)))
                 (label (pi-coding-agent//chat-buffer-label buf by-file))
                 (n (gethash label seen 0)))
            (puthash label (1+ n) seen)
            (push (cons (pi-coding-agent//disambiguated-label label n file)
                        (append (list :buffer buf :label label :opened t)
                                (and file (list :file file))
                                (and entry (list :entry entry))))
                  live)))))
    ;; CLOSED: session files on disk not loaded by an active buffer
    ;; (the :opened flag of `pi-coding-agent//session-entries' is
    ;; derived from the active buffers).
    (when include-closed
      (dolist (entry entries)
        (let* ((file (plist-get entry :file))
               (label (pi-coding-agent//session-base-label entry))
               (n (gethash label seen 0)))
          (unless (or (plist-get entry :opened)
                      (and current-file (equal file current-file)))
            (puthash label (1+ n) seen)
            (push (cons (pi-coding-agent//disambiguated-label label n file)
                        (list :entry entry :label label :opened nil))
                  closed)))))
    (cons (nreverse live) (nreverse closed))))

(defun pi-coding-agent//collapse-whitespace (string)
  "Collapse whitespace runs in STRING to single spaces, ends trimmed.
Newlines and tabs in first-message titles would otherwise break the
session list into multi-line rows (helm and *Completions* display
candidates verbatim), making sessions look like they have no text,
directory, or time.  Returns nil for non-strings and blank strings."
  (when (stringp string)
    (let ((collapsed (string-trim
                      (replace-regexp-in-string "[ \t\n\r]+" " " string))))
      (and (not (string-empty-p collapsed)) collapsed))))

(defun pi-coding-agent//entry-title (entry)
  "Display title for session ENTRY (name, first message, or placeholder).
Newlines and other whitespace runs are collapsed to single spaces, so
titles stay on one line in the session lists."
  (or (let ((name (pi-coding-agent//collapse-whitespace
                   (plist-get entry :name))))
        (and (stringp name) name))
      (let ((fm (pi-coding-agent//collapse-whitespace
                 (plist-get entry :first-message))))
        (and (stringp fm) (pi-coding-agent//truncate fm 40)))
      "(no messages)"))

(defun pi-coding-agent//target-meta (target slot default)
  "Return session TARGET's metadata SLOT, falling back to DEFAULT.
The slot is read from the target's :entry when it has one, else from
the target itself — live sessions carry their file metadata in
:entry, while fallback targets (e.g. the close picker's default
perspective) carry :count/:modified directly."
  (or (plist-get (plist-get target :entry) slot)
      (plist-get target slot)
      default))

(defun pi-coding-agent//target-title (target)
  "Sort/display title for session TARGET: its entry's title, else its label."
  (if-let* ((entry (plist-get target :entry)))
      (pi-coding-agent//entry-title entry)
    (plist-get target :label)))

(defun pi-coding-agent//target-count (target)
  "Message count of session TARGET."
  (pi-coding-agent//target-meta target :count 0))

(defun pi-coding-agent//target-modified (target)
  "Last-modification time of session TARGET."
  (pi-coding-agent//target-meta target :modified (current-time)))

(defun pi-coding-agent//target-dir (target)
  "Normalized session directory of TARGET, or nil when undeterminable.
Closed targets read the recorded :cwd from their :entry; live targets
without a file entry fall back to the chat buffer's session
directory."
  (or (when-let* ((entry (plist-get target :entry))
                  (cwd (plist-get entry :cwd)))
        (pi-coding-agent//normalized-dir cwd))
      (when-let* ((buf (plist-get target :buffer)))
        (condition-case nil
            (pi-coding-agent//normalized-dir
             (with-current-buffer buf
               (pi-coding-agent--chat-session-directory)))
          (error nil)))))

(defun pi-coding-agent//sort-targets (targets mode)
  "Sort session TARGETS (a candidate alist) by MODE.
`alpha' sorts by title, `chrono' by last modification (newest first),
`dir-then-name' by session directory, then by title."
  (pcase mode
    ('alpha
     (sort (copy-sequence targets)
           (lambda (a b)
             (string< (pi-coding-agent//target-title (cdr a))
                      (pi-coding-agent//target-title (cdr b))))))
    ('chrono
     (sort (copy-sequence targets)
           (lambda (a b)
             (time-less-p (pi-coding-agent//target-modified (cdr b))
                          (pi-coding-agent//target-modified (cdr a))))))
    ('dir-then-name
     (sort (copy-sequence targets)
           (lambda (a b)
             (let ((dir-a (or (pi-coding-agent//target-dir (cdr a)) ""))
                   (dir-b (or (pi-coding-agent//target-dir (cdr b)) "")))
               (if (string= dir-a dir-b)
                   (string< (pi-coding-agent//target-title (cdr a))
                            (pi-coding-agent//target-title (cdr b)))
                 (string< dir-a dir-b))))))
    (_ targets)))

(defun pi-coding-agent//age-string (time)
  "Humanized age of TIME, e.g. \"now\", \"5m\", \"3h\", \"2d\"."
  (let ((secs (max 0 (floor (float-time (time-subtract (current-time) time))))))
    (cond ((< secs 60) "now")
          ((< secs 3600) (format "%dm" (/ secs 60)))
          ((< secs 86400) (format "%dh" (/ secs 3600)))
          (t (format "%dd" (/ secs 86400))))))

(defun pi-coding-agent//session-header (title)
  "Section header row \"──── TITLE ────\" marking a group boundary."
  (format "────── %s ──────" title))

(defconst pi-coding-agent//live-sessions-header
  (pi-coding-agent//session-header "Live sessions")
  "Non-selectable boundary row preceding the live session candidates.
Inserted by `pi-coding-agent//cr-pick-session-target' between the
live and closed groups; selecting it re-prompts.")

(defconst pi-coding-agent//closed-sessions-header
  (pi-coding-agent//session-header "Closed sessions")
  "Non-selectable boundary row preceding the closed session candidates.
Inserted by `pi-coding-agent//cr-pick-session-target' after the live
group; selecting it re-prompts.")

(defun pi-coding-agent//annotated-session-candidate (cand target)
  "Annotated display string for session candidate CAND with TARGET.
Separators and action items (nil target, e.g. \"✚ New session\")
render as-is; sessions get a \"● \"/\"○ \" status glyph plus
\"  N msgs  AGE\"."
  (if (or (null target) (eq (plist-get target :separator) t))
      cand
    (format "%s%s  %d msgs  %s"
            (if (plist-get target :opened) "● " "○ ")
            cand
            (pi-coding-agent//target-count target)
            (pi-coding-agent//age-string
             (pi-coding-agent//target-modified target)))))

(defun pi-coding-agent//helm-session-candidates (alist)
  "Return (DISPLAY . REAL) cons candidates for helm from session ALIST.
DISPLAY annotates the candidate with status glyph, message count, and
age; REAL is the clean candidate string used for dispatch, so helm
matching (on DISPLAY) and the caller's `assoc' lookups stay
consistent."
  (mapcar (lambda (cand)
            (cons (pi-coding-agent//annotated-session-candidate
                   (car cand) (cdr cand))
                  (car cand)))
          alist))

(defun pi-coding-agent//session-target-affixation (alist)
  "Return an affixation function for session candidate ALIST.
Candidates are annotated with a status glyph (● live / ○ closed)
plus message count and age; section-header rows (:separator targets)
and action items (nil target, e.g. \"✚ New session\") get no
annotation."
  (lambda (cands)
    (mapcar
     (lambda (cand)
       (let* ((target (cdr (assoc cand alist)))
              (glyph (cond ((null target) "")
                           ((eq (plist-get target :separator) t) "")
                           ((plist-get target :opened) "● ")
                           (t "○ ")))
              (suffix (if (and target
                               (not (eq (plist-get target :separator) t)))
                          (format "  %d msgs  %s"
                                  (pi-coding-agent//target-count target)
                                  (pi-coding-agent//age-string
                                   (pi-coding-agent//target-modified target)))
                        "")))
         (list cand glyph suffix)))
     cands)))

(defun pi-coding-agent//session-collection (alist)
  "Return a completing-read collection over candidate ALIST.
Provides affixation metadata (status glyph, count, age) and keeps the
pre-sorted candidate order."
  (let ((cands (mapcar #'car alist)))
    (lambda (string pred action)
      (cond
       ((null action) (try-completion string cands pred))
       ((eq action t) (all-completions string cands pred))
       ((eq (car-safe action) 'metadata)
        `(metadata (category . pi-session)
                   (affixation-function
                    . ,(pi-coding-agent//session-target-affixation alist))
                   (display-sort-function . identity)))
       (t nil)))))

(defun pi-coding-agent//cr-pick-session-target (live closed prompt
                                                &optional default-label
                                                must-match extra)
  "completing-read over LIVE/CLOSED candidate alists; return the choice.
Candidates keep the pre-sorted order (live before closed) with
section-header rows (`pi-coding-agent//live-sessions-header' /
`pi-coding-agent//closed-sessions-header') marking the boundary
between the two groups, annotated with status glyph, message count,
and age.  EXTRA (an alist, e.g. the \"✚ New session\" action) is
appended after the closed group.  Selecting a header row re-prompts.
Returns the chosen candidate string, or the typed input when
MUST-MATCH is nil."
  (cl-loop
   with alist = (append (list (cons pi-coding-agent//live-sessions-header
                                    '(:separator t)))
                        live
                        (and closed
                             (list (cons pi-coding-agent//closed-sessions-header
                                         '(:separator t))))
                        closed
                        extra)
   with collection = (pi-coding-agent//session-collection alist)
   for choice = (completing-read
                 prompt collection nil must-match default-label
                 'pi-coding-agent-session-history)
   until (not (eq (plist-get (cdr (assoc choice alist)) :separator) t))
   do (message "Pick a session, not a section header")
   finally return choice))

;; Declared for the byte-compiler: `helm-make-source' (helm-core's
;; helm-source.el) is only available at runtime, once helm is loaded.
(declare-function helm-make-source "helm-source.el")

(defun pi-coding-agent//helm-pick-session-target (live closed prompt
                                                 &optional default-label
                                                 must-match extra)
  "Helm pick of a session from LIVE/CLOSED candidate alists.
Live sessions are shown in their own \"Live sessions\" section,
closed sessions in a \"Closed sessions\" one (when present) — the
boundary between the groups; EXTRA is a list of (SOURCE-NAME . ALIST)
sections appended after them (e.g. the \"✚ New session\" action).
Candidates are annotated with status glyph, message count, and age;
the returned string is the clean candidate (no annotation)."
  ;; Sources are built with `helm-make-source' (a function), not the
  ;; `helm-build-sync-source' macro: funcs.el is loaded/compiled before
  ;; helm is, so a macro call would never be expanded and would fail at
  ;; runtime with "Invalid function".  `helm-make-source' lives in
  ;; helm-core's helm-source.el, which helm.el requires at load time.
  (require 'helm)
  (helm :sources
        (append
         (list (helm-make-source
                "Live sessions" 'helm-source-sync
                :candidates (pi-coding-agent//helm-session-candidates live)
                :must-match must-match
                :action 'identity))
         (and closed
              (list (helm-make-source
                     "Closed sessions" 'helm-source-sync
                     :candidates (pi-coding-agent//helm-session-candidates closed)
                     :must-match must-match
                     :action 'identity)))
         (cl-loop for (name . alist) in extra
                  collect (helm-make-source
                           name 'helm-source-sync
                           :candidates (pi-coding-agent//helm-session-candidates alist)
                           :must-match nil
                           :action 'identity)))
        :buffer "*helm pi session*"
        :prompt prompt
        :default default-label))

(defun pi-coding-agent//pick-session (live closed prompt
                                      &optional default-label must-match extra)
  "Unified session picker over LIVE/CLOSED candidate alists.
Live sessions are always offered before closed ones, with a clear
boundary between the groups: separate \"Live sessions\" /
\"Closed sessions\" sources under helm, section-header rows under
completing-read (vertico, ivy, plain minibuffer).  EXTRA is an
action alist (e.g. \"✚ New session\"), offered as its own source
under helm and appended after the closed group otherwise.  Returns
the chosen candidate string — or the typed input when MUST-MATCH is
nil."
  (if (featurep 'helm)
      (pi-coding-agent//helm-pick-session-target
       live closed prompt default-label must-match extra)
    (pi-coding-agent//cr-pick-session-target
     live closed prompt default-label must-match extra)))

;; ---------------------------------------------------------------------
;; Opening, switching, reviving

(defun pi-coding-agent//chat-buffers-in-persp (persp)
  "Return the pi chat buffers of PERSP, in perspective buffer order."
  (cl-remove-if-not (lambda (buf)
                      (with-current-buffer buf
                        (derived-mode-p 'pi-coding-agent-chat-mode)))
                    (safe-persp-buffers persp)))

(defun pi-coding-agent//chat-buffer-in-persp (persp)
  "Return the first pi chat buffer of PERSP, or nil."
  (car (pi-coding-agent//chat-buffers-in-persp persp)))

(defun pi-coding-agent//revive-session (chat file &optional launch)
  "Ensure a live pi process for the session of FILE and resume FILE.
CHAT is an existing chat buffer to reuse; its launch name is used when
LAUNCH is nil.  Returns the chat buffer."
  (let* ((dir (pi-coding-agent--session-file-cwd-or-error file))
         (launch (or launch (and chat (pi-coding-agent--chat-session-name chat)))))
    (condition-case err
        (let* ((chat (pi-coding-agent--setup-session dir launch))
               (proc (buffer-local-value 'pi-coding-agent--process chat)))
          (when (and (processp proc) (process-live-p proc)
                     (pi-coding-agent--session-transition-ready-p chat "open"))
            (pi-coding-agent--resume-selected-session proc chat file))
          chat)
      (error
       (message "pi: failed to revive session %s: %s" file
                (error-message-string err))
       nil))))

(defun pi-coding-agent//switch-to-session (persp-name file)
  "Switch to opened session PERSP-NAME, reviving a dead pi process.

A live process is not proof that FILE is loaded: the chat buffer and its
pi process are shared by every unnamed session of a directory, so another
perspective of the same directory may have resumed a different session
into the shared process, a transition may have been skipped while the
process was busy, or (via the layout's buffer fallback) the perspective
may even display another directory's chat buffer.  Besides reviving dead
processes, re-resume FILE whenever the loaded session file differs from
it, and re-assert the layout when the perspective shows a chat buffer of
a different directory, so switching always surfaces the selected session.
When the perspective displays several pi chat buffers (e.g. a named
session started inside a registered perspective), the one whose loaded
session file already matches FILE is preferred, so the switch does not
re-resume a different session into the wrong process."
  (persp-switch persp-name)
  (when-let* ((persp (persp-get-by-name persp-name))
              ((persp-p persp)))
    (let* ((chat (or (cl-find-if
                      (lambda (buf)
                        (equal (plist-get (buffer-local-value
                                           'pi-coding-agent--state buf)
                                          :session-file)
                               file))
                      (pi-coding-agent//chat-buffers-in-persp persp))
                     (pi-coding-agent//chat-buffer-in-persp persp)))
           (file-dir (pi-coding-agent//session-file-cwd file))
           (chat-dir (and chat
                          (with-current-buffer chat
                            (pi-coding-agent--chat-session-directory))))
           (wrong-buffer (and chat file-dir
                              (not (equal
                                    (file-name-as-directory file-dir)
                                    (file-name-as-directory chat-dir)))))
           (stale-process
            (and chat (not wrong-buffer)
                 (let* ((proc (buffer-local-value
                               'pi-coding-agent--process chat))
                        (state (buffer-local-value
                                'pi-coding-agent--state chat)))
                   (or (not (processp proc))
                       (not (process-live-p proc))
                       (not (equal (plist-get state :session-file)
                                   file)))))))
      (when (or (null chat) wrong-buffer stale-process)
        (let ((new-chat (pi-coding-agent//revive-session chat file)))
          (when (and new-chat (not (eq new-chat chat)))
            ;; The perspective was displaying another directory's session
            ;; buffer (drifted in through the layout fallback): pin the
            ;; correct buffers into the pi panes.
            (pi-coding-agent//apply-pi-layout
             new-chat
             (buffer-local-value 'pi-coding-agent--input-buffer new-chat)
             nil nil)))))))

(defun pi-coding-agent//restore-registry-buffers (entry)
  "Replay ENTRY's captured buffer specs through persp's load dispatch.
Pi chat/input specs are skipped (the open path re-creates them).  Each
spec fails open: errors are logged and missing files are not restored
as empty buffers."
  (let ((specs (plist-get (cdr entry) :buffers))
        ;; Consumed dynamically by persp's own loader
        ;; (persp-buffer-from-savelist -> missing-file handlers); the
        ;; binding makes missing files skip instead of creating empty
        ;; buffers.
        (persp-load-buffer-handle-missing-file-functions
         (list (lambda (_) nil))))
    (ignore persp-load-buffer-handle-missing-file-functions)
    (dolist (spec specs)
      (when (and (consp spec)
                 (not (memq (car spec)
                            '(def-buffer-pi-chat def-buffer-pi-input))))
        (condition-case err
            (cl-some (lambda (fn) (funcall fn spec))
                     persp-load-buffer-functions)
          (error
           (message "pi: failed to restore buffer %S: %s"
                    spec (error-message-string err))))))))

(defun pi-coding-agent//current-session-file ()
  "Return the session file of the current perspective, or nil.
Only real perspectives count; the default perspective has no session."
  (when (bound-and-true-p persp-mode)
    (let* ((persp (get-current-persp))
           (name (safe-persp-name persp))
           (entry (assoc name pi-coding-agent//registry)))
      (or (and entry (pi-coding-agent//registry-fill-session-file
                      name (cdr entry)))
          (when (and persp (perspective-p persp))
            (when-let* ((chat (pi-coding-agent//chat-buffer-in-persp persp)))
              (plist-get (buffer-local-value 'pi-coding-agent--state chat)
                         :session-file)))))))

(defun pi-coding-agent//open-session (entry)
  "Open closed session ENTRY: new perspective, pi session, buffers, layout."
  (let* ((file (plist-get entry :file))
         (title (pi-coding-agent//entry-title entry))
         (label (pi-coding-agent//make-persp-label title file))
         (persp-name (pi-coding-agent//unique-persp-name label file)))
    (persp-switch persp-name)
    (pi-coding-agent//registry-put persp-name
                                   :session-file file
                                   :label-locked nil
                                   :buffers nil)
    (pi-coding-agent//registry-save)
    (condition-case err
        (let* ((chat (pi-coding-agent-open-session-file file))
               (input (and chat (buffer-local-value
                                 'pi-coding-agent--input-buffer chat))))
          (pi-coding-agent//restore-registry-buffers
           (assoc persp-name pi-coding-agent//registry))
          ;; Pass the session's own chat/input buffers explicitly: the
          ;; layout fallback otherwise fills the pi panes with whatever
          ;; pi-chat buffer the purpose system considers most recent,
          ;; which can be another perspective's buffer (e.g. a different
          ;; directory's session).
          (pi-coding-agent//apply-pi-layout chat input nil t))
      (error
       ;; Roll back the perspective on failure: kill the pi process and
       ;; any session buffers created before the failure, then the
       ;; perspective itself.
       (when (perspective-p (persp-get-by-name persp-name))
         (let ((persp (persp-get-by-name persp-name)))
           (dolist (buf (pi-coding-agent//exclusive-buffers persp))
             (when (buffer-live-p buf)
               (pi-coding-agent//skip-kill-confirmation-for buf)
               (kill-buffer buf)))
           (persp-kill (list persp-name) t)))
       (pi-coding-agent//registry-remove persp-name)
       (pi-coding-agent//registry-save)
       (user-error "pi: failed to open session: %s"
                   (error-message-string err))))))

(defun pi-coding-agent//open-or-switch (entry)
  "Open closed session ENTRY, or switch to it when already opened.
A live perspective whose chat buffer has settled on the session's file
counts as opened even when its registry entry is stale or absent (e.g.
named sessions started via `pi-coding-agent/open-named-session' inside
a registered perspective).

Remote (TRAMP) session files are opened with the host's verified
executable mapping (`pi-coding-agent//remote-executable-entry-for'),
matching `pi-coding-agent/start-remote-session's spawn: the mapped
node directory is exported into the spawn PATH so pi's
`#!/usr/bin/env node' shebang resolves on the PATH-less TRAMP spawn
shell, and local `-e' extensions are dropped (handled for every
remote spawn by `pi-coding-agent//remote-spawn-start-process').  An
unestablished connection is probed with the bounded ssh deadline
first (`pi-coding-agent//ensure-remote-reachable') — the open fails
with a clear error instead of hanging inside TRAMP's untimeoutable
connection wait."
  (let* ((file (plist-get entry :file))
         (remote-entry (pi-coding-agent//remote-executable-entry-for file))
         ;; `pi-coding-agent-executable' is read deep inside the
         ;; package's spawn path (and the startup version check); binding
         ;; it dynamically here makes a remote open spawn pi exactly
         ;; like `pi-coding-agent/start-remote-session' does.
         (pi-coding-agent-executable
          (if remote-entry
              (pi-coding-agent//remote-spawn-executable remote-entry)
            pi-coding-agent-executable))
         (persp-name (or (pi-coding-agent//registry-persp-name-for-file file)
                         (car (rassoc file (pi-coding-agent//live-session-mappings))))))
    (pi-coding-agent//ensure-remote-reachable file)
    (if persp-name
        (pi-coding-agent//switch-to-session persp-name file)
      (pi-coding-agent//open-session entry))))

(defun pi-coding-agent//switch-to-live-buffer (buf)
  "Switch to the perspective owning live pi chat buffer BUF.
When BUF belongs to no perspective (a session started outside the
persp flow), its session file is opened into a fresh perspective
instead — which reuses the directory's canonical chat buffer — or,
for a fresh session without a file yet, BUF is displayed directly."
  (if-let* ((persp (pi-coding-agent//persp-containing-buffer buf)))
      (let ((name (safe-persp-name persp)))
        (if (perspective-p (persp-get-by-name name))
            (persp-switch name)
          (user-error "The selected session's perspective is gone")))
    (if-let* ((file (plist-get (buffer-local-value
                                'pi-coding-agent--state buf)
                               :session-file))
              ((stringp file))
              ((not (string-empty-p file))))
        (pi-coding-agent//open-or-switch (list :file file))
      (switch-to-buffer buf))))

(defun pi-coding-agent//open-or-switch-target (target)
  "Open or switch to session TARGET from the session pickers.
TARGET is (:buffer BUF) for a live session (switch to the
perspective owning the active chat buffer) or (:entry ENTRY) for a
closed one (open it, switching to it when it is already opened)."
  (cond
   ((plist-get target :buffer)
    (pi-coding-agent//switch-to-live-buffer (plist-get target :buffer)))
   ((plist-get target :entry)
    (pi-coding-agent//open-or-switch (plist-get target :entry)))
   (t (user-error "Invalid session target"))))

(defun pi-coding-agent/switch-session ()
  "List all pi sessions; open the chosen one or switch to it if opened.
The current session is excluded.  Live sessions — the active pi chat
buffers (●) — are listed first, then closed sessions (○, files on
disk not loaded by a live session), with a section boundary between
the two groups: separate \"Live sessions\" / \"Closed sessions\"
sources under helm, header rows otherwise.  Both groups sort by title
(configurable via `pi-coding-agent/session-sort-opened' and
`pi-coding-agent/session-sort-closed').  Picking a live session
switches to its perspective; picking a closed one opens it (reviving
the perspective still registered for it).

Scope: a local context lists LOCAL sessions only — remote sessions
never appear, and no remote file is ever touched, so an unreachable
host cannot block the listing.  Used inside a remote (TRAMP) session,
the list adds that host's sessions: its live chat buffers plus its
closed session files, scanned over the established connection; when
the connection is down, a background probe is fired and the host's
closed sessions reappear in a later listing instead of blocking this
one."
  (interactive)
  (require 'pi-coding-agent)
  (unless (bound-and-true-p persp-mode)
    (user-error "persp-mode is not active — enable the spacemacs-layouts layer"))
  (pi-coding-agent//sync-labels)
  (let* ((remote-prefix (pi-coding-agent//current-session-remote-prefix))
         (remote-scope (or remote-prefix 'local))
         (groups (pi-coding-agent//session-targets nil t t nil remote-scope))
         (live (pi-coding-agent//sort-targets
                (car groups) pi-coding-agent/session-sort-opened))
         (closed (pi-coding-agent//sort-targets
                  (cdr groups) pi-coding-agent/session-sort-closed)))
    (if (and (null live) (null closed))
        (user-error "No other pi sessions found (looked in %s%s)"
                    (expand-file-name pi-coding-agent/session-root)
                    (if (stringp remote-scope)
                        (format "; remote sessions on %s are not connected"
                                (file-remote-p remote-scope 'host))
                      ""))
      (let ((choice (pi-coding-agent//pick-session
                     live closed "Pi session: " nil t)))
        (when choice
          (pi-coding-agent//open-or-switch-target
           (cdr (or (assoc choice live) (assoc choice closed)))))))))

(defun pi-coding-agent/switch-session-in-dir ()
  "Switch to another pi session of the current directory, with its layout.

The directory is the session's own directory inside pi chat/input
buffers, the terminal's working directory in terminal buffers, and
the visited file's directory (else `default-directory') elsewhere.
Lists only that directory's sessions — live (●) first, then closed
(○), with a section boundary between the groups, each sorted by
title — excluding the current one.  A remote directory's closed
sessions are scanned on its host over the established connection
(nothing remote is touched when the host is unreachable — a
background probe re-establishes reachability for a later listing).
Picking a live session switches to its perspective; picking a closed
session opens it in a fresh perspective with its workspace restored.
Either way the pi window
layout (chat/input left, edit right) is applied afterwards."
  (interactive)
  (require 'pi-coding-agent)
  (unless (bound-and-true-p persp-mode)
    (user-error "persp-mode is not active — enable the spacemacs-layouts layer"))
  (pi-coding-agent//sync-labels)
  (let* ((dir (pi-coding-agent//context-directory))
         ;; A remote DIR's sessions live on its host: that host's live
         ;; buffers are admitted (REMOTE-SCOPE) and its closed sessions
         ;; are scanned — but only over an established connection
         ;; (`pi-coding-agent//remote-scan-root' fires a background
         ;; probe and returns nil otherwise, so an unreachable host
         ;; never blocks the listing).
         (remote-prefix (pi-coding-agent--remote-prefix-for-path dir))
         (groups (pi-coding-agent//session-targets
                  dir t t
                  (pi-coding-agent//remote-scan-root remote-prefix)
                  remote-prefix))
         (live (pi-coding-agent//sort-targets
                (car groups) pi-coding-agent/session-sort-opened))
         (closed (pi-coding-agent//sort-targets
                  (cdr groups) pi-coding-agent/session-sort-closed)))
    (if (and (null live) (null closed))
        (user-error "No other pi sessions found in %s"
                    (abbreviate-file-name (directory-file-name dir)))
      (let ((choice (pi-coding-agent//pick-session
                     live closed
                     (format "Pi session in %s: "
                             (abbreviate-file-name (directory-file-name dir)))
                     nil t)))
        (when choice
          (pi-coding-agent//open-or-switch-target
           (cdr (or (assoc choice live) (assoc choice closed))))
          ;; Re-assert the pi window layout for the switched-to session
          ;; (chat/input left, edit right), putting whatever buffer the
          ;; switch restored as current into the edit pane.  The
          ;; most-recent-buffer fallback is restricted to the switched-to
          ;; perspective so buffers from other workspaces never leak in.
          (when-let* ((persp (get-current-persp))
                      ((perspective-p persp))
                      (chat (pi-coding-agent//chat-buffer-in-persp persp)))
            (pi-coding-agent//apply-pi-layout
             chat
             (buffer-local-value 'pi-coding-agent--input-buffer chat)
             (current-buffer) t)))))))

;; ---------------------------------------------------------------------
;; New session

(defun pi-coding-agent//context-directory ()
  "The \"current directory\" for session commands (never prompts itself).
Inside pi chat/input buffers the session's recorded directory; inside
terminal buffers the terminal's working directory (vterm via its
`/proc/<pid>/cwd', other terminal modes keep `default-directory' in
sync); elsewhere the visited file's directory, else
`default-directory'."
  (cond
   ((derived-mode-p 'pi-coding-agent-chat-mode 'pi-coding-agent-input-mode)
    (condition-case nil
        (pi-coding-agent--session-directory)
      (error default-directory)))
   ((pi-coding-agent//terminal-buffer-p)
    (if (and (derived-mode-p 'vterm-mode)
             (get-buffer-process (current-buffer)))
        (or (pi-coding-agent//vterm-process-directory
             (get-buffer-process (current-buffer)))
            default-directory)
      default-directory))
   (t (or (and buffer-file-name (file-name-directory buffer-file-name))
          default-directory))))

(defun pi-coding-agent//live-session-in-dir-p (dir)
  "Return non-nil when DIR has a live unnamed pi session."
  (when-let* ((chat (pi-coding-agent--find-session dir)))
    (let ((proc (buffer-local-value 'pi-coding-agent--process chat)))
      (and (processp proc) (process-live-p proc)))))

(defconst pi-coding-agent//new-session-candidate "✚ New session"
  "Completing-read candidate for starting a fresh pi session.")

(defun pi-coding-agent//read-new-session-name (dir)
  "Prompt for the name of a fresh pi session in DIR.
Returns the trimmed name, or nil when the user wants an unnamed
session (empty input).  An unnamed session is refused later by
`pi-coding-agent//start-fresh-session' when DIR already runs a live
unnamed session."
  (let ((name (string-trim
               (read-string
                (format "New session name in %s (empty for unnamed): "
                        (abbreviate-file-name (directory-file-name dir)))))))
    (and (not (string-empty-p name)) name)))

(defun pi-coding-agent//new-session-choice (dir &optional root)
  "Choose between DIR's existing sessions and a fresh session.
Returns (existing . TARGET) when an existing session was chosen,
(new . NAME) when a fresh session named NAME (nil = unnamed) should
be started.  ROOT overrides the scanned session root (see
`pi-coding-agent//session-entries'); it is how the remote-session flow
scans the chosen host's own session directory.

With no existing sessions (none live, none closed) a fresh session
is chosen directly; when DIR already runs a live unnamed session
whose file pi has not written yet, a name is prompted first (parallel
sessions need a name).  With existing sessions, they are offered
through the unified session picker — live (●) first, then closed
(○), with a section boundary between the groups, each sorted by
title — plus the \"✚ New session\" candidate and free-form input
(any non-matching name) both starting a fresh named session; an
empty input starts an unnamed session."
  (let* ((groups (pi-coding-agent//session-targets
                  dir t nil root
                  ;; A remote DIR's live sessions live on its host:
                  ;; admit that host's chat buffers (directory-scoped
                  ;; lists get their closed entries from ROOT itself,
                  ;; not from the scope).
                  (pi-coding-agent--remote-prefix-for-path dir)))
         (live (pi-coding-agent//sort-targets
                (car groups) pi-coding-agent/session-sort-opened))
         (closed (pi-coding-agent//sort-targets
                  (cdr groups) pi-coding-agent/session-sort-closed)))
    (if (and (null live) (null closed))
        (cons 'new (and (pi-coding-agent//live-session-in-dir-p dir)
                        (pi-coding-agent//read-new-session-name dir)))
      (let* ((extra (list (cons pi-coding-agent//new-session-candidate nil)))
             (choice (pi-coding-agent//pick-session
                      live closed
                      (format "Pi session in %s (type a new name for a new session): "
                              (abbreviate-file-name (directory-file-name dir)))
                      nil nil (list (cons "New session" extra))))
             (target (cdr (assoc choice (append live closed)))))
        (cond
         (target
          (cons 'existing target))
         ((string= choice pi-coding-agent//new-session-candidate)
          (cons 'new (pi-coding-agent//read-new-session-name dir)))
         ((or (null choice) (string-empty-p choice))
          (cons 'new nil))
         (t
          (cons 'new (let ((name (string-trim choice)))
                       (and (not (string-empty-p name)) name)))))))))

(defun pi-coding-agent//start-fresh-session (dir &optional name)
  "Start a brand-new pi session in DIR as its own perspective.
NAME (optional, trimmed) opens a named parallel session, labelled
NAME and label-locked; without NAME an unnamed session is started
(labelled \"New session · DIR\") and refused when DIR already runs a
live unnamed session — the package allows one unnamed session per
directory.  Creates and switches to the perspective, starts the pi
process via `pi-coding-agent--setup-session' (fresh, no resume),
registers the registry entry, and applies the pi window layout.
Returns the chat buffer; on failure the fresh perspective is rolled
back and an error signalled."
  (let* ((name (and (stringp name)
                    (not (string-empty-p (string-trim name)))
                    (string-trim name)))
         (dir (file-name-as-directory
               (pi-coding-agent--route-preserving-expand-file-name dir)))
         (label (if name
                    name
                  (format "New session · %s"
                          (abbreviate-file-name (directory-file-name dir)))))
         (persp-name (pi-coding-agent//unique-persp-name label nil)))
    (when (and (null name) (pi-coding-agent//live-session-in-dir-p dir))
      (user-error "A pi session is already running in %s — give a session \
name for a parallel session" dir))
    (persp-switch persp-name)
    ;; Everything between the perspective switch and the finished
    ;; layout is inside the guard: any failure (process startup or the
    ;; window-purpose layout, which can hit transient frame errors)
    ;; rolls the fresh perspective back so a retry starts clean.
    (let ((chat
           (condition-case err
               (let ((chat (pi-coding-agent--setup-session dir name)))
                 (pi-coding-agent//registry-put persp-name
                                                :session-file nil
                                                :label-locked (and name t)
                                                :buffers nil)
                 (pi-coding-agent//registry-save)
                 (let ((input (buffer-local-value 'pi-coding-agent--input-buffer chat)))
                   (pi-coding-agent//apply-pi-layout chat input nil t))
                 chat)
             (error
              (when (perspective-p (persp-get-by-name persp-name))
                (persp-kill (list persp-name) t))
              (user-error "pi: failed to start session: %s"
                          (error-message-string err))))))
      chat)))

(defun pi-coding-agent/start-new-session ()
  "Start a new pi session in a user-chosen directory, or open an existing one.

Always prompts for the directory (unlike `pi-coding-agent/layout',
which reuses the recorded directory inside pi buffers); the prompt
default follows the layout's directory logic.  When the directory has
existing sessions, they are offered for selection — live (●) first,
then closed (○), with a section boundary between the groups, each
sorted by title — via the unified session picker, so it works under
helm, ivy, vertico, or the plain minibuffer.  Picking an existing
session opens it (or switches to it when already opened), with its
layout; typing a new session name — or picking the \"✚ New
session\" candidate and entering one — starts a fresh named
session; an empty name starts an unnamed session, refused when the
directory already runs a live unnamed session.  With no existing
sessions a fresh unnamed session is started directly."
  (interactive)
  (require 'pi-coding-agent)
  (unless (bound-and-true-p persp-mode)
    (user-error "persp-mode is not active — enable the spacemacs-layouts layer"))
  (let* ((default-dir (pi-coding-agent//context-directory))
         (dir (read-directory-name "Start new pi session in directory: "
                                   default-dir default-dir t))
         (dir (pi-coding-agent--route-preserving-expand-file-name dir))
         (choice (pi-coding-agent//new-session-choice dir)))
    (pcase choice
      (`(existing . ,target)
       (pi-coding-agent//open-or-switch-target target))
      (`(new . ,name)
       (pi-coding-agent//start-fresh-session dir name)))))

;; ---------------------------------------------------------------------
;; Remote sessions (TRAMP)
;;
;; `pi-coding-agent/start-remote-session' (SPC a i m) starts a session
;; on a remote host the way `pi-coding-agent/start-new-session' does
;; locally: choose a host from the ssh config (a single configured
;; host is used without prompting), choose the remote directory
;; (default: the host's home), then the normal new-session flow —
;; existing sessions of that directory first (the closed list is
;; scanned on the remote host), a fresh session otherwise.
;;
;; The pi process itself runs on the remote host through TRAMP: the
;; package's `pi-coding-agent--start-process' detects the remote
;; prefix in the session directory and starts pi over ssh
;; (`make-process' with :file-handler and a ready-marker protocol),
;; so the remote host needs the pi CLI installed and reachable via
;; `ssh HOST'.

(defun pi-coding-agent//ssh-config-include-files (patterns file)
  "Return readable files named by ssh config `Include' PATTERNS.
PATTERNS is the raw value of an `Include' directive in FILE.
`~' references and glob(7) wildcards are expanded; relative paths
resolve against `~/.ssh' (a user config), per ssh_config(5).
Unreadable or missing files are skipped."
  (let ((base (if (string-prefix-p "/etc/" (expand-file-name file))
                  "/etc/ssh"
                "~/.ssh"))
        files)
    (dolist (pat (split-string patterns "[[:space:]]+" t))
      (let* ((pat (expand-file-name pat base))
             (matches (if (string-match-p "[*?\\[]" pat)
                          (file-expand-wildcards pat t)
                        (list pat))))
        (dolist (m matches)
          (when (file-readable-p m)
            (push m files)))))
    (nreverse files)))

(defun pi-coding-agent//ssh-config-parse (&optional files depth)
  "Parse ssh config FILES, returning (HOSTS . INFO).
FILES is a string or list of strings; nil means
`pi-coding-agent/ssh-config-file'.  HOSTS lists the plain host names
in config order — wildcard and negation patterns (containing `*',
`?', `[' or `!') and `Match' blocks are skipped — deduplicated.
INFO is an alist mapping each host to (HOSTNAME . USER) taken from
its block; option lines attach to every plain pattern of the
current `Host' line.  `Include' directives are followed recursively
(depth-capped)."
  (let* ((files (cond ((null files)
                       (list (expand-file-name pi-coding-agent/ssh-config-file)))
                      ((stringp files) (list files))
                      (t files)))
         (hosts '())
         (info '()))
    (dolist (file files)
      (when (and (< (or depth 0) 10)
                 (file-readable-p file))
        (with-temp-buffer
          (insert-file-contents file)
          (let ((cur nil)        ; plain patterns of the current Host line
                (in-match nil))  ; inside a `Match' block: skip Hosts
            (goto-char (point-min))
            (while (re-search-forward
                    "^[[:space:]]*\\([A-Za-z][A-Za-z0-9-]*\\)[[:space:]]+\\(.*\\)$"
                    nil t)
              (let* ((kw (downcase (match-string 1)))
                     (rest (string-trim (match-string 2))))
                (pcase kw
                  ("match"
                   (setq in-match t cur nil))
                  ("host"
                   (setq in-match nil cur nil)
                   (dolist (pat (split-string rest "[[:space:]]+" t))
                     (when (string-match-p "\\`[A-Za-z0-9._-]+\\'" pat)
                       (push pat hosts)
                       (push pat cur))))
                  ("include"
                   (unless in-match
                     (let ((sub (pi-coding-agent//ssh-config-parse
                                 (pi-coding-agent//ssh-config-include-files
                                  rest file)
                                 (1+ (or depth 0)))))
                       ;; hosts/info are kept reversed; the include's
                       ;; result must be spliced BEFORE the current
                       ;; prefix so the final nreverse restores config
                       ;; order.
                       (setq hosts (nconc (nreverse (car sub)) hosts)
                             info (nconc (nreverse (cdr sub)) info)))))
                  ((or "hostname" "user")
                   (when (and cur (not in-match))
                     (dolist (h cur)
                       (let ((cell (assoc h info)))
                         (unless cell
                           (setq cell (cons h (cons nil nil)))
                           (push cell info))
                         (if (string= kw "hostname")
                             (setcar (cdr cell) rest)
                           (setcdr (cdr cell) rest))))))
                  (_
                   ;; Ordinary option (IdentityFile, Port, ...): keep
                   ;; CUR so later HostName/User lines still attach.
                   nil))))))))
    (cons (delete-dups (nreverse hosts))
          (delete-dups info))))

(defun pi-coding-agent//ssh-config-hosts (&optional file)
  "Return the host aliases from the ssh config file.
Only plain `Host' patterns whose block declares a `HostName' field
(an alias pointing at the real DNS name) are returned; entries that
are already direct hostnames, or that only set options like `User'
or `IdentityFile', are filtered out.  See
`pi-coding-agent//ssh-config-parse' for the extraction rules."
  (let* ((parsed (pi-coding-agent//ssh-config-parse file))
         (info (cdr parsed)))
    (cl-remove-if-not
     (lambda (host) (car (cdr (assoc host info))))
     (car parsed))))

(defun pi-coding-agent//ssh-config-host-info (host &optional file)
  "Return (HOSTNAME . USER) for HOST from the ssh config, or nil."
  (cdr (assoc host (cdr (pi-coding-agent//ssh-config-parse file)))))

(defun pi-coding-agent//read-remote-host (hosts)
  "Prompt for one of HOSTS, annotating each with its ssh config info."
  (let* ((info (cdr (pi-coding-agent//ssh-config-parse)))
         ;; `completion-extra-properties' is read by the completion UI
         ;; (vertico, Emacs's own *Completions*) during the minibuffer
         ;; session, which runs inside this dynamic extent.
         (completion-extra-properties
          (list :annotation-function
                (lambda (cand)
                  (when-let* ((cell (assoc cand info)))
                    (let ((hostname (car (cdr cell)))
                          (user (cdr (cdr cell))))
                      (concat "  "
                              (and hostname (format "(HostName %s)" hostname))
                              (and user (format " (user %s)" user)))))))))
    (completing-read "Remote host: " hosts nil t nil nil nil)))

(defun pi-coding-agent//remote-session-root (dir)
  "Return the pi session root on DIR's remote host, or nil for a local DIR.
Uses the remote default agent directory (~/.pi/agent/sessions); the
local PI_AGENT_DIR override is not propagated to remote pi processes
(TRAMP does not forward environment), so it is not applied here."
  (when-let* ((prefix (pi-coding-agent--remote-prefix dir)))
    (concat prefix "~/.pi/agent/sessions/")))

(defun pi-coding-agent//remote-login-args (timeout)
  "Full ssh login args for the `login-args' connection property.
The property REPLACES the method's args, so the complete ssh arg
list is rebuilt: `-l %u' / `-p %p' specs, an added
`-o ConnectTimeout=TIMEOUT' option (TIMEOUT nil keeps the ssh
method default), the `%c' ControlMaster specifier is DROPPED, and
an explicit remote command `exec /bin/sh -i' is appended.

Why no `%c' (ControlMaster): macOS's ssh detaches when it becomes
a connection-share master for a process without a controlling
terminal (setsid + stdout to /dev/null), so the remote shell's
output never reaches TRAMP, which waits for it forever.

Why the remote command: TRAMP recognizes the connection by the
remote shell's prompt (`tramp-shell-prompt-pattern' requires the
prompt to end with `#', `%', `>' or similar).  The default ssh
method runs the remote LOGIN shell, whose rc files (powerline,
oh-my-zsh, ...) often draw prompts that never match — TRAMP then
waits forever, again un-timeoutable.  `exec /bin/sh -i' runs a
plain shell instead (no .zshrc/.bashrc games) that prints a
recognized prompt; TRAMP then switches to its own clean shell."
  (append (list (list "-l" "%u") (list "-p" "%p"))
          (and timeout (list (list "-o" (format "ConnectTimeout=%d" timeout))))
          (list (list "-e" "none") (list "%h")
                (list "exec") (list "/bin/sh" "-i"))))

(defun pi-coding-agent//remote-host-probe (host &optional timeout)
  "Probe HOST's ssh reachability with a bounded asynchronous subprocess.
Run `ssh HOST true' with `-o BatchMode=yes' and `-o
ConnectTimeout=TIMEOUT' (default `pi-coding-agent/remote-connect-timeout',
minimum 1s) asynchronously, and hard-kill the probe at the
deadline.  Return (RESULT . DIAGNOSTIC): RESULT is `reachable'
(exit 0), `auth' (host answered but rejected BatchMode
authentication — TRAMP can prompt interactively) or `unreachable'
(killed at the deadline, or ssh failed); DIAGNOSTIC is ssh's stderr,
possibly empty.

Why not just connect: TRAMP's connection timeouts cannot abort a
Why not just connect: TRAMP's connection timeouts cannot abort a
connection whose ssh stays alive but silent.  TRAMP 2.7 waits in
`tramp-accept-process-output' with JUST-THIS-ONE, which suspends
timer dispatch, so neither ssh's ConnectTimeout (which does not
bound name resolution anyway) nor `tramp-connection-timeout' fires;
Emacs freezes — observed with mDNS names (`.local') that hang in
name-resolution retries.  The probe runs as an ordinary asynchronous
subprocess, where the kill deadline is reliably enforced, and only
hands over to TRAMP once `ssh HOST' has been seen to complete.

The remote command is `printf %s\\n \"$HOME\"' rather than a
plain `true' so a successful probe also reports the remote home
directory (the DIAGNOSTIC of a `reachable' result); the caller uses
it to make user-private bin directories visible to TRAMP."
  (let* ((timeout (max 1 (or timeout
                             pi-coding-agent/remote-connect-timeout
                             20)))
         (outbuf (generate-new-buffer " *pi-remote-probe stdout*"))
         (errbuf (generate-new-buffer " *pi-remote-probe stderr*"))
         result)
    (unwind-protect
        (condition-case err
            (let* ((proc (make-process
                          :name "pi-remote-probe"
                          :buffer outbuf
                          :stderr errbuf
                          :connection-type 'pipe
                          :noquery t
                          :command (list "ssh" "-o" "BatchMode=yes"
                                         "-o" (format "ConnectTimeout=%d" timeout)
                                         host "printf '%s\\n' \"$HOME\"")))
                   (deadline (+ (float-time) timeout)))
              (while (and (process-live-p proc)
                          (< (float-time) deadline))
                ;; No JUST-THIS-ONE argument: timers must keep running
                ;; so the deadline below is enforced.
                (accept-process-output proc 0.25))
              (cond
               ((process-live-p proc)
                (delete-process proc)
                (setq result
                      (cons 'unreachable (format "no response within %ds" timeout))))
               ((zerop (process-exit-status proc))
                (setq result
                      (cons 'reachable
                            (string-trim
                             (with-current-buffer outbuf
                               (buffer-string))))))
               ((= 255 (process-exit-status proc))
                (let ((diag (string-trim
                             (concat (with-current-buffer outbuf
                                       (buffer-string))
                                     " "
                                     (with-current-buffer errbuf
                                       (buffer-string))))))
                  (if (string-match-p
                       (rx (or "Permission denied" "publickey"
                               "passphrase" "HOST KEY VERIFICATION FAILED"
                               "authenticity"))
                      diag)
                      ;; Host answered; authentication was merely
                      ;; refused non-interactively.  TRAMP can prompt.
                      (setq result (cons 'auth diag))
                    (setq result (cons 'unreachable diag)))))
               (t (setq result
                        (cons 'unreachable
                              (format "ssh exited with status %d"
                                      (process-exit-status proc)))))))
          (file-error
           (setq result (cons 'unreachable (error-message-string err)))))
      (dolist (buf (list outbuf errbuf))
        (when (buffer-live-p buf)
          (kill-buffer buf))))
    result))

(defun pi-coding-agent//remote-shell-run (script)
  "Run SCRIPT with /bin/sh -c on the live TRAMP connection.
`default-directory' must be a remote directory when called.
Returns (EXIT-STATUS . TRIMMED-OUTPUT); the process runs over the
already-established connection, so a dead connection fails fast."
  (let ((buf (generate-new-buffer " *pi-remote-shell*")))
    (unwind-protect
        (cons (process-file "sh" nil buf nil "-c" script)
              (string-trim
               (with-current-buffer buf
                 (buffer-substring-no-properties (point-min) (point-max)))))
      (when (buffer-live-p buf)
        (kill-buffer buf)))))

(defun pi-coding-agent//remote-ask-executable (host name)
  "Ask the user to locate executable NAME on remote HOST.
Completes over the remote file system, then verifies the chosen
path is remotely executable.  Loops until a valid path is given or
the user quits; returns the absolute remote path or nil."
  (let ((root (format "/ssh:%s:" host))
        (prompt (format "%s executable on %s — locate it (C-g to abort): "
                        name host)))
    (catch 'located
      (dotimes (_ 3)
        (let ((answer (condition-case nil
                          (read-file-name prompt root nil t)
                        (quit (user-error "pi: cannot continue without %s on %s"
                                          name host)))))
          (when (and (stringp answer) (not (string-empty-p answer))
                     (file-executable-p answer))
            (throw 'found answer))
          (message "Not an executable: %s" answer)))
      (user-error "pi: cannot continue without %s on %s" name host))))

(defun pi-coding-agent//remote-verify-pi (host pi-path node-path)
  "Verify that pi at PI-PATH runs on HOST; return its version line.
Runs `pi --version' over the live connection; NODE-PATH (optional)
is the mapped node binary whose directory is prepended to PATH so
pi's `#!/usr/bin/env node' shebang resolves.  Returns the trimmed
version output, or nil when the run fails."
  (pcase (pi-coding-agent//remote-shell-run
          (format "%s%s --version"
                  (if node-path
                      (format "PATH=%s:$PATH; export PATH; "
                              (shell-quote-argument
                               (directory-file-name
                                (file-name-directory node-path))))
                    "")
                  (tramp-shell-quote-argument pi-path)))
    (`(0 . ,out) (and (not (string-empty-p out)) out))))

(defun pi-coding-agent//remote-locate-executables (host &optional home)
  "Locate the pi and node executables on remote HOST before starting pi.
The live TRAMP connection to HOST must be established.  The saved
mapping in `pi-coding-agent/remote-executables' is consulted and
re-verified first (the pi binary must still exist and actually
run), then the connection's PATH and common install locations are
searched, and finally the user is asked to locate the binary
interactively.  A candidate is only accepted after it has been
verified working by running it remotely; the mapping for HOST is
then updated and persisted with `customize-save-variable'.
Returns (PI-PATH . NODE-PATH); NODE-PATH is nil when node is only
needed through PATH."
  (let* ((root (format "/ssh:%s:" host))
         (home (and home (directory-file-name home)))
         (remote (lambda (p) (concat root p)))
         (entry (alist-get host pi-coding-agent/remote-executables nil nil #'string-equal))
         (default-directory root)
         pi-path node-path)
    ;; 1. Saved mapping: re-verify that the pi binary still exists
    ;;    and actually runs before trusting it.
    (when (and entry (stringp (car entry))
               (file-executable-p (funcall remote (car entry))))
      (setq pi-path (car entry) node-path (cdr entry)))
    (when (and pi-path
               (not (pi-coding-agent//remote-verify-pi host pi-path node-path)))
      (setq pi-path nil))
    ;; 2. Search the connection's PATH and common install locations.
    (unless pi-path
      (let ((found (cdr (pi-coding-agent//remote-shell-run "command -v pi 2>/dev/null"))))
        (when (and (string-prefix-p "/" found) (file-executable-p (funcall remote found)))
          (setq pi-path found))))
    (unless pi-path
      (dolist (dir (delq nil (list (and home (concat home "/.local/bin"))
                                   (and home (concat home "/bin"))
                                   "/usr/local/bin" "/opt/homebrew/bin")))
        (when (and (not pi-path)
                   (file-executable-p (funcall remote (concat dir "/pi"))))
          (setq pi-path (concat dir "/pi")))))
    ;; 3. Ask the user to locate it.
    (while (not pi-path)
      (let ((answer (read-file-name
                     (format "pi executable not found on %s - locate it (C-g to abort): " host)
                     root nil t nil #'file-executable-p)))
        (if (file-executable-p answer)
            (setq pi-path (or (file-remote-p answer 'localname) answer))
          (message "Not an executable: %s" answer))))
    ;; 4. node: pi's `#!/usr/bin/env node' shebang resolves it through
    ;; PATH; record where it lives when it is not on the default PATH.
    (unless node-path
      (let ((found (pi-coding-agent//remote-shell-run "command -v node 2>/dev/null")))
        (when (and (eq (car found) 0) (string-prefix-p "/" (cdr found)))
          (setq node-path (cdr found)))))
    (unless node-path
      (dolist (dir (delq nil (list (and home (concat home "/.local/bin"))
                                   "/usr/local/bin" "/usr/bin"
                                   (and home (concat home "/.bun/bin")))))
        (when (and (not node-path)
                   (file-executable-p (funcall remote (concat dir "/node"))))
          (setq node-path (concat dir "/node")))))
    ;; 5. Verify the whole chain actually works before recording it.
    (unless (pi-coding-agent//remote-verify-pi host pi-path node-path)
      (let ((answer (and (yes-or-no-p
                          (format "pi at %s on %s did not run - likely its node runtime is missing. Locate node on %s? "
                                  pi-path host host))
                         (read-file-name (format "node executable on %s: " host)
                                         root nil t nil #'file-executable-p))))
        (setq node-path (and answer (file-remote-p answer 'localname)))
        (unless (pi-coding-agent//remote-verify-pi host pi-path node-path)
          (user-error "pi at %s on %s still does not run (node: %s) - check `ssh %s' and install pi + node"
                      pi-path host (or node-path "missing") host))))
    ;; 6. Persist the verified mapping for this host.
    (setq pi-coding-agent/remote-executables
          (cons (cons host (cons pi-path node-path))
                ;; String keys: `assoc-delete-all', not assq — eq never
                ;; matches strings, so an assq-based delete never
                ;; removed the previous entry and the saved custom
                ;; accumulated a duplicate per re-verification.
                (assoc-delete-all host pi-coding-agent/remote-executables)))
    (customize-save-variable 'pi-coding-agent/remote-executables
                             pi-coding-agent/remote-executables)
    (message "pi on %s: %s%s" host pi-path
             (if node-path (format " (node: %s)" node-path) ""))
    (cons pi-path node-path)))

(defun pi-coding-agent//remote-extra-args (host)
  "Extra pi arguments usable on remote HOST.
Drops every \"-e LOCAL-FILE\" pair whose file lives on this machine
(not a remote file name) — a remote pi process cannot load it, and
the Emacs bridge extension in particular could not work remotely
anyway: its tool drives this Emacs through `emacsclient', which
would have to run on HOST and reach this Emacs' server socket.  All
other arguments are passed through unchanged."
  (let (out (tail pi-coding-agent-extra-args))
    (while tail
      (let ((arg (pop tail)))
        (if (and (string-equal arg "-e") tail)
            (let ((path (pop tail)))
              (if (file-remote-p path)
                  (setq out (append out (list "-e" path)))
                (message
                 "pi: skipping extension %s for the session on %s (local-only; the bridge needs emacsclient, which only exists here)"
                 path host)))
          (setq out (append out (list arg))))))
    out))

(defun pi-coding-agent/start-remote-session (&optional host)
  "Start a pi session on a remote host from `pi-coding-agent/ssh-config-file'.

Prompts for the host among the aliases of the ssh config file —
plain (non-wildcard) `Host' entries whose block declares a
`HostName' field; with exactly one alias it is used without
prompting.  Then behaves like `pi-coding-agent/start-new-session'
on that host: prompts for the remote directory (default: the host's
home), offers that directory's existing sessions — live first, then
closed, scanned on the remote host — and starts a fresh session
otherwise.

The pi process runs on the remote host through TRAMP (ssh method),
so the host must be reachable via `ssh HOST' with the pi CLI
installed."
  (interactive)
  (require 'pi-coding-agent)
  (unless (bound-and-true-p persp-mode)
    (user-error "persp-mode is not active — enable the spacemacs-layouts layer"))
  (let* ((timeout pi-coding-agent/remote-connect-timeout)
         (hosts (pi-coding-agent//ssh-config-hosts))
         (host (or host
                   (pcase (length hosts)
                     (0 (user-error
                         "No host aliases in %s — add Host entries with a HostName field pointing at the real DNS name (or use SPC a i n with a /ssh:HOST:path directory)"
                         (expand-file-name pi-coding-agent/ssh-config-file)))
                     (1 (car hosts))
                     (_ (pi-coding-agent//read-remote-host hosts)))))
         ;; Bound while the connection is established: ssh's own
         ;; ConnectTimeout (via the login-args property, which
         ;; replaces the method args) aborts an unreachable or
         ;; unresponsive host instead of hanging; TRAMP's overall
         ;; timeout is bound to the same value for good measure.
         (tramp-connection-timeout (or timeout
                                       (and (boundp 'tramp-connection-timeout)
                                            tramp-connection-timeout)))
         (tramp-connection-properties
          (if timeout
              (cons (list (format "/ssh:%s:" host)
                          "login-args"
                          (pi-coding-agent//remote-login-args timeout))
                    tramp-connection-properties)
            tramp-connection-properties))
         ;; Reachability probe BEFORE any TRAMP work: an ssh that stays
         ;; alive but silent (mDNS name stuck in name-resolution
         ;; retries, hung auth) would freeze Emacs inside TRAMP's
         ;; wait loop, whose timeouts cannot fire while timers are
         ;; suspended.  The probe's kill deadline turns that into a
         ;; clean error; see its doc string.  A successful probe also
         ;; reports the remote home directory, used below to make the
         ;; user's private bin directories visible on the connection.
         (probe (progn
                  (message "Probing %s (ssh, %ds timeout) ..." host timeout)
                  (pi-coding-agent//remote-host-probe host timeout)))
         (_ (pcase probe
              (`(reachable . ,_) nil)
              (`(auth . ,diag)
               (message "%s is reachable; ssh authentication will be handled by TRAMP%s"
                        host (if (string-empty-p diag) ""
                               (format " (%s)" diag))))
              (`(unreachable . ,diag)
               (user-error
                "Cannot reach %s via ssh within %ds%s — check `ssh %s' in a terminal"
                host timeout
                (if (string-empty-p diag) ""
                  (format ": %s" diag))
                host))))
         ;; Force pipes instead of a pty for the login: TRAMP's default
         ;; (pty) makes ssh open an INTERACTIVE remote login shell,
         ;; whose rc files (e.g. powerline/oh-my-zsh zsh prompts) draw
         ;; fancy prompts that never match `tramp-shell-prompt-pattern'
         ;; — TRAMP then waits for a recognizable prompt forever, and
         ;; its wait loop cannot be timed out (timers suspended while
         ;; waiting for the single process).  With pipes the remote
         ;; shell stays non-interactive (zsh never sources .zshrc), so
         ;; TRAMP connects cleanly and fast.
         (tramp-process-connection-type nil)
         ;; Make user-private bin directories visible to everything
         ;; riding this connection: TRAMP exports the remote PATH from
         ;; `tramp-remote-path' during login, and its default covers
         ;; only system directories.  A pi installed in ~/.local/bin
         ;; (npm -g with the default prefix) would otherwise not be
         ;; found by the RPC process ("exec: pi: not found", exit
         ;; 127), because the plain login shell we force for TRAMP
         ;; skips the rc files that set up the user's PATH.
         ;; The directories are spelled out absolutely (from the
         ;; probe's home report): TRAMP validates entries with a
         ;; quoted remote `test -d', in which tilde never expands, so
         ;; a literal "~/.local/bin" entry would always be dropped.
         ;; Non-existent directories are dropped by TRAMP, so this is
         ;; harmless on hosts without them.
         (tramp-remote-path
          (append (and (stringp (cdr probe))
                       (string-prefix-p "/" (string-trim (cdr probe)))
                       (let ((home (directory-file-name
                                    (string-trim (cdr probe)))))
                         (list (concat home "/.local/bin")
                               (concat home "/bin"))))
                  tramp-remote-path))
         ;; Pre-flight: connect once and resolve the remote home
         ;; BEFORE the directory prompt, so the first TRAMP connection
         ;; happens at a predictable point after a successful probe,
         ;; with a clear error instead of inside read-file-name's
         ;; default expansion.  The canonical home (no `~') also keeps
         ;; the prompt itself free of hidden connections.
         ;; `tramp-set-connection-property' ensures the login-args
         ;; (see `pi-coding-agent//remote-login-args') also apply when
         ;; a connection cache for this host already exists — pushed
         ;; `tramp-connection-properties' entries only seed freshly
         ;; created cache tables.
         (_ (ignore-errors
              (let ((vec (tramp-dissect-file-name (format "/ssh:%s:" host))))
                ;; The login-args must be visible to TRAMP even when a
                ;; connection cache for this host already exists — pushed
                ;; `tramp-connection-properties' entries only seed freshly
                ;; created cache tables.  The "remote-path" cache is
                ;; dropped for the same reason: it is saved persistently,
                ;; and a stale entry computed without the user-private
                ;; directories would shadow the binding above.
                (tramp-flush-connection-property vec "remote-path")
                (tramp-set-connection-property
                 vec "login-args"
                 (pi-coding-agent//remote-login-args timeout)))))
         (home (condition-case err
                   (progn
                     (message "Connecting to %s ..." host)
                     (pi-coding-agent//normalized-dir
                      (format "/ssh:%s:~" host)))
                 (error
                  (user-error
                   "Cannot reach %s via ssh: %s — check `ssh %s' in a terminal (password? host key? network?)"
                   host (error-message-string err) host))))
         ;; Locate (or re-verify) the remote pi and node executables
         ;; BEFORE starting the pi agent: the spawn runs in a shell
         ;; whose PATH is not the user's interactive one (the login
         ;; shell is bypassed on purpose), so `pi' may not be found
         ;; there even though it works in an ssh login session.  The
         ;; located paths are verified by actually running pi remotely,
         ;; recorded in `pi-coding-agent/remote-executables', and bound
         ;; as the executable below — with the mapped node directory
         ;; exported into the spawn PATH, since pi's
         ;; `#!/usr/bin/env node' shebang would otherwise fail with
         ;; exit 127 ("env: node: No such file or directory") on the
         ;; PATH-less spawn shell — making the pi spawn independent of
         ;; the remote PATH entirely.
         (executables (condition-case err
                          (pi-coding-agent//remote-locate-executables
                           host (file-remote-p home 'localname))
                        (quit (user-error "pi: cancelled — no executable mapping for %s" host))))
         (dir (read-directory-name
               (format "Start pi session on %s in directory: " host)
               home home t))
         (dir (condition-case err
                  (pi-coding-agent//normalized-dir dir)
                (error
                 (user-error "Cannot reach %s: %s"
                             host (error-message-string err)))))
         (choice (pi-coding-agent//new-session-choice
                  dir (pi-coding-agent//remote-session-root dir))))
    (let ((pi-coding-agent-executable
           (pi-coding-agent//remote-spawn-executable executables))
          (pi-coding-agent-extra-args (pi-coding-agent//remote-extra-args host)))
      (pcase choice
        (`(existing . ,target)
         (pi-coding-agent//open-or-switch-target target)
         ;; Cover later re-spawns of the pi process (restart, session
         ;; file re-open) with the verified PATH-independent spawn.
         (when (derived-mode-p 'pi-coding-agent-mode)
           (setq-local pi-coding-agent-executable
                       (pi-coding-agent//remote-spawn-executable
                        executables))))
        (`(new . ,name)
         (let ((chat (pi-coding-agent//start-fresh-session dir name)))
           (when (buffer-live-p chat)
             (with-current-buffer chat
               (setq-local pi-coding-agent-executable
                           (pi-coding-agent//remote-spawn-executable
                            executables))))))))))

;; ---------------------------------------------------------------------
;; Worktree and workspace sessions
;;
;; Two commands turn a git repository (or several) into a fresh
;; worktree under `pi-coding-agent/workspace-root' (default ~/work)
;; and start a new pi session — own perspective, pi window layout —
;; in it:
;;
;; - `pi-coding-agent/new-worktree-session' (SPC a i w): one repo ->
;;   one worktree at ROOT/SUFFIX, session named SUFFIX;
;; - `pi-coding-agent/new-workspace-session' (SPC a i W): one or more
;;   repos -> ROOT/NAME/repos/<repo> worktrees, session named NAME at
;;   ROOT/NAME.
;;
;; Repos are picked with helm (single-select, or multi-select with
;; `pi-coding-agent/repo-mark-key' marking for the workspace command;
;; `completing-read'/`completing-read-multiple' without helm).  The
;; pickers unbind helm's C-SPC/C-@ marking keys, which commonly
;; conflict with input method activation.  Candidates come from the
;; context directory, `projectile-known-projects', and one level
;; under each `pi-coding-agent/repo-roots' entry; any path can be
;; typed instead.  Worktrees are created from the repo's mainline
;; branch — origin/main, else origin/master, else the local
;; main/master — fetched best-effort from origin first
;; (timeout-capped, failures ignored).  A remote-tracking branch
;; lands as a detached HEAD at its tip; a free local branch is
;; checked out attached; otherwise the worktree is created detached
;; at the branch tip.

(defun pi-coding-agent//git-run (dir &rest args)
  "Run `git -C DIR ARGS', sending combined output to the current buffer.

Returns git's exit status (0 = success).  The `timeout' utility caps
network-bound invocations (fetch) when available, so a hung remote
cannot block the command; without `timeout' (non-GNU userland) git
runs unprotected.  Terminal credential prompts are disabled — the
child's stdin is /dev/null anyway, and GIT_TERMINAL_PROMPT=0 makes
git fail instead of waiting."
  (let* ((timeout (executable-find "timeout"))
         (program (or timeout "git"))
         (args (if timeout
                   (append (list "30" "git" "-C" dir) args)
                 (append (list "-C" dir) args)))
         (process-environment (cons "GIT_TERMINAL_PROMPT=0"
                                    process-environment)))
    (apply #'process-file program nil t nil args)))

(defun pi-coding-agent//git-output (dir &rest args)
  "Run git in DIR with ARGS; return trimmed output, or nil on failure."
  (with-temp-buffer
    (when (zerop (apply #'pi-coding-agent//git-run dir args))
      (string-trim (buffer-string)))))

(defun pi-coding-agent//git-repo-root (dir)
  "Return the top-level worktree directory of the git repo containing DIR.
DIR may be any subdirectory.  Returns nil when DIR is not inside a
git repository."
  (when-let* ((root (pi-coding-agent//git-output
                     (expand-file-name dir) "rev-parse" "--show-toplevel"))
              ((file-directory-p root)))
    root))

(defun pi-coding-agent//git-branch-exists-p (repo branch)
  "Return non-nil when REPO has BRANCH (local or remote-tracking)."
  (or (pi-coding-agent//git-output repo "rev-parse" "--verify" "--quiet"
                                   (format "refs/heads/%s" branch))
      (pi-coding-agent//git-output repo "rev-parse" "--verify" "--quiet"
                                   (format "refs/remotes/%s" branch))))

(defun pi-coding-agent//git-default-branch (repo)
  "Return REPO's mainline branch: origin/main, origin/master, local
main, master, or the branch currently checked out — whichever exists
first.  Remote-tracking branches win so worktrees start at the
latest fetched state of the repo's mainline.  Nil when REPO has no
branches at all."
  (cl-find-if
   (lambda (branch) (and (stringp branch) (not (string-empty-p branch))))
   (list (and (pi-coding-agent//git-branch-exists-p repo "origin/main")
              "origin/main")
         (and (pi-coding-agent//git-branch-exists-p repo "origin/master")
              "origin/master")
         (and (pi-coding-agent//git-branch-exists-p repo "main") "main")
         (and (pi-coding-agent//git-branch-exists-p repo "master") "master")
         (pi-coding-agent//git-output repo "symbolic-ref" "--short" "HEAD"))))

(defun pi-coding-agent//git-has-remote (repo remote)
  "Return non-nil when REPO has a git remote named REMOTE."
  (when-let* ((out (pi-coding-agent//git-output repo "remote"))
              (remotes (split-string out "\n" t)))
    (member remote remotes)))

(defun pi-coding-agent//git-fetch-branch (repo branch)
  "Best-effort fetch of BRANCH into REPO, capped by `timeout'.
No-op when REPO has no origin remote.  Fetch failures are logged and
ignored: the worktree falls back to the previously fetched state of
origin/BRANCH."
  (when (pi-coding-agent//git-has-remote repo "origin")
    (let ((remote-branch (if (string-prefix-p "origin/" branch)
                             (substring branch (length "origin/"))
                           branch)))
      (with-temp-buffer
        (unless (zerop (pi-coding-agent//git-run repo "fetch" "origin" remote-branch))
          (message "pi: fetch of %s from origin failed — worktree will use the previously fetched origin/%s"
                   remote-branch remote-branch))))))

(defun pi-coding-agent//workspace-root ()
  "Return the absolute `pi-coding-agent/workspace-root', creating it."
  (let ((root (expand-file-name pi-coding-agent/workspace-root)))
    (make-directory root t)
    root))

(defvar pi-coding-agent-repo-history nil
  "History of repo paths typed into the repo pickers.")

(defun pi-coding-agent//git-repo-p (dir)
  "Return non-nil when DIR looks like a git repo root (has a .git entry).
Cheap check used for candidate listing; the pickers validate the
final selection with `pi-coding-agent//git-repo-root'."
  (file-exists-p (expand-file-name ".git" dir)))

(defun pi-coding-agent//repo-candidates ()
  "Git repo candidates for the repo pickers (abbreviated paths).
Sources, in order: the current context directory,
`projectile-known-projects' (when projectile is loaded), and one
directory level under each entry of `pi-coding-agent/repo-roots'.
Deduplicated; each candidate must have a .git entry."
  (let ((seen (make-hash-table :test #'equal))
        candidates)
    (cl-labels ((add (dir)
                 (let ((dir (expand-file-name dir)))
                   (when (and (file-directory-p dir)
                              (pi-coding-agent//git-repo-p dir)
                              (not (gethash dir seen)))
                     (puthash dir t seen)
                     (push (abbreviate-file-name (directory-file-name dir))
                           candidates)))))
      (add (pi-coding-agent//context-directory))
      (dolist (dir (and (boundp 'projectile-known-projects)
                        (listp projectile-known-projects)
                        projectile-known-projects))
        (add dir))
      (dolist (root pi-coding-agent/repo-roots)
        (let ((root (expand-file-name root)))
          (when (file-directory-p root)
            (dolist (dir (directory-files root t "^[^.]"))
              (add dir)))))
      (nreverse candidates))))

(defun pi-coding-agent//helm-repo-map ()
  "Keymap for the pi repo pickers: `helm-map' minus C-SPC marking.
C-SPC/C-@ (and their marking) are removed so the picker does not
shadow input method activation keys; marking uses
`pi-coding-agent/repo-mark-key' (default C-;) instead."
  (let ((map (make-sparse-keymap))
        (mark-key (or (bound-and-true-p pi-coding-agent/repo-mark-key)
                      "C-;")))
    (set-keymap-parent map helm-map)
    (define-key map (kbd "C-SPC") nil)
    (define-key map (kbd "C-@") nil)
    (define-key map (kbd mark-key) #'helm-toggle-visible-mark-forward)
    map))

(defun pi-coding-agent//helm-pick-repos (candidates prompt)
  "Helm multi-select of repo CANDIDATES with PROMPT.
`pi-coding-agent/repo-mark-key' (C-; by default) marks several
candidates, RET confirms.  Returns the selected strings: the marked
candidates, or the single candidate at point; typed input is
returned verbatim."
  ;; `helm-make-source' is a function (the `helm-build-sync-source'
  ;; macro equivalent) — funcs.el is loaded/compiled before helm is, so
  ;; a macro call would never be expanded and would fail at runtime
  ;; with "Invalid function".
  (require 'helm)
  (helm :sources (helm-make-source "Git repositories" 'helm-source-sync
                   :candidates candidates
                   :must-match nil
                   :keymap (pi-coding-agent//helm-repo-map)
                   :action (lambda (_candidate)
                             (helm-marked-candidates)))
        :buffer "*helm pi git repos*"
        :marked-candidates t
        :prompt prompt))

(defun pi-coding-agent//helm-pick-repo (candidates prompt)
  "Helm single-select of repo CANDIDATES with PROMPT.
Returns the selected candidate string, or the typed input."
  (require 'helm)
  (helm :sources (helm-make-source "Git repository" 'helm-source-sync
                   :candidates candidates
                   :must-match nil
                   :keymap (pi-coding-agent//helm-repo-map)
                   :action 'identity)
        :buffer "*helm pi git repo*"
        :prompt prompt))

(defun pi-coding-agent//pick-repos (prompt)
  "Pick one or more git repos with PROMPT: helm multi-select.
Without helm, falls back to `completing-read-multiple' (candidates
separated by commas).  Returns a list of picked strings; nil when
nothing was picked — with helm this means the user cancelled (C-g)."
  (let* ((cands (pi-coding-agent//repo-candidates))
         (picks (if (featurep 'helm)
                    (pi-coding-agent//helm-pick-repos cands prompt)
                  (completing-read-multiple
                   prompt cands nil nil nil 'pi-coding-agent-repo-history))))
    (cl-remove-if (lambda (s) (string-empty-p (or s ""))) picks)))

(defun pi-coding-agent//pick-repo (prompt)
  "Pick a git repo with PROMPT: helm single-select.
Without helm, falls back to `completing-read'.  Returns the picked
string; nil when the user cancelled (helm) or input was empty
(completing-read returns \"\")."
  (let* ((cands (pi-coding-agent//repo-candidates))
         (pick (if (featurep 'helm)
                   (pi-coding-agent//helm-pick-repo cands prompt)
                 (completing-read prompt cands nil nil nil
                                  'pi-coding-agent-repo-history))))
    pick))

(defun pi-coding-agent//read-git-repo (prompt &optional default-dir)
  "Pick a git repository with PROMPT, re-prompting until it is valid.
Known repos are offered as candidates (see
`pi-coding-agent//repo-candidates'); any directory can be typed
instead.  Empty input falls back to DEFAULT-DIR when it is a
repository.  Returns the repository's top-level directory."
  (let (repo)
    (cl-loop
     for pick = (pi-coding-agent//pick-repo prompt)
     for dir = (cond ((null pick) (keyboard-quit)) ; helm C-g: abort quietly
                     ((string-empty-p pick) (or default-dir ""))
                     (t pick))
     until (and (not (string-empty-p (or dir "")))
                (setq repo (pi-coding-agent//git-repo-root dir)))
     do (message "%s is not inside a git repository — choose again"
                 (abbreviate-file-name (directory-file-name dir))))
    repo))

(defun pi-coding-agent//read-git-repos (prompt)
  "Pick one or more git repositories with PROMPT.
Uses helm multi-select (`pi-coding-agent/repo-mark-key' marks
candidates, RET confirms; known repos are offered, see
`pi-coding-agent//repo-candidates') or `completing-read-multiple'
without helm.  The whole batch is re-offered when any picked entry
is not inside a git repository.  Returns the repository top-level
directories, deduplicated, in selection order."
  (let (picks roots)
    (cl-loop
     do (setq picks (pi-coding-agent//pick-repos prompt))
     while (and picks
                (cl-some #'null
                         (setq roots (mapcar #'pi-coding-agent//git-repo-root
                                             picks))))
     do (message "Not a git repository: %s — choose again"
                 (mapconcat #'identity
                            (cl-loop for pick in picks for root in roots
                                     unless root collect
                                     (abbreviate-file-name
                                      (directory-file-name pick)))
                            ", ")))
    ;; With helm, nil means the user cancelled (C-g); abort quietly
    ;; instead of reporting "no repositories".  The completing-read
    ;; fallback returns nil only on empty input, which is a genuine
    ;; "no repos" result.
    (when (and (null picks) (featurep 'helm))
      (keyboard-quit))
    (cl-remove-duplicates roots :test #'equal)))

(defvar pi-coding-agent-worktree-suffix-history nil
  "History of worktree suffixes entered by the user.")

(defvar pi-coding-agent-workspace-name-history nil
  "History of workspace names entered by the user.")

(defun pi-coding-agent//read-worktree-suffix (root)
  "Prompt for the worktree directory name under ROOT.
Re-prompts while the input is empty or a file/directory of that name
already exists under ROOT.  Returns the suffix, trimmed of
surrounding whitespace and slashes."
  (cl-loop
   for input = (read-string "Worktree suffix: " nil
                            'pi-coding-agent-worktree-suffix-history)
   for suffix = (string-trim input "/ \t\n")
   until (and (not (string-empty-p suffix))
              (not (file-exists-p (expand-file-name suffix root))))
   do (cond ((string-empty-p suffix)
             (message "Worktree suffix must not be empty"))
            (t
             (message "A file or directory named %s already exists in %s — pick another suffix"
                      suffix (abbreviate-file-name (directory-file-name root)))))
   finally return suffix))

(defun pi-coding-agent//create-worktree (repo target branch)
  "Create a git worktree at TARGET from BRANCH of REPO.
TARGET must not exist yet; its parent directories are created.
Stale worktree registrations are pruned first, so a manually deleted
worktree does not block re-creating it.  BRANCH is checked out when
it can be — attached for a free local branch, detached at the branch
tip for a remote-tracking branch — otherwise the worktree is created
detached at BRANCH's tip.  Signals a `user-error' carrying git's
message when the worktree cannot be created."
  (make-directory (file-name-directory target) t)
  (with-temp-buffer
    (pi-coding-agent//git-run repo "worktree" "prune")
    (unless (or (zerop (pi-coding-agent//git-run repo "worktree" "add" target branch))
                (zerop (pi-coding-agent//git-run repo "worktree" "add" "--detach"
                                                 target branch)))
      (user-error "git worktree add failed for %s: %s"
                  (abbreviate-file-name target)
                  (string-trim (buffer-string))))))

(defun pi-coding-agent//unique-name (base taken)
  "Return BASE, or BASE-2/-3/… when BASE is already in TAKEN."
  (let ((name base) (n 1))
    (while (member name taken)
      (setq n (1+ n)
            name (format "%s-%d" base n)))
    name))

(defun pi-coding-agent//worktree-session (repo suffix)
  "Create a worktree of REPO at ROOT/SUFFIX and start a pi session in it.
The repo's mainline branch (see `pi-coding-agent//git-default-branch')
is fetched best-effort and checked out — detached at the
remote-tracking tip when the branch comes from origin, attached when
it is a free local branch.  Then a fresh pi session named SUFFIX
starts in the worktree: own perspective, pi window layout."
  (let* ((root (pi-coding-agent//workspace-root))
         (branch (or (pi-coding-agent//git-default-branch repo)
                     (user-error "No mainline branch (origin/main, origin/master, main, master) found in %s"
                                 (abbreviate-file-name repo))))
         (target (expand-file-name suffix root)))
    (pi-coding-agent//git-fetch-branch repo branch)
    (pi-coding-agent//create-worktree repo target branch)
    (pi-coding-agent//start-fresh-session target suffix)))

(defun pi-coding-agent/new-worktree-session ()
  "Create a fresh git worktree and start a new pi session in it.

Prompts for a git repository — re-prompting until the chosen
directory is inside one — then for a suffix naming the worktree
directory under `pi-coding-agent/workspace-root' (default ~/work).
The repo's mainline branch (origin/main, else origin/master, else
the local main/master) is fetched best-effort and checked out in the
worktree — detached at the remote-tracking tip when the branch comes
from origin, attached when it is a free local branch.  The new pi
session (own perspective, pi window layout) is named after the
suffix."
  (interactive)
  (require 'pi-coding-agent)
  (unless (bound-and-true-p persp-mode)
    (user-error "persp-mode is not active — enable the spacemacs-layouts layer"))
  (let* ((repo (pi-coding-agent//read-git-repo
                "Git repository for the worktree: "
                (pi-coding-agent//context-directory)))
         (suffix (pi-coding-agent//read-worktree-suffix
                  (pi-coding-agent//workspace-root))))
    (pi-coding-agent//worktree-session repo suffix)))

(defun pi-coding-agent//workspace-session (repos name)
  "Create workspace ROOT/NAME with worktrees of REPOS, then a pi session.
Creates ROOT/NAME/repos and one worktree per repository — its
mainline branch (see `pi-coding-agent//git-default-branch'), fetched
best-effort — named after the repository's directory (uniquified
with -2/-3/… on collisions), detached at the remote-tracking tip when
the branch comes from origin, attached when it is a free local
branch.  Then starts a fresh pi session named NAME in the workspace
directory: own perspective, pi window layout.  REPOS must be
non-empty and NAME must not exist under ROOT yet."
  (let* ((root (pi-coding-agent//workspace-root))
         (ws-dir (expand-file-name name root))
         (repos-dir (expand-file-name "repos" ws-dir))
         taken)
    (unless repos
      (user-error "No repositories chosen"))
    (when (file-exists-p ws-dir)
      (user-error "Workspace %s already exists" ws-dir))
    (make-directory repos-dir t)
    (dolist (repo repos)
      (let* ((subdir (pi-coding-agent//unique-name
                      (file-name-nondirectory (directory-file-name repo))
                      taken))
             (branch (or (pi-coding-agent//git-default-branch repo)
                         (user-error "No mainline branch (origin/main, origin/master, main, master) found in %s — workspace left incomplete"
                                     (abbreviate-file-name repo)))))
        (push subdir taken)
        (pi-coding-agent//git-fetch-branch repo branch)
        (pi-coding-agent//create-worktree repo
                                          (expand-file-name subdir repos-dir)
                                          branch)))
    (pi-coding-agent//start-fresh-session ws-dir name)))

(defun pi-coding-agent/new-workspace-session ()
  "Create a fresh workspace with git worktrees and start a new pi session.

Prompts for one or more git repositories — re-prompting until each
chosen directory is inside one; empty input finishes the list — then
for the workspace name.  Creates ROOT/NAME/repos (ROOT =
`pi-coding-agent/workspace-root', default ~/work) with one worktree
per repository (its mainline branch, fetched best-effort) named
after the repository's directory.  The new pi session (own
perspective, pi window layout) is named after the workspace."
  (interactive)
  (require 'pi-coding-agent)
  (unless (bound-and-true-p persp-mode)
    (user-error "persp-mode is not active — enable the spacemacs-layouts layer"))
  (let* ((repos (pi-coding-agent//read-git-repos
                 (format "Git repositories for the workspace (%s marks, RET confirms): "
                         pi-coding-agent/repo-mark-key)))
         (name (string-trim
                (read-string "Workspace name: " nil
                             'pi-coding-agent-workspace-name-history))))
    (when (string-empty-p name)
      (user-error "No workspace name given"))
    (pi-coding-agent//workspace-session repos name)))

;; ---------------------------------------------------------------------
;; Close and delete session

(defun pi-coding-agent//exclusive-buffers (persp)
  "Buffers of PERSP not present in any other real perspective.
Common buffers (injected into every perspective) and buffers shared
with other perspectives are spared.  Note: the nil perspective is nil
itself and `persp-contain-buffer-p' is always true for it, so it must
be excluded from the other-perspective check."
  (let ((others (delq persp
                      (cl-remove-if-not
                       (lambda (p) (and p (perspective-p p)))
                       (mapcar #'persp-get-by-name (persp-names))))))
    (cl-remove-if (lambda (buf)
                    (cl-find-if (lambda (p) (persp-contain-buffer-p buf p))
                                others))
                  (safe-persp-buffers persp))))

(defun pi-coding-agent//skip-kill-confirmation-for (buf)
  "Suppress the package's kill confirmation for BUFFER's session process.
The input buffer also carries the package's kill-buffer query (it
resolves the process through its chat link), so both pi buffer types
need the skip flag before an intentional teardown."
  (let ((proc (with-current-buffer buf
                (or (and (derived-mode-p 'pi-coding-agent-chat-mode
                                        'pi-coding-agent-input-mode)
                         (pi-coding-agent--get-process))
                    (get-buffer-process buf)))))
    (when (processp proc)
      (pi-coding-agent--skip-process-kill-confirmation proc))))

(defun pi-coding-agent//capture-buffer-specs (persp)
  "Capture PERSP's buffers as persp savelist specs via the save dispatch.
Pi chat/input buffers are excluded: the open path re-creates them."
  (let (specs)
    (dolist (buf (safe-persp-buffers persp))
      (when (buffer-live-p buf)
        (let ((spec (cl-some (lambda (fn) (funcall fn buf))
                             persp-save-buffer-functions)))
          (when (and (consp spec)
                     (not (memq (car spec)
                                '(def-buffer-pi-chat def-buffer-pi-input))))
            (push spec specs)))))
    (nreverse specs)))

(defun pi-coding-agent//update-entry-buffers (persp-name persp)
  "Refresh the registry entry's captured buffer specs for PERSP."
  (when-let* ((entry (assoc persp-name pi-coding-agent//registry)))
    (setcdr entry (plist-put (cdr entry) :buffers
                             (pi-coding-agent//capture-buffer-specs persp)))
    (pi-coding-agent//registry-save)))

(defun pi-coding-agent//on-before-switch (&rest _)
  "Capture the leaving perspective's buffers (switch-away checkpoint)."
  (when (bound-and-true-p persp-mode)
    (let* ((persp (get-current-persp))
           (name (safe-persp-name persp)))
      (when (assoc name pi-coding-agent//registry)
        (pi-coding-agent//update-entry-buffers name persp)))))

(defun pi-coding-agent//on-before-kill (persp)
  "Capture a perspective's buffers before it is killed externally."
  (let ((name (safe-persp-name persp)))
    (when (assoc name pi-coding-agent//registry)
      (pi-coding-agent//update-entry-buffers name persp))))

(defun pi-coding-agent//on-kill-emacs ()
  "Capture all live pi perspectives' buffers and save the registry."
  (when (bound-and-true-p persp-mode)
    (dolist (entry pi-coding-agent//registry)
      (when-let* ((persp (persp-get-by-name (car entry)))
                  ((persp-p persp)))
        (pi-coding-agent//update-entry-buffers (car entry) persp))))
  (pi-coding-agent//registry-save))

(defun pi-coding-agent//persp-pi-session-p (name)
  "Return non-nil when perspective NAME is associated with a pi session.
Counts a registry entry (the session mapping, resolved lazily for
fresh sessions) or a pi chat buffer in the perspective (sessions
started outside the registry flow, e.g. `pi-coding-agent/
open-named-session')."
  (or (assoc name pi-coding-agent//registry)
      (when-let* ((persp (persp-get-by-name name))
                  ((perspective-p persp)))
        (pi-coding-agent//chat-buffer-in-persp persp))))

(defun pi-coding-agent//ordered-persp-names ()
  "Return real perspective names in persp's display order.
The nil (default) perspective is excluded: it cannot host a pi
session and `persp-contain-buffer-p' is always true for it."
  (cl-remove-if-not (lambda (name)
                      (perspective-p (persp-get-by-name name)))
                    (persp-names-current-frame-fast-ordered)))

(defun pi-coding-agent//active-pi-buffer-p (buf)
  "Return non-nil when BUF is a pi chat buffer with a live process."
  (and (buffer-live-p buf)
       (with-current-buffer buf
         (derived-mode-p 'pi-coding-agent-chat-mode))
       (let ((proc (buffer-local-value 'pi-coding-agent--process buf)))
         (and (processp proc) (process-live-p proc)))))

(defun pi-coding-agent//active-chat-buffers ()
  "Return active pi chat buffers, most recently used first."
  (cl-remove-if-not #'pi-coding-agent//active-pi-buffer-p (buffer-list)))

(defun pi-coding-agent//session-entry-by-file ()
  "Return a hash table mapping session file paths to metadata entries."
  (let ((table (make-hash-table :test 'equal)))
    (dolist (entry (pi-coding-agent//session-entries))
      (puthash (plist-get entry :file) entry table))
    table))

(defun pi-coding-agent//session-base-label (entry)
  "Base candidate label for session ENTRY: \"title · abbrev-path\"."
  (when entry
    (let* ((title (pi-coding-agent//entry-title entry))
           (cwd (plist-get entry :cwd))
           (abbrev (and (stringp cwd)
                        (abbreviate-file-name (directory-file-name cwd)))))
      (if abbrev (format "%s · %s" title abbrev) title))))

(defun pi-coding-agent//chat-buffer-dir (buf)
  "Return the abbreviated session directory of chat buffer BUF, or nil.
Used to annotate named-session labels, whose perspective name is the
bare session name and carries no directory."
  (when (buffer-live-p buf)
    (let ((dir (condition-case nil
                   (with-current-buffer buf
                     (pi-coding-agent--chat-session-directory))
                 (error nil))))
      (when (and (stringp dir) (not (string-empty-p dir)))
        (abbreviate-file-name (directory-file-name dir))))))

(defun pi-coding-agent//registry-label-locked-p (persp-name)
  "Return non-nil when perspective PERSP-NAME has a label-locked registry entry.
Label-locked marks named sessions (their perspective name is the bare
session name) and user-renamed perspectives — in both cases the
perspective name alone does not carry the session's directory, so the
session list appends it."
  (when-let* ((entry (assoc persp-name pi-coding-agent//registry)))
    (plist-get (cdr entry) :label-locked)))

(defun pi-coding-agent//chat-buffer-label (buf by-file)
  "Display label for pi chat buffer BUF.
The perspective's name when BUF belongs to one — with the session's
directory appended for named (label-locked) perspectives, whose name
is the bare session name — else the session's \"title · path\" label,
else the buffer name.  BY-FILE maps session files to metadata entries."
  (or (when-let* ((persp (pi-coding-agent//persp-containing-buffer buf))
                  (name (safe-persp-name persp)))
        (if (pi-coding-agent//registry-label-locked-p name)
            (if-let* ((dir (pi-coding-agent//chat-buffer-dir buf)))
                (format "%s · %s" name dir)
              name)
          name))
      (pi-coding-agent//session-base-label
       (gethash (plist-get (buffer-local-value 'pi-coding-agent--state buf)
                           :session-file)
                by-file))
      (buffer-name buf)))

(defun pi-coding-agent//persp-for-close (buf)
  "Resolve the perspective to close for pi chat buffer BUF.
Prefers the current perspective when it displays BUF (a chat buffer
can be shared by several perspectives of one directory); otherwise
the first real perspective containing it."
  (let ((current (get-current-persp)))
    (cond
     ((and (perspective-p current)
           (memq buf (safe-persp-buffers current)))
      (safe-persp-name current))
     ((when-let* ((persp (pi-coding-agent//persp-containing-buffer buf)))
        (safe-persp-name persp))))))

(defun pi-coding-agent//default-close-candidate ()
  "Return (CANDIDATE . TARGET) defaulting the session pickers.
The current perspective's session: its active pi chat buffer when it
has one (TARGET (:buffer BUF)); without an active pi buffer, its
registered session (TARGET (:persp NAME)).  Nil when the current
perspective has no session."
  (let* ((persp (get-current-persp))
         (name (safe-persp-name persp))
         (chat (and (perspective-p persp)
                    (pi-coding-agent//chat-buffer-in-persp persp))))
    (cond
     ((and chat (pi-coding-agent//active-pi-buffer-p chat))
      (cons (pi-coding-agent//chat-buffer-label
             chat (pi-coding-agent//session-entry-by-file))
            (list :buffer chat)))
     ((pi-coding-agent//persp-pi-session-p name)
      (cons name (list :persp name :opened t :count 0
                       :modified (current-time)))))))

(defun pi-coding-agent//read-close-target (&optional include-closed action)
  "Prompt for a pi session; return a target plist.
LIVE candidates are the active pi chat buffers — the perspective is
resolved at close time (`pi-coding-agent//persp-for-close'), not
when listing; when INCLUDE-CLOSED, closed sessions follow (their
file is deleted).  The picker's default is the current
perspective's session — its active pi chat buffer, or its registered
session when there is no active buffer.  Live sessions are always
offered before closed ones, with a section boundary between the
groups (separate sources under helm, header rows otherwise).
ACTION is the verb used in the prompt and error (default \"Close\").
Returns (:buffer BUF), (:entry ENTRY), or (:persp NAME).

The list is built by the same `pi-coding-agent//session-targets'
logic as the switch pickers, scoped with REMOTE-SCOPE t: every
host's sessions are offered (close/delete must reach a dead remote
session), with remote closed files scanned only over established
connections, exactly like the switch list does for its host.  The
single listing difference besides that scope is that the current
session is NOT excluded: it is the picker's default."
  (let* ((action (or action "Close"))
         (groups (pi-coding-agent//session-targets
                  nil include-closed nil nil t))
         (live (car groups))
         (closed (cdr groups))
         (default (pi-coding-agent//default-close-candidate)))
    (when (and default (not (assoc (car default) live)))
      ;; Default without an active buffer: replace any same-labelled
      ;; closed candidate (the same session) and offer it in the
      ;; live list.
      (when (assoc (car default) closed)
        (setq closed (cl-remove (car default) closed :key #'car :test #'equal)))
      (push default live))
    (if (and (null live) (null closed))
        (user-error "No open pi sessions to %s" (downcase action))
      (let ((choice (pi-coding-agent//pick-session
                     live closed (format "%s pi session: " action)
                     (car default) t)))
        (cond
         ((and default (string-empty-p choice)) (cdr default))
         ((assoc choice live) (cdr (assoc choice live)))
         ((assoc choice closed) (cdr (assoc choice closed)))
         (t (user-error "No session selected")))))))

(defun pi-coding-agent//close-target-persp (target)
  "Resolve TARGET from `pi-coding-agent//read-close-target' to a
perspective name to close."
  (cond
   ((plist-get target :buffer)
    (or (pi-coding-agent//persp-for-close (plist-get target :buffer))
        (user-error "The selected session belongs to no perspective")))
   ((plist-get target :persp) (plist-get target :persp))
   (t (user-error "Invalid close target"))))

(defun pi-coding-agent//choose-session-to-close ()
  "Resolve the perspective name to close.
The current perspective's session when it has one (registry entry or
pi chat buffer); otherwise the active pi sessions are listed and the
perspective is resolved from the chosen buffer at close time."
  (let ((name (safe-persp-name (get-current-persp))))
    (if (pi-coding-agent//persp-pi-session-p name)
        name
      (pi-coding-agent//close-target-persp
       (pi-coding-agent//read-close-target nil "Close")))))

(defun pi-coding-agent//switch-to-next-persp (closed-name persp-order)
  "Switch to the next perspective after closing CLOSED-NAME.
PERSP-ORDER is the ordered perspective list from before the close.
Prefers the next perspective after CLOSED-NAME (wrapping) that is
associated with a pi session; when no remaining perspective has a pi
session, the next perspective (wrapping) is used.  No-op when only
the default perspective remains."
  (let* ((pos (cl-position closed-name persp-order))
         (order (if pos
                    (append (nthcdr (1+ pos) persp-order)
                            (cl-subseq persp-order 0 pos))
                  (cl-remove closed-name persp-order :test #'equal)))
         (with-pi (cl-remove-if-not #'pi-coding-agent//persp-pi-session-p
                                    persp-order))
         (next (or (cl-find-if (lambda (name) (member name with-pi)) order)
                   (car order))))
    (when (and next
               (not (string= next (safe-persp-name (get-current-persp)))))
      (persp-switch next))))

(defun pi-coding-agent//delete-session-file (file)
  "Delete session FILE: move it to the OS trash, else delete it.
Mirrors pi's own TUI delete: the `trash' command is used when
available, falling back to a permanent unlink — the session is
recoverable from the trash on systems with the `trash' CLI.  Returns
non-nil on success.  Returns nil (with a message) when FILE does not
exist on disk — a fresh session whose JSONL pi never wrote; there is
nothing to delete and the session is not listable anyway.  Signals
when both trash and unlink fail."
  (if (file-exists-p file)
      (let* ((trash (executable-find "trash"))
             (status (and trash
                          (apply #'process-file trash nil nil nil
                                 (if (string-prefix-p "-" file)
                                     (list "--" file)
                                   (list file))))))
        (if (or (and status (zerop status))
                (not (file-exists-p file)))
            (progn
              (when trash
                (message "pi: moved session file to trash (%s)"
                         (abbreviate-file-name file)))
              t)
          ;; Trash unavailable or failed: delete permanently.
          (condition-case err
              (progn
                (delete-file file)
                (message "pi: deleted session file (%s)"
                         (abbreviate-file-name file))
                t)
            (error
             (user-error "pi: failed to delete session file %s%s: %s"
                         (abbreviate-file-name file)
                         (if trash " (trash also failed)" "")
                         (error-message-string err))))))
    (message "pi: no session file to delete (%s)"
             (abbreviate-file-name file))
    nil))

(defun pi-coding-agent//remote-stderr-fifo (stderr)
  "Return the remote fifo TRAMP created for stderr buffer STDERR, or nil.
TRAMP's `make-process' with a stderr buffer creates a remote named
pipe and a separate `cat' process reading it; the pipe's local name
is the second element of that process's `remote-command'.  Returns
nil for a local session (or when the stderr buffer/process is gone)."
  (when (buffer-live-p stderr)
    (when-let* ((stderr-proc (get-buffer-process stderr))
                (vec (process-get stderr-proc 'tramp-vector))
                (cmd (process-get stderr-proc 'remote-command))
                (local (and (consp cmd) (stringp (nth 1 cmd)) (nth 1 cmd))))
      (tramp-make-tramp-file-name vec local))))

(defun pi-coding-agent//close-session-in-persp (name &optional delete)
  "Close the pi session of perspective NAME: process, buffers, persp.
Confirms first.  Kills the pi process (when the perspective has its
own chat buffer), then the perspective's exclusive buffers (standard
unsaved-change prompts; common buffers and buffers shared with other
perspectives are spared), then the perspective itself.

When DELETE is non-nil the session file is also deleted — moved to
the OS trash via the `trash' command, else permanently, the same
behavior as pi's own TUI delete — and the registry entry is dropped,
so the session no longer appears in the session list; deleting is
refused while the session's chat buffer is shared with another
perspective (the file would move out from under a live process).
Otherwise the registry entry (mapping and captured buffer specs)
persists, so reopening the session from the list restores its
workspace."
  (let* ((persp (persp-get-by-name name))
         (entry (assoc name pi-coding-agent//registry))
         (buffers (and (perspective-p persp)
                       (pi-coding-agent//exclusive-buffers persp)))
         (chat (cl-find-if (lambda (buf)
                             (with-current-buffer buf
                               (derived-mode-p 'pi-coding-agent-chat-mode)))
                           buffers)))
    (when (and delete
               (perspective-p persp)
               (pi-coding-agent//chat-buffer-in-persp persp)
               (null chat))
      (user-error "Cannot delete: session '%s' is shared with another \
perspective" name))
    (unless (y-or-n-p
             (format "%s pi session '%s' and kill its %d buffer%s? "
                     (if delete "Delete" "Close")
                     name (length buffers)
                     (if (= (length buffers) 1) "" "s")))
      (user-error "Aborted"))
    ;; Remember the workspace before destroying it (close only; a
    ;; deleted session's registry entry is dropped below).
    (when (and entry (not delete))
      (setcdr entry (plist-put (cdr entry) :buffers
                               (pi-coding-agent//capture-buffer-specs persp)))
      (pi-coding-agent//registry-save))
    ;; Resolve the session file for the delete while the chat buffer
    ;; is still alive (fresh entries may not have one yet; sessions
    ;; started outside the registry flow fall back to the chat
    ;; buffer's loaded file).
    (let ((file-to-delete
           (and delete
                (or (and entry
                         (pi-coding-agent//registry-fill-session-file
                          name (cdr entry)))
                    (and chat
                         (let ((f (plist-get (buffer-local-value
                                              'pi-coding-agent--state chat)
                                             :session-file)))
                           (and (stringp f) (not (string-empty-p f)) f)))))))
      ;; Teardown, fail open: a session whose file or directory no
      ;; longer exists must still be removed.  An unexpected error in
      ;; one teardown step (e.g. a buffer hook) is reported and
      ;; skipped so the remaining cleanup — file deletion, registry
      ;; drop, perspective kill — still runs and the delete never
      ;; strands a zombie perspective.
      (condition-case err
          (progn
            ;; Stop the pi process first (killing its chat buffer must
            ;; not trigger a process query).
            (when chat
              (let* ((proc (buffer-local-value 'pi-coding-agent--process chat))
                     (stderr (and (processp proc)
                                  (process-get proc
                                               'pi-coding-agent-stderr-buf)))
                     (remote-fifo (pi-coding-agent//remote-stderr-fifo stderr)))
                (when (processp proc)
                  ;; Suppress the package's own kill confirmation (the
                  ;; chat-buffer kill below would otherwise prompt).
                  (pi-coding-agent--skip-process-kill-confirmation proc)
                  ;; For a remote (TRAMP) process, `delete-process' runs
                  ;; the process sentinel synchronously, and that sentinel
                  ;; (including TRAMP's own :after cleanup) performs
                  ;; synchronous TRAMP operations — deleting the stderr
                  ;; fifo — which fail with "Forbidden reentrant call of
                  ;; Tramp" when the connection is busy.  Detach the
                  ;; sentinel so the kill stays a plain local process
                  ;; kill, and remove the fifo here, outside the sentinel.
                  (when (process-get proc 'tramp-vector)
                    (set-process-sentinel proc #'ignore))
                  (delete-process proc))
                (when (and stderr (buffer-live-p stderr))
                  (kill-buffer stderr))
                (when remote-fifo
                  (ignore-errors
                    (when (file-exists-p remote-fifo)
                      (delete-file remote-fifo))))))
            ;; Kill the session's buffers (unsaved-change prompts
            ;; preserved; the pi kill confirmation is suppressed — the
            ;; user already confirmed the close).
            (dolist (buf buffers)
              (when (buffer-live-p buf)
                (pi-coding-agent//skip-kill-confirmation-for buf)
                (kill-buffer buf))))
        (error
         (message "pi: error tearing down session '%s': %s — continuing"
                  name (error-message-string err))))
      ;; Delete: remove the file (trash first, unlink fallback) and
      ;; drop the registry entry before the perspective is killed, so
      ;; the before-kill hook does not re-capture it.  A missing file
      ;; (a fresh session pi never wrote, or a session whose
      ;; directory no longer exists) is fine — nothing to delete, and
      ;; nothing listable; a real delete failure is
      ;; reported but must not abort the teardown (that would leave a
      ;; zombie perspective with a dead process and a stale registry
      ;; entry).
      (when delete
        (when file-to-delete
          (condition-case err
              (pi-coding-agent//delete-session-file file-to-delete)
            (error
             (message "pi: failed to delete session file %s: %s — the \
session may still appear in the session list"
                      (abbreviate-file-name file-to-delete)
                      (error-message-string err)))))
        (pi-coding-agent//registry-remove name)
        (pi-coding-agent//registry-save)))
    ;; Close the perspective; frames showing it switch to the default
    ;; perspective (the caller then switches to the next pi persp).
    (persp-kill (list name) t)))

(defun pi-coding-agent/close-session ()
  "Close a pi session and its perspective.
Closes the current perspective's session when it has one; otherwise
lists the open sessions for the user to pick one.  Stops the pi
process, kills the perspective's buffers (standard unsaved-change
prompts; common buffers and buffers shared with other perspectives
are spared), deletes the perspective, then switches to the next
perspective that has a pi session (or the next perspective when none
does).  The workspace is remembered in the registry, so reopening the
session from the list restores it."
  (interactive)
  (require 'pi-coding-agent)
  (unless (bound-and-true-p persp-mode)
    (user-error "persp-mode is not active — enable the spacemacs-layouts layer"))
  (let* ((name (pi-coding-agent//choose-session-to-close))
         (persp-order (pi-coding-agent//ordered-persp-names)))
    (pi-coding-agent//close-session-in-persp name nil)
    (pi-coding-agent//switch-to-next-persp name persp-order)))

(defun pi-coding-agent//delete-closed-session (entry)
  "Delete closed session ENTRY (no active pi buffer loads its file).
Deletes the session file (OS trash first, permanent unlink as
fallback) and drops any registry entry.  When a perspective is still
registered for the session, it is torn down like an active session
via `pi-coding-agent//close-session-in-persp' (single confirmation,
buffers included).  Returns the perspective name that was closed, or
nil."
  (let* ((file (plist-get entry :file))
         (persp-name (and file (pi-coding-agent//registry-persp-name-for-file file)))
         (persp (and persp-name (persp-get-by-name persp-name))))
    (if (perspective-p persp)
        (progn
          (pi-coding-agent//close-session-in-persp persp-name t)
          persp-name)
      (unless (y-or-n-p (format "Delete closed session '%s'? "
                                (pi-coding-agent//entry-title entry)))
        (user-error "Aborted"))
      (when file
        (condition-case err
            (pi-coding-agent//delete-session-file file)
          (error
           (message "pi: failed to delete session file %s: %s — the \
session may still appear in the session list"
                    (abbreviate-file-name file)
                    (error-message-string err)))))
      (when persp-name
        (pi-coding-agent//registry-remove persp-name)
        (pi-coding-agent//registry-save))
      persp-name)))

(defun pi-coding-agent/delete-session ()
  "Delete a pi session: remove it from the session list.
Always prompts — the current session is the default — offering both
active sessions (live pi chat buffers; the perspective is resolved
when deleting) and closed sessions (their file is deleted).  The
list is the shared session-targets logic with remote scope t: every
host's live and closed sessions are offered, remote closed files
scanned only over established connections.  Under
helm the two groups are separate sections, active first.  An active
session is torn down like `pi-coding-agent/close-session', then its
file is deleted — moved to the OS trash via the `trash' command when
available, otherwise deleted permanently, the same behavior as pi's
own TUI delete — and its registry entry dropped; a closed session is
deleted the same way, dropping any registry entry (a dead
perspective still registered for it is torn down too)."
  (interactive)
  (require 'pi-coding-agent)
  (unless (bound-and-true-p persp-mode)
    (user-error "persp-mode is not active — enable the spacemacs-layouts layer"))
  (let* ((target (pi-coding-agent//read-close-target t "Delete"))
         (persp-order (pi-coding-agent//ordered-persp-names)))
    (cond
     ((plist-get target :entry)
      (let ((closed (pi-coding-agent//delete-closed-session
                     (plist-get target :entry))))
        (when closed
          (pi-coding-agent//switch-to-next-persp closed persp-order))))
     ((or (plist-get target :buffer) (plist-get target :persp))
      (let ((persp-name (pi-coding-agent//close-target-persp target)))
        (pi-coding-agent//close-session-in-persp persp-name t)
        (pi-coding-agent//switch-to-next-persp persp-name persp-order)))
     (t (user-error "Invalid delete target")))))

;; ---------------------------------------------------------------------
;; Emacs bridge entry (called by the pi bridge extension via emacsclient)
;;
;; pi sessions started by this Emacs frontend load an extension
;; (pi-bridge-extension.ts, wired through `pi-coding-agent-extra-args')
;; that registers tools driving the hosting Emacs.  The extension
;; shells out to `emacsclient -e' with a base64-encoded JSON request;
;; the layer ensures an Emacs server is running (`pi-coding-agent/
;; enable-bridge') and exports the socket path to pi processes as
;; PI_EMACS_SERVER so emacsclient targets exactly this Emacs instance.
;;
;; These entry points must never prompt: a server eval runs while the
;; tool call waits on `emacsclient', so a minibuffer question would
;; block the pi agent turn until answered (the extension's
;; --timeout=20 caps the wait).  All failure paths return a JSON error
;; instead of signalling interactively.

;; Declared special (no value: does not clobber the package
;; defcustoms) so the let-bindings in the bridge entry bind
;; dynamically.  The package may evaluate its own defvar/defcustom
;; for these names lazily inside the bridge extent (first load), which
;; is only legal while the binding is dynamic.
(defvar pi-coding-agent-essential-grammar-action)
(defvar pi-coding-agent--grammar-prompt-done)

(defun pi-coding-agent//open-session-request (dir &optional name prompt)
  "Open a fresh pi session at DIR as its own perspective and switch to it.

Non-interactive twin of `pi-coding-agent/start-new-session': DIR is
mandatory, NAME opens a named (parallel) session that bypasses the
live-unnamed-session refusal and is labelled with NAME only
(label-locked).  PROMPT (optional string) is sent as the fresh
session's first user message through the standard
`pi-coding-agent--send-prompt' path once the process is up; pi queues
or handles it, and send failures are surfaced in the chat buffer.
Runs the standard flow via `pi-coding-agent//
start-fresh-session' (create+switch perspective, fresh pi process,
registry entry, pi window layout).  Returns the plist (:ok t :persp
NAME :directory DIR); signals an error when the request is invalid or
the launch fails (rolling back the fresh perspective)."
  (require 'pi-coding-agent)
  (unless (bound-and-true-p persp-mode)
    (user-error "persp-mode is not active — enable the spacemacs-layouts layer"))
  (unless (and (stringp dir) (not (string-empty-p dir)))
    (user-error "No directory given"))
  (let* ((dir (file-name-as-directory
               (pi-coding-agent--route-preserving-expand-file-name dir))))
    (unless (file-directory-p dir)
      (user-error "Not a directory: %s" dir))
    (let ((chat (pi-coding-agent//start-fresh-session dir name)))
      (when (and (stringp prompt) (not (string-empty-p prompt)))
        (with-current-buffer chat
          (pi-coding-agent--send-prompt prompt)))
      (let ((persp-name (safe-persp-name (get-current-persp))))
        (message "pi: opened session in %s (perspective %s)" dir persp-name)
        (list :ok t :persp persp-name :directory dir)))))

(defun pi-coding-agent/open-session-at-directory-bridge (b64)
  "Bridge entry invoked via `emacsclient -e' by the pi bridge extension.

B64 is a base64-encoded JSON request object `{directory, name,
prompt}'.  PROMPT is optional; when present it is sent as the new
session's first user message.  Executes the new-session flow
non-interactively and returns a JSON
string: `{\"ok\": true, \"persp\": \"...\", \"directory\": \"/abs\"}'
or `{\"ok\": false, \"error\": \"...\"}'.
Runs strictly prompt-free: dependency/grammar questions are
suppressed for this eval (essential grammars degrade to a warning,
the optional-grammar prompt is skipped) so the emacsclient call can
never block on a minibuffer question.  Interactive sessions keep
their normal prompting."
  (require 'json)
  (condition-case err
      (let* ((request (json-parse-string (base64-decode-string b64)))
             (dir (gethash "directory" request))
             (name (gethash "name" request))
             (prompt (gethash "prompt" request))
             ;; A server eval runs while the pi tool waits on
             ;; emacsclient: never ask.  'warn keeps the session
             ;; usable (chat buffer degrades to plain text) and defers
             ;; installation to an interactive open / M-x
             ;; pi-coding-agent-install-grammars.
             (pi-coding-agent-essential-grammar-action 'warn)
             (pi-coding-agent--grammar-prompt-done t))
        (when (eq name :null)
          (setq name nil))
        (when (eq prompt :null)
          (setq prompt nil))
        (json-encode (pi-coding-agent//open-session-request dir name prompt)))
    (error
     (json-encode (list :ok :json-false
                        :error (error-message-string err))))))

;; ---------------------------------------------------------------------
;; persp save/load handlers for pi chat/input buffers
;;
;; Registered at the front of persp's public dispatch so pi buffers are
;; saved/restored with the perspective (e.g. auto-resume restarts) while
;; all other buffer types are handled by their own owners.

(defun pi-coding-agent//persp-save-handler (buffer)
  "Save pi chat/input BUFFER as a persp savelist spec, else nil."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (cond
       ((derived-mode-p 'pi-coding-agent-chat-mode)
        (let* ((dir (pi-coding-agent--chat-session-directory))
               (launch (pi-coding-agent--chat-session-name))
               (file (plist-get pi-coding-agent--state :session-file)))
          (when (and dir (stringp file) (not (string-empty-p file)))
            (list 'def-buffer-pi-chat (buffer-name) dir launch file))))
       ((derived-mode-p 'pi-coding-agent-input-mode)
        (let* ((chat (pi-coding-agent--get-chat-buffer))
               (dir (and chat (with-current-buffer chat
                                (pi-coding-agent--chat-session-directory))))
               (launch (and chat (with-current-buffer chat
                                  (pi-coding-agent--chat-session-name)))))
          (when dir
            (list 'def-buffer-pi-input (buffer-name) dir launch))))))))

(defun pi-coding-agent//persp-load-handler (spec)
  "Restore a pi chat/input SPEC by re-opening the session, else nil."
  (when (and (listp spec)
             (memq (car spec) '(def-buffer-pi-chat def-buffer-pi-input)))
    (condition-case err
        (pcase (car spec)
          ('def-buffer-pi-chat
           (let* ((_name (nth 1 spec))
                  (dir (nth 2 spec))
                  (launch (nth 3 spec))
                  (file (nth 4 spec)))
             (when (and (stringp dir) (file-directory-p dir)
                        (stringp file) (file-exists-p file))
               (pi-coding-agent//revive-session nil file launch))))
          ('def-buffer-pi-input
           (let* ((name (nth 1 spec))
                  (dir (nth 2 spec))
                  (launch (nth 3 spec)))
             (or (get-buffer name)
                 (when (and (stringp dir) (file-directory-p dir))
                   (pi-coding-agent--get-or-create-buffer :input dir launch))))))
      (error
       (message "pi: failed to restore pi buffer: %s"
                (error-message-string err))
       nil))))

;; ---------------------------------------------------------------------
;; Registration

(pi-coding-agent//registry-load)

(with-eval-after-load 'persp-mode
  ;; Our save/load handlers must run before persp's default `*'-prefixed
  ;; skip, hence the front position.
  (add-to-list 'persp-save-buffer-functions #'pi-coding-agent//persp-save-handler)
  (add-to-list 'persp-load-buffer-functions #'pi-coding-agent//persp-load-handler)
  (add-hook 'persp-renamed-functions #'pi-coding-agent//on-persp-renamed)
  (add-hook 'persp-before-switch-functions #'pi-coding-agent//on-before-switch)
  (add-hook 'persp-before-kill-functions #'pi-coding-agent//on-before-kill))

(add-hook 'kill-emacs-hook #'pi-coding-agent//on-kill-emacs)

(defun pi-coding-agent//bridge-start-process (orig-fn directory)
  "Around-advice exporting the Emacs server socket to pi processes.

Sets PI_EMACS_SERVER (the emacsclient server file) in the pi process
environment so the bridge extension can target exactly this Emacs
instance with `emacsclient -s' — correct with daemons or several
Emacs running.  No-op when the bridge is disabled or no server is
configured (emacsclient then falls back to default socket discovery)."
  (if (not (bound-and-true-p pi-coding-agent/enable-bridge))
      (funcall orig-fn directory)
    (let* ((server-file (and (boundp 'server-socket-dir)
                             (boundp 'server-name)
                             server-socket-dir
                             server-name
                             (expand-file-name server-name server-socket-dir)))
           (process-environment
            (if server-file
                (cons (format "PI_EMACS_SERVER=%s" server-file)
                      process-environment)
              process-environment)))
      (funcall orig-fn directory))))

(defun pi-coding-agent//remote-spawn-start-process (orig-fn directory)
  "Around-advice making every remote pi spawn independent of the remote PATH.

The TRAMP spawn shell is a non-interactive login shell (rc files are
skipped on purpose, see `pi-coding-agent/start-remote-session'), so a
user-installed pi is invisible to it in two ways: even with the mapped
absolute pi path, the `#!/usr/bin/env node' shebang resolves `node'
through PATH and dies with exit 127 (\"env: node: No such file or
directory\") right after the ready marker; and `-e' extension paths
that exist only locally (the Emacs bridge) make the remote pi abort
with \"Extension path does not exist\".

When DIRECTORY is remote and its host has a verified executable
mapping, rebind `pi-coding-agent-executable' to the PATH-independent
spawn (`pi-coding-agent//remote-spawn-executable') and drop local-only
`-e' pairs (`pi-coding-agent//remote-extra-args') — covering every
entry point that spawns a remote pi (session list opens, `a i s',
revivals) without each having to bind the values itself.  Local
directories and hosts without a mapping spawn exactly as before
(fail-open)."
  (let* ((entry (pi-coding-agent//remote-executable-entry-for directory))
         (pi-coding-agent-executable
          (if entry
              (pi-coding-agent//remote-spawn-executable entry)
            pi-coding-agent-executable))
         (pi-coding-agent-extra-args
          (if entry
              (pi-coding-agent//remote-extra-args
               (file-remote-p directory 'host))
            pi-coding-agent-extra-args)))
    (funcall orig-fn directory)))

(defun pi-coding-agent//install-package-advices ()
  "Install the layer's advices on package commands.

Idempotent (removes before adding), so layer reloads (`SPC f e R')
do not double-fire the advices."
  ;; Keep the perspective label in sync when the session is renamed.
  (advice-remove 'pi-coding-agent-set-session-name
                 #'pi-coding-agent//after-set-session-name)
  (advice-add 'pi-coding-agent-set-session-name
              :after #'pi-coding-agent//after-set-session-name)
  ;; Keep the registry mapping + perspective label in sync when a
  ;; package command switches the live session to another session file.
  (dolist (cmd '(pi-coding-agent-new-session
                 pi-coding-agent-resume-session
                 pi-coding-agent--execute-fork
                 pi-coding-agent-open-session-file
                 pi-coding-agent-compact))
    (advice-remove cmd #'pi-coding-agent//sync-registry-after-session-change)
    (advice-add cmd :after #'pi-coding-agent//sync-registry-after-session-change))
  ;; Export the Emacs server socket to pi processes (bridge channel).
  (advice-remove 'pi-coding-agent--start-process
                 #'pi-coding-agent//bridge-start-process)
  (advice-add 'pi-coding-agent--start-process
              :around #'pi-coding-agent//bridge-start-process)
  ;; Make every remote pi spawn PATH-independent (node shebang) and
  ;; free of local-only `-e' extensions, whatever entry point
  ;; triggered the spawn.
  (advice-remove 'pi-coding-agent--start-process
                 #'pi-coding-agent//remote-spawn-start-process)
  (advice-add 'pi-coding-agent--start-process
              :around #'pi-coding-agent//remote-spawn-start-process))

(with-eval-after-load 'pi-coding-agent
  (pi-coding-agent//install-package-advices))

;;; funcs.el ends here
