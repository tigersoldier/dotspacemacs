;;; packages.el --- javacomp layer packages file for Spacemacs.
;;
;; Copyright (c) 2017 Caibin Chen
;;
;; Author: Caibin Chen <tigersoldi@gmail.com>
;;
;; This file is not part of GNU Emacs.
;;
;;; License: GPLv3

;;; Commentary:

;;; Code:

(defconst javacomp-packages
  '(
    (javacomp :location local)
    ))

(defun javacomp/init-javacomp ()
  (use-package javacomp
    :defer t
    :commands (javacomp-mode company-javacomp)
    :init
    (progn
      (add-hook 'java-mode-hook 'javacomp-mode)
      ;; (add-hook 'java-mode-hook 'eldoc-mode)

      ;; (add-to-list 'spacemacs-jump-handlers-java-mode 'javacomp-jump-to-definition)

      (push 'company-javacomp company-backends-java-mode))
    ;; :config
    ;; (progn
    ;;   ;; (spacemacs/declare-prefix-for-mode 'java-mode "mg" "goto")
    ;;   ;; (spacemacs/declare-prefix-for-mode 'java-mode "mh" "help")
    ;;   ;; (spacemacs/declare-prefix-for-mode 'java-mode "mn" "name")
    ;;   ;; (spacemacs/declare-prefix-for-mode 'java-mode "mr" "rename")
    ;;   ;; (spacemacs/declare-prefix-for-mode 'java-mode "mS" "server")
    ;;   ;; (spacemacs/declare-prefix-for-mode 'java-mode "ms" "send")

    ;;   (defun java/jump-to-type-def()
    ;;     (interactive)
    ;;     (javacomp-jump-to-definition t))

    ;;   (spacemacs/set-leader-keys-for-major-mode 'java-mode
    ;;     "gb" 'javacomp-jump-back
    ;;     "gt" 'java/jump-to-type-def
    ;;     "gu" 'javacomp-references
    ;;     "hh" 'javacomp-documentation-at-point
    ;;     "rr" 'javacomp-rename-symbol
    ;;     "Sr" 'javacomp-restart-server))
    ))
;;; packages.el ends here
