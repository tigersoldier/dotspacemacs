;;; funcs.el --- purpose-fix layer functions. -*- lexical-binding: t; -*-
;;
;;; License: GPLv3

;;; Commentary:
;;
;; window-purpose routes buffers through `display-buffer' and the advised
;; `switch-to-buffer'/`pop-to-buffer', so a purpose-dedicated window only
;; ever receives buffers of its own purpose.  Callers that bypass those and
;; hand a buffer straight to `set-window-buffer' — Spacemacs' helm action
;; `spacemacs//helm-open-buffers-in-windows' maps opened files onto windows
;; by number — can still take such a window over, and they leave the focus
;; behind while doing it.  `purpose-fix//keep-dedicated-window' applies the
;; same rule to that path.
;;
;; window-purpose's own "assign a purpose to this window" functions, and
;; wholesale window-state restores, are exempt (see
;; `purpose-fix--suspended'): both authoritatively decide which buffer
;; belongs in a window, which is the opposite of a caller stealing one.

;;; Code:

(defvar purpose-fix--suspended nil
  "Non-nil while a caller that owns window assignment is at work.
Bound by `purpose-fix//suspend-guard'.  While it is non-nil
`purpose-fix//keep-dedicated-window' leaves `set-window-buffer' alone.
The callers that bind it assign buffers to windows *en masse* and in
place — window-purpose's layout/purpose functions, and `window-state-put'
(perspective, desktop and other frame-state restores).  They decide what
belongs in each window themselves, and they set a window's buffer while
the window still carries its pre-assignment purpose, so judging those
assignments by the window's old purpose would divert the buffer, leave a
duplicate of the old one behind and scramble the state being restored.")

(defun purpose-fix//window-usable-p (window buffer)
  "Return non-nil when WINDOW may be handed BUFFER directly.
Usable means WINDOW is not dedicated to its buffer, is not dedicated to
a purpose other than BUFFER's, and is not the minibuffer.  This mirrors
`purpose-display--frame-usable-windows' on purpose: the `display-buffer'
path and the `set-window-buffer' path must agree on which windows a
buffer may take over, or the two routes fight each other."
  (and (or (not (window-dedicated-p window))
           (eq (window-buffer window) buffer))
       (or (not (purpose-window-purpose-dedicated-p window))
           (eq (purpose-window-purpose window)
               (purpose-buffer-purpose buffer)))
       (not (window-minibuffer-p window))))

(defun purpose-fix//same-purpose-window-p (window purpose)
  "Return non-nil when WINDOW is free and already has PURPOSE.
A window dedicated to its buffer is not free, so it is not considered."
  (and (eq (purpose-window-purpose window) purpose)
       (not (window-dedicated-p window))))

(defun purpose-fix//target-window (window buffer)
  "Return a window of WINDOW's frame that should show BUFFER instead.
Prefers a window already showing BUFFER, then a free window whose purpose
matches BUFFER's (the window the buffer is meant for), then any window
that is not dedicated to a different purpose.  Skips WINDOW itself,
minibuffers, and side windows (popups).  Returns nil when the frame has
no better window, in which case there is nothing to divert to."
  (let* ((purpose (purpose-buffer-purpose buffer))
         (candidates (cl-remove-if (lambda (w)
                                     (or (eq w window)
                                         (window-parameter w 'window-side)))
                                   (window-list (window-frame window) 'nomini))))
    (or (cl-find-if (lambda (w) (eq (window-buffer w) buffer)) candidates)
        (cl-find-if (lambda (w) (purpose-fix//same-purpose-window-p w purpose))
                    candidates)
        (cl-find-if (lambda (w) (purpose-fix//window-usable-p w buffer))
                    candidates))))

(defun purpose-fix//keep-dedicated-window (orig window buffer &optional keep-margins)
  "Around-advice for `set-window-buffer' that respects purpose dedication.

A buffer whose purpose differs from the purpose-dedicated WINDOW's is
diverted to a window that fits it (`purpose-fix//target-window'), and
WINDOW keeps its own buffer.  Callers that bypass
window-purpose entirely — Spacemacs' helm action
`spacemacs//helm-open-buffers-in-windows' hands files to
`set-window-buffer' on windows it picked by `winum' number — can
otherwise take over a window that window-purpose itself would protect.

Only exact purpose dedication is judged, the same rule the package's
display functions apply, so a buffer of the window's own purpose still
takes the window over.  Callers that own window assignment — the
package's layout/purpose functions and window-state restores — are
exempt; see `purpose-fix--suspended'.

When the diverted buffer was headed for the *selected* window, the focus
follows it: that window is the one the user would have been looking at,
and the caller cannot fix it itself, since `set-window-buffer' never
selects a window.  A buffer aimed at a background window is diverted
silently."
  (let* ((buf (if (bufferp buffer) buffer (get-buffer buffer)))
         (takeover (and (not purpose-fix--suspended)
                        (bound-and-true-p purpose-mode)
                        (buffer-live-p buf)
                        (not (eq (window-buffer window) buf))
                        (purpose-window-purpose-dedicated-p window)
                        (not (eq (purpose-window-purpose window)
                                 (purpose-buffer-purpose buf))))))
    (if (not takeover)
        (funcall orig window buffer keep-margins)
      (let ((target (or (purpose-fix//target-window window buf) window)))
        (prog1 (funcall orig target buffer keep-margins)
          (when (and (not (eq target window))
                     (eq window (selected-window)))
            (select-window target)))))))

(defun purpose-fix//suspend-guard (orig &rest args)
  "Around-advice suspending the guard around an authoritative assignment.
Applied to window-purpose's own window assignment and to
`window-state-put'.  `purpose-fix//keep-dedicated-window' must not
second-guess those: applying a layout, running `purpose-set-window-purpose',
or restoring a saved window state installs exactly the buffers the caller
picked, and diverting one of them would leave the frame half converted."
  (let ((purpose-fix--suspended t))
    (apply orig args)))

(defun purpose-fix//install-advices ()
  "Install the layer's advices.  Idempotent, and safe to call twice.

The advice on the built-in `set-window-buffer' goes in every time.  The
advices on window-purpose's own functions need the package: the layer's
config.el runs before package initialization, so it calls this again once
window-purpose is loaded (`with-eval-after-load'), which is also what
executes immediately on a configuration reload (`SPC f e R')."
  (advice-remove 'set-window-buffer #'purpose-fix//keep-dedicated-window)
  (advice-add 'set-window-buffer :around #'purpose-fix//keep-dedicated-window)
  ;; `window-state-put' is a built-in, and the path persp-mode takes when it
  ;; restores a perspective's window state: it reuses the frame's windows and
  ;; repurposes them in place, which is what `purpose-fix--suspended' is for.
  (advice-remove 'window-state-put #'purpose-fix//suspend-guard)
  (advice-add 'window-state-put :around #'purpose-fix//suspend-guard)
  (when (fboundp 'purpose-set-window-properties)
    (dolist (fn '(purpose-set-window-properties purpose-set-window-purpose))
      (advice-remove fn #'purpose-fix//suspend-guard)
      (advice-add fn :around #'purpose-fix//suspend-guard)))
  ;; The guard used to live in the pilish layer, where it was keyed on that
  ;; layer's window marker instead of purpose dedication.  A reloaded
  ;; configuration keeps advices from the previous load, and after the move
  ;; that function no longer exists, so a stale advice would make every
  ;; `set-window-buffer' call fail.
  (when (advice-member-p 'pilish//keep-session-window 'set-window-buffer)
    (advice-remove 'set-window-buffer 'pilish//keep-session-window)))

;;; funcs.el ends here
