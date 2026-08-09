;;; config.el --- my-persp layer configuration for Spacemacs.
;;
;; Layer-level options for the generic persp-mode enhancements.  All
;; behavior is registered in funcs.el once persp-mode is loaded.
;;
;;; License: GPLv3

;;; Code:

(defgroup my-persp nil
  "Generic persp-mode enhancements (common buffers, terminal restore)."
  :group 'spacemacs)

(defcustom my-persp-common-buffer-regexps
  '("\\*scratch\\*" "\\*Messages\\*")
  "Buffer names matching these regexps are injected into every perspective.
Injected buffers appear in the restricted buffer list (SPC b b) of every
layout and are never killed by layout-scoped kill commands."
  :type '(repeat regexp)
  :group 'my-persp)

;;; config.el ends here
