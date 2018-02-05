;;; packages.el --- javacomp layer packages file for Spacemacs.  -*- lexical-binding: t -*-
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
    (lsp-javacomp :requires lsp-mode)))

(defun javacomp/init-lsp-javacomp ()
  (use-package lsp-mode
    :defer t
    :config (require 'lsp-javacomp))

  (use-package lsp-javacomp
    :defer t
    :init
    (progn
      (add-hook 'java-mode-hook
                (lambda ()
                  (require 'lsp-javacomp)
                  (make-variable-buffer-local 'company-backends)
                  (setq company-backends '(company-lsp))
                  (lsp-javacomp-enable)
                  (set (make-variable-buffer-local 'company-idle-delay) 0)
                  (set (make-variable-buffer-local 'company-minimum-prefix-length) 1)
                  )))
    :config (lsp-javacomp-install-server)))

;;; packages.el ends here
