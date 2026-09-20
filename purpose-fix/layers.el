;;; layers.el --- purpose-fix layer layer dependencies for Spacemacs. -*- lexical-binding: t; -*-
;;
;;; License: GPLv3

;;; Code:

;; Everything here is an addition to window-purpose itself: the guard is
;; installed on window-purpose's public API (`purpose-window-purpose',
;; `purpose-window-purpose-dedicated-p', `purpose-set-window-properties'),
;; all of which the spacemacs-purpose layer provides.  No pilish (or any
;; other consumer) is required.
(configuration-layer/declare-layer-dependencies '(spacemacs-purpose))

;;; layers.el ends here
