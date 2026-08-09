;;; layers.el --- pi-coding-agent layer layer dependencies for Spacemacs.
;;
;;; License: GPLv3

;;; Code:

;; Session management turns each opened pi session into a persp-mode
;; perspective (one perspective per session, per-perspective buffer
;; filtering, workspace persistence), so the Spacemacs layouts layer
;; (persp-mode) is required.
(configuration-layer/declare-layer-dependencies '(spacemacs-layouts))

;;; layers.el ends here
