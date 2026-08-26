;;; funcs.el --- my-persp layer functions for Spacemacs.
;;
;; Generic persp-mode enhancements that work for every perspective, pi
;; session or not:
;;
;; 1. Common-buffer injection: buffers matching
;;    `my-persp-common-buffer-regexps' (default *scratch*, *Messages*) are
;;    added to every perspective as it is created, so they stay reachable
;;    from the restricted buffer list in any layout.
;;
;; 2. Terminal save/restore: vterm/term/eshell/shell buffers are saved to
;;    perspective state as (def-buffer-vterm|term|eshell|shell NAME CWD)
;;    specs and relaunched in their saved working directory when the
;;    perspective is restored (e.g. after an Emacs restart with
;;    `dotspacemacs-auto-resume-layouts').  The restored terminal is a
;;    fresh shell process in the saved cwd; shell state is not preserved.
;;
;; Both are implemented through persp-mode's public save/load dispatch
;; (`persp-save-buffer-functions' / `persp-load-buffer-functions'), so
;; other layers can register their own buffer types into the same
;; pipeline.  In particular the pi-coding-agent layer registers its own
;; chat/input handlers at the front of those lists and does not depend on
;; this layer.
;;
;;; License: GPLv3

;;; Code:

(defun my-persp//common-buffer-p (buffer)
  "Return non-nil when BUFFER is a common buffer."
  (cl-find-if (lambda (re) (string-match-p re (buffer-name buffer)))
              my-persp-common-buffer-regexps))

(defun my-persp//inject-common-buffers (persp &rest _)
  "Add live common buffers to PERSP."
  (when (persp-p persp)
    (dolist (buf (buffer-list))
      (when (and (buffer-live-p buf)
                 (my-persp//common-buffer-p buf)
                 (not (persp-contain-buffer-p buf persp)))
        (persp-add-buffer buf persp nil nil)))))

(defun my-persp//inject-common-buffers-all ()
  "Add live common buffers to every existing perspective.
No-op when persp-mode is loaded but not yet activated: `*persp-hash*'
is only created when `persp-mode' is enabled, and `persp-names' would
signal an error on the nil hash table."
  (when (hash-table-p *persp-hash*)
    (dolist (name (persp-names))
      (when-let* ((persp (persp-get-by-name name)))
        (my-persp//inject-common-buffers persp)))))

;; ---------------------------------------------------------------------
;; Terminal save/restore

(defun my-persp//terminal-buffer-p (buffer)
  "Return non-nil when BUFFER is a terminal emulator buffer."
  (with-current-buffer buffer
    (derived-mode-p 'vterm-mode 'term-mode 'eshell-mode 'shell-mode)))

(defun my-persp//terminal-kind (buffer)
  "Return the terminal spec keyword for BUFFER's mode, or nil."
  (pcase (buffer-local-value 'major-mode buffer)
    ('vterm-mode 'def-buffer-vterm)
    ('term-mode 'def-buffer-term)
    ('eshell-mode 'def-buffer-eshell)
    ('shell-mode 'def-buffer-shell)
    (_ nil)))

(defun my-persp//terminal-cwd (buffer)
  "Return the real working directory of terminal BUFFER, or nil.
vterm only updates `default-directory' from OSC 7 (which plain shells
never emit), so its real cwd is read from /proc/<pid>/cwd; the other
terminal modes keep `default-directory' in sync with the shell."
  (if (eq (buffer-local-value 'major-mode buffer) 'vterm-mode)
      (when-let* ((proc (get-buffer-process buffer))
                  ((process-live-p proc))
                  (pid (process-id proc))
                  (dir (file-symlink-p (format "/proc/%d/cwd" pid)))
                  (dir (file-name-as-directory dir))
                  ((file-directory-p dir)))
        dir)
    (buffer-local-value 'default-directory buffer)))

(defun my-persp//save-terminal (buffer)
  "Save terminal BUFFER as (def-buffer-<kind> NAME CWD)."
  (when-let* ((kind (my-persp//terminal-kind buffer))
              (cwd (my-persp//terminal-cwd buffer)))
    (list kind (buffer-name buffer) cwd)))

(defun my-persp//load-terminal (spec)
  "Restore a (def-buffer-<kind> NAME CWD) SPEC by relaunching the shell."
  (when-let* ((kind (car-safe spec))
              (kind (memq kind '(def-buffer-vterm def-buffer-term
                                 def-buffer-eshell def-buffer-shell)))
              (kind (car kind))
              (name (nth 1 spec))
              (cwd (nth 2 spec))
              ((stringp cwd))
              ((file-directory-p cwd)))
    (condition-case err
        (let ((orig-buffer (current-buffer)))
          (unwind-protect
              (let ((default-directory cwd)
                    (buf (pcase kind
                           ('def-buffer-vterm (vterm))
                           ('def-buffer-term (term shell-file-name))
                           ('def-buffer-eshell (eshell))
                           ('def-buffer-shell (shell)))))
                (when (and (bufferp buf) (stringp name)
                           (not (get-buffer name))
                           (not (string= name (buffer-name buf))))
                  (rename-buffer name t))
                buf)
            (when (and (buffer-live-p orig-buffer)
                       (not (eq (current-buffer) orig-buffer)))
              (switch-to-buffer orig-buffer))))
      (error
       (message "my-persp: failed to restore terminal: %s"
                (error-message-string err))
       nil))))

;; ---------------------------------------------------------------------
;; Registration (runs when persp-mode is loaded)

(with-eval-after-load 'persp-mode
  ;; Common buffers: inject on perspective creation and into everything
  ;; that already exists (incl. the default perspective).  The initial
  ;; injection must wait for `persp-mode' to be *activated*: at load
  ;; time `*persp-hash*' is still nil and persp-names would error.
  (add-hook 'persp-created-functions #'my-persp//inject-common-buffers)
  (add-hook 'persp-mode-hook #'my-persp//inject-common-buffers-all)
  ;; Terminal save/load.  persp's default save dispatch skips all
  ;; `*'-prefixed buffers (via `persp-filter-save-buffers-functions')
  ;; and then falls through to the generic `(def-buffer NAME FILE MODE)'
  ;; handler, which would swallow terminals (saved without their cwd and
  ;; restored as empty buffers).  The terminal handler must therefore
  ;; run at the FRONT of the save dispatch, before the `*'-skip filter
  ;; and the file/dired defaults, so terminals are saved as
  ;; (def-buffer-<kind> NAME CWD) specs and relaunched in their saved
  ;; working directory on restore.  The stock filter is left in place —
  ;; it still skips non-terminal `*'-prefixed buffers.  `add-to-list'
  ;; alone would not move the symbol to the front when an earlier
  ;; registration already placed it elsewhere, so the position is
  ;; enforced explicitly.
  (setq persp-save-buffer-functions
        (cons #'my-persp//save-terminal
              (delq #'my-persp//save-terminal persp-save-buffer-functions)))
  (add-to-list 'persp-load-buffer-functions #'my-persp//load-terminal))

;;; funcs.el ends here
