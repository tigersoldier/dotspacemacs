;;; funcs.el --- pi-coding-agent layer functions for Spacemacs. -*- lexical-binding: t; -*-
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
buffers from other workspaces never leak into the session)."
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

(defcustom pi-coding-agent/session-sort-opened 'alpha
  "Sort order for opened sessions in the switch-session list.
`alpha' sorts by title, `chrono' by last modification (newest first)."
  :type '(choice (const :tag "Alphabetical" alpha)
                 (const :tag "Chronological" chrono))
  :group 'pi-coding-agent)

(defcustom pi-coding-agent/session-sort-closed 'alpha
  "Sort order for closed sessions in the switch-session list.
`alpha' sorts by title (lexical), `chrono' by last modification
(newest first).  The default is `alpha' — both groups sort lexically."
  :type '(choice (const :tag "Alphabetical" alpha)
                 (const :tag "Chronological" chrono))
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
  "Return FILE's recorded cwd, or nil."
  (condition-case nil
      (pi-coding-agent--session-file-cwd-or-error file)
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
Session /name wins, then the first-message snippet, then \"New session\"."
  (when-let* ((meta (pi-coding-agent//session-metadata-cached file)))
    (or (let ((name (plist-get meta :session-name)))
          (and (stringp name) (not (string-empty-p name)) name))
        (let ((fm (plist-get meta :first-message)))
          (and (stringp fm) (pi-coding-agent//truncate fm 40)))
        "New session")))

(defun pi-coding-agent//sync-labels ()
  "Lazily sync perspective labels with their session titles.
Sessions without a /name keep the first-message snippet; perspectives
renamed by the user are skipped.  Called from the session list and
before switching."
  (dolist (entry pi-coding-agent//registry)
    (let ((name (car entry)) (plist (cdr entry)))
      (when (and (not (plist-get plist :label-locked))
                 (persp-p (persp-get-by-name name))
                 (plist-get plist :session-file))
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
                   (plist-get (cdr entry) :session-file))
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
  "Return the first live perspective containing BUFFER, or nil."
  (when (bound-and-true-p persp-mode)
    (when-let* ((name (cl-find-if
                       (lambda (name)
                         (let ((persp (persp-get-by-name name)))
                           (and (persp-p persp)
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

(defun pi-coding-agent//session-metadata-cached (file)
  "Return cached metadata for session FILE, re-parsing when mtime changed."
  (let* ((attrs (file-attributes file))
         (mtime (and attrs (file-attribute-modification-time attrs)))
         (cached (gethash file pi-coding-agent//session-cache)))
    (if (and cached (equal (car cached) mtime))
        (cdr cached)
      (let ((meta (pi-coding-agent--session-metadata file)))
        (puthash file (cons mtime meta) pi-coding-agent//session-cache)
        meta))))

(defun pi-coding-agent//opened-session-files ()
  "Return session files currently opened in a live perspective.
Uses the registry first; falls back to scanning perspective buffers for
pi chat buffers (e.g. named sessions placed in a perspective outside
the registry)."
  (if (not (bound-and-true-p persp-mode))
      nil
    (let (files)
    (dolist (name (persp-names))
      (when-let* ((persp (persp-get-by-name name))
                  ((persp-p persp)))
        (let ((entry (assoc name pi-coding-agent//registry)))
          (if entry
              (when-let* ((f (plist-get (cdr entry) :session-file)))
                (push f files))
            (dolist (buf (safe-persp-buffers persp))
              (when (with-current-buffer buf
                      (derived-mode-p 'pi-coding-agent-chat-mode))
                (when-let* ((state (buffer-local-value
                                    'pi-coding-agent--state buf))
                            (f (plist-get state :session-file))
                            ((stringp f))
                            ((not (string-empty-p f))))
                  (push f files))))))))
    files)))

(defun pi-coding-agent//session-entries-in-dir (dir)
  "Return session entries whose recorded cwd is DIR (exact match).
DIR is compared expanded and with a trailing slash, matching the
normalization `pi-coding-agent--session-file-cwd-or-error' applies to
recorded cwds."
  (let ((dir (file-name-as-directory
              (pi-coding-agent--route-preserving-expand-file-name dir))))
    (cl-remove-if-not
     (lambda (entry)
       (let ((cwd (plist-get entry :cwd)))
         (and (stringp cwd)
              (equal (file-name-as-directory
                      (pi-coding-agent--route-preserving-expand-file-name
                       cwd))
                     dir))))
     (pi-coding-agent//session-entries))))

(defun pi-coding-agent//session-entries ()
  "Return plist entries for all sessions under `pi-coding-agent/session-root'."
  (let* ((root (expand-file-name pi-coding-agent/session-root))
         (files (and (file-directory-p root)
                     (directory-files-recursively root "\\.jsonl$")))
         (opened (pi-coding-agent//opened-session-files))
         entries)
    (dolist (file files)
      (when-let* ((meta (pi-coding-agent//session-metadata-cached file)))
        (push (list :file file
                    :cwd (plist-get meta :cwd)
                    :first-message (plist-get meta :first-message)
                    :name (plist-get meta :session-name)
                    :count (plist-get meta :message-count)
                    :modified (plist-get meta :modified-time)
                    :opened (member file opened))
              entries)))
    ;; Drop cache entries for deleted files.
    (maphash (lambda (file _)
               (unless (member file files)
                 (remhash file pi-coding-agent//session-cache)))
             pi-coding-agent//session-cache)
    (nreverse entries)))

(defun pi-coding-agent//entry-title (entry)
  "Display title for session ENTRY (name, first message, or placeholder)."
  (or (let ((name (plist-get entry :name)))
        (and (stringp name) (not (string-empty-p name)) name))
      (let ((fm (plist-get entry :first-message)))
        (and (stringp fm) (pi-coding-agent//truncate fm 40)))
      "(no messages)"))

(defun pi-coding-agent//sort-group (entries mode)
  "Sort ENTRIES by MODE (`alpha' or `chrono')."
  (pcase mode
    ('alpha
     (sort (copy-sequence entries)
           (lambda (a b)
             (string< (pi-coding-agent//entry-title a)
                      (pi-coding-agent//entry-title b)))))
    ('chrono
     (sort (copy-sequence entries)
           (lambda (a b)
             (time-less-p (plist-get b :modified)
                          (plist-get a :modified)))))
    (_ entries)))

(defun pi-coding-agent//sort-entries (entries)
  "Opened sessions first (per `pi-coding-agent/session-sort-opened'),
then closed (per `pi-coding-agent/session-sort-closed'); both default
to lexical order by title."
  (append
   (pi-coding-agent//sort-group
    (cl-remove-if-not (lambda (e) (plist-get e :opened)) entries)
    pi-coding-agent/session-sort-opened)
   (pi-coding-agent//sort-group
    (cl-remove-if-not (lambda (e) (not (plist-get e :opened))) entries)
    pi-coding-agent/session-sort-closed)))

(defun pi-coding-agent//age-string (time)
  "Humanized age of TIME, e.g. \"now\", \"5m\", \"3h\", \"2d\"."
  (let ((secs (max 0 (floor (float-time (time-subtract (current-time) time))))))
    (cond ((< secs 60) "now")
          ((< secs 3600) (format "%dm" (/ secs 60)))
          ((< secs 86400) (format "%dh" (/ secs 3600)))
          (t (format "%dd" (/ secs 86400))))))

(defun pi-coding-agent//session-candidates (entries &optional dir)
  "Build (CANDIDATE . ENTRY) conses for the switch-session list.
Candidates are \"title · abbrev-path\" — or just \"title\" when DIR is
given (all sessions share that directory) — with a uuid disambiguator
when two sessions would render identically."
  (let ((seen (make-hash-table :test 'equal))
        candidates)
    (dolist (entry entries)
      (let* ((title (pi-coding-agent//entry-title entry))
             (cwd (plist-get entry :cwd))
             (abbrev (and (null dir) (stringp cwd)
                          (abbreviate-file-name (directory-file-name cwd))))
             (base (if abbrev (format "%s · %s" title abbrev) title))
             (n (gethash base seen 0)))
        (puthash base (1+ n) seen)
        (let ((cand (if (> n 0)
                        (format "%s  (%s)" base
                                (or (pi-coding-agent//file-uuid-prefix
                                     (plist-get entry :file))
                                    "?"))
                      base)))
          (push (cons cand entry) candidates))))
    (nreverse candidates)))

(defun pi-coding-agent//make-session-affixation (alist)
  "Return an affixation function showing status, count, and age.
Candidates without an ENTRY (e.g. the \"✚ New session\" action item)
get a \"✚ \" glyph and no suffix."
  (lambda (cands)
    (mapcar
     (lambda (cand)
       (let* ((entry (cdr (assoc cand alist)))
              (glyph (cond ((null entry) "✚ ")
                           ((plist-get entry :opened) "● ")
                           (t "○ ")))
              (suffix (if entry
                          (format "  %d msgs  %s"
                                  (or (plist-get entry :count) 0)
                                  (pi-coding-agent//age-string
                                   (plist-get entry :modified)))
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
                    . ,(pi-coding-agent//make-session-affixation alist))
                   (display-sort-function . identity)))
       (t nil)))))

;; ---------------------------------------------------------------------
;; Opening, switching, reviving

(defun pi-coding-agent//chat-buffer-in-persp (persp)
  "Return the pi chat buffer of PERSP, or nil."
  (cl-find-if (lambda (buf)
                (with-current-buffer buf
                  (derived-mode-p 'pi-coding-agent-chat-mode)))
              (safe-persp-buffers persp)))

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
a different directory, so switching always surfaces the selected session."
  (persp-switch persp-name)
  (when-let* ((persp (persp-get-by-name persp-name))
              ((persp-p persp)))
    (let* ((chat (pi-coding-agent//chat-buffer-in-persp persp))
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
      (or (and entry (plist-get (cdr entry) :session-file))
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
       (when (persp-p (persp-get-by-name persp-name))
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
  "Open closed session ENTRY, or switch to it when already opened."
  (let* ((file (plist-get entry :file))
         (persp-name (pi-coding-agent//registry-persp-name-for-file file)))
    (if persp-name
        (pi-coding-agent//switch-to-session persp-name file)
      (pi-coding-agent//open-session entry))))

(defun pi-coding-agent/switch-session ()
  "List all pi sessions; open the chosen one or switch to it if opened.
The current session is excluded.  Opened sessions are marked with ●
and listed first, closed sessions after; both groups sort lexically by
title (configurable via `pi-coding-agent/session-sort-opened' and
`pi-coding-agent/session-sort-closed')."
  (interactive)
  (require 'pi-coding-agent)
  (unless (bound-and-true-p persp-mode)
    (user-error "persp-mode is not active — enable the spacemacs-layouts layer"))
  (pi-coding-agent//sync-labels)
  (let* ((current (pi-coding-agent//current-session-file))
         (entries (pi-coding-agent//sort-entries
                   (cl-remove-if (lambda (e)
                                   (and current
                                        (equal (plist-get e :file) current)))
                                 (pi-coding-agent//session-entries))))
         (alist (pi-coding-agent//session-candidates entries)))
    (if (null alist)
        (user-error "No other pi sessions found (looked in %s)"
                    (expand-file-name pi-coding-agent/session-root))
      (let ((choice (completing-read
                     "Pi session: "
                     (pi-coding-agent//session-collection alist)
                     nil t nil 'pi-coding-agent-session-history)))
        (when-let* ((entry (cdr (assoc choice alist))))
          (pi-coding-agent//open-or-switch entry))))))

(defun pi-coding-agent/switch-session-in-dir ()
  "Switch to another pi session of the current directory, with its layout.

The directory is the session's own directory inside pi chat/input
buffers, the terminal's working directory in terminal buffers, and
the visited file's directory (else `default-directory') elsewhere.
Lists only that directory's sessions — opened (●) first, then closed
(○), each sorted lexically by title — excluding the current one.
Picking an opened session switches to its perspective (reviving a
dead pi process); picking a closed session opens it in a fresh
perspective with its workspace restored.  Either way the pi window
layout (chat/input left, edit right) is applied afterwards."
  (interactive)
  (require 'pi-coding-agent)
  (unless (bound-and-true-p persp-mode)
    (user-error "persp-mode is not active — enable the spacemacs-layouts layer"))
  (pi-coding-agent//sync-labels)
  (let* ((dir (pi-coding-agent//context-directory))
         (current (pi-coding-agent//current-session-file))
         (entries (pi-coding-agent//sort-entries
                   (cl-remove-if
                    (lambda (entry)
                      (and current
                           (equal (plist-get entry :file) current)))
                    (pi-coding-agent//session-entries-in-dir dir))))
         (alist (pi-coding-agent//session-candidates entries dir)))
    (if (null alist)
        (user-error "No other pi sessions found in %s"
                    (abbreviate-file-name (directory-file-name dir)))
      (let ((choice (completing-read
                     (format "Pi session in %s: "
                             (abbreviate-file-name (directory-file-name dir)))
                     (pi-coding-agent//session-collection alist)
                     nil t nil 'pi-coding-agent-session-history)))
        (when-let* ((entry (cdr (assoc choice alist))))
          (pi-coding-agent//open-or-switch entry)
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

(defun pi-coding-agent//new-session-choice (dir entries)
  "Choose between DIR's existing sessions and a fresh session.
ENTRIES are the directory's session entries (see
`pi-coding-agent//session-entries-in-dir').  Returns (existing .
ENTRY) when an existing session was chosen, (new . NAME) when a fresh
session named NAME (nil = unnamed) should be started.

With no existing sessions a fresh session is chosen directly; when
DIR already runs a live unnamed session whose file pi has not written
yet, a name is prompted first (parallel sessions need a name).  With
existing sessions, they are offered through completing-read — opened
first, then closed, each sorted lexically — with the \"✚ New
session\" candidate and free-form input (any non-matching name) both
starting a fresh named session; an empty input starts an unnamed
session."
  (if (null entries)
      (cons 'new (and (pi-coding-agent//live-session-in-dir-p dir)
                      (pi-coding-agent//read-new-session-name dir)))
    (let* ((alist (append (pi-coding-agent//session-candidates entries dir)
                          (list (cons pi-coding-agent//new-session-candidate
                                      nil))))
           (choice (completing-read
                    (format "Pi session in %s (type a new name for a new session): "
                            (abbreviate-file-name (directory-file-name dir)))
                    (pi-coding-agent//session-collection alist)
                    nil nil nil 'pi-coding-agent-session-history))
           (entry (cdr (assoc choice alist))))
      (cond
       (entry
        (cons 'existing entry))
       ((string= choice pi-coding-agent//new-session-candidate)
        (cons 'new (pi-coding-agent//read-new-session-name dir)))
       ((or (null choice) (string-empty-p choice))
        (cons 'new nil))
       (t
        (cons 'new (let ((name (string-trim choice)))
                     (and (not (string-empty-p name)) name))))))))

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
    (let ((chat (condition-case err
                    (pi-coding-agent--setup-session dir name)
                  (error
                   (when (persp-p (persp-get-by-name persp-name))
                     (persp-kill (list persp-name) t))
                   (user-error "pi: failed to start session: %s"
                               (error-message-string err))))))
      (pi-coding-agent//registry-put persp-name
                                     :session-file nil
                                     :label-locked (and name t)
                                     :buffers nil)
      (pi-coding-agent//registry-save)
      (let ((input (buffer-local-value 'pi-coding-agent--input-buffer chat)))
        (pi-coding-agent//apply-pi-layout chat input nil t))
      chat)))

(defun pi-coding-agent/start-new-session ()
  "Start a new pi session in a user-chosen directory, or open an existing one.

Always prompts for the directory (unlike `pi-coding-agent/layout',
which reuses the recorded directory inside pi buffers); the prompt
default follows the layout's directory logic.  When the directory has
existing sessions, they are offered for selection — opened (●) first,
then closed (○), each sorted lexically — via completing-read, so the
picker works under helm, ivy, vertico, or the plain minibuffer.
Picking an existing session opens it (or switches to it when already
opened), with its layout; typing a new session name — or picking the
\"✚ New session\" candidate and entering one — starts a fresh named
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
         (choice (pi-coding-agent//new-session-choice
                  dir (pi-coding-agent//session-entries-in-dir dir))))
    (pcase choice
      (`(existing . ,entry)
       (pi-coding-agent//open-or-switch entry))
      (`(new . ,name)
       (pi-coding-agent//start-fresh-session dir name)))))

;; ---------------------------------------------------------------------
;; Close session

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

(defun pi-coding-agent/close-session ()
  "Close the current pi session: kill its buffers and perspective.
Kills the pi process, then the perspective's exclusive buffers (files,
terminals, chat/input) with standard unsaved-change prompts.  Buffers
shared with other perspectives and common buffers are spared.  The
workspace is remembered in the registry, so reopening the session from
the list restores it."
  (interactive)
  (require 'pi-coding-agent)
  (unless (bound-and-true-p persp-mode)
    (user-error "persp-mode is not active — enable the spacemacs-layouts layer"))
  (let* ((persp (get-current-persp))
         (name (safe-persp-name persp))
         (entry (assoc name pi-coding-agent//registry)))
    (unless entry
      (user-error "No pi session in the current perspective"))
    (let* ((buffers (pi-coding-agent//exclusive-buffers persp))
           (chat (cl-find-if (lambda (buf)
                               (with-current-buffer buf
                                 (derived-mode-p 'pi-coding-agent-chat-mode)))
                             buffers)))
      (unless (y-or-n-p
               (format "Close pi session '%s' and kill its %d buffer%s? "
                       name (length buffers)
                       (if (= (length buffers) 1) "" "s")))
        (user-error "Aborted"))
      ;; Remember the workspace before destroying it.
      (setcdr entry (plist-put (cdr entry) :buffers
                               (pi-coding-agent//capture-buffer-specs persp)))
      (pi-coding-agent//registry-save)
      ;; Stop the pi process first (killing its chat buffer must not
      ;; trigger a process query).
      (when chat
        (let* ((proc (buffer-local-value 'pi-coding-agent--process chat))
               (stderr (and (processp proc)
                            (process-get proc 'pi-coding-agent-stderr-buf))))
          (when (processp proc)
            ;; Suppress the package's own kill confirmation (the
            ;; chat-buffer kill below would otherwise prompt).
            (pi-coding-agent--skip-process-kill-confirmation proc)
            (delete-process proc))
          (when (and stderr (buffer-live-p stderr))
            (kill-buffer stderr))))
      ;; Kill the session's buffers (unsaved-change prompts preserved;
      ;; the pi kill confirmation is suppressed — the user already
      ;; confirmed the close).
      (dolist (buf buffers)
        (when (buffer-live-p buf)
          (pi-coding-agent//skip-kill-confirmation-for buf)
          (kill-buffer buf)))
      ;; Close the perspective; frames showing it switch to the default
      ;; perspective.
      (persp-kill (list name) t))))

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

(defun pi-coding-agent//open-session-request (dir &optional name)
  "Open a fresh pi session at DIR as its own perspective and switch to it.

Non-interactive twin of `pi-coding-agent/start-new-session': DIR is
mandatory, NAME opens a named (parallel) session that bypasses the
live-unnamed-session refusal and is labelled with NAME only
(label-locked).  Runs the standard flow via `pi-coding-agent//
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
    (pi-coding-agent//start-fresh-session dir name)
    (let ((persp-name (safe-persp-name (get-current-persp))))
      (message "pi: opened session in %s (perspective %s)" dir persp-name)
      (list :ok t :persp persp-name :directory dir))))

(defun pi-coding-agent/open-session-at-directory-bridge (b64)
  "Bridge entry invoked via `emacsclient -e' by the pi bridge extension.

B64 is a base64-encoded JSON request object `{directory, name}'.
Executes the new-session flow non-interactively and returns a JSON
string: `{\"ok\": true, \"persp\": \"...\", \"directory\": \"/abs\"}'
or `{\"ok\": false, \"error\": \"...\"}'."
  (require 'json)
  (condition-case err
      (let* ((request (json-parse-string (base64-decode-string b64)))
             (dir (gethash "directory" request))
             (name (gethash "name" request)))
        (when (eq name :null)
          (setq name nil))
        (json-encode (pi-coding-agent//open-session-request dir name)))
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
              :around #'pi-coding-agent//bridge-start-process))

(with-eval-after-load 'pi-coding-agent
  (pi-coding-agent//install-package-advices))

;;; funcs.el ends here
