;;; packages.el --- my-persp layer packages file for Spacemacs.
;;
;; Optional generic enhancements for the spacemacs-layouts (persp-mode)
;; layer: common-buffer injection and terminal buffer save/restore.
;;
;; This layer declares no packages; it only configures persp-mode.  It is
;; an optional dependency-free enhancement: the pi-coding-agent layer works
;; without it, and nothing imports it.
;;
;;; License: GPLv3

;;; Code:

(configuration-layer/declare-layer-dependencies '(spacemacs-layouts))

(defconst my-persp-packages '())

;;; packages.el ends here
