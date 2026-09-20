;;; config.el --- purpose-fix layer configuration for Spacemacs. -*- lexical-binding: t; -*-
;;
;;; License: GPLv3

;;; Commentary:
;;
;; Activation of the layer.  The functions live in funcs.el, which is
;; loaded before config.el (and before any package), so the advice can be
;; installed here — this is configuration, not a helper.

;;; Code:

;; The `set-window-buffer' guard is a plain built-in advice and goes in
;; right away.  The advices on window-purpose's own assignment functions
;; need the package, which the spacemacs-purpose layer initializes only
;; after the layers are configured: install them again once it is loaded.
;; `purpose-fix//install-advices' is idempotent, and when window-purpose is
;; already loaded (always the case on a configuration reload) the
;; `with-eval-after-load' body runs immediately.
(purpose-fix//install-advices)
(with-eval-after-load 'window-purpose
  (purpose-fix//install-advices))

;;; config.el ends here
