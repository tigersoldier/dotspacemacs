;;; packages.el --- lsp-mode layer packages file for Spacemacs.  -*- lexical-binding: t -*-
;;
;; Copyright (c) 2018 Caibin Chen
;;
;; Author: Caibin Chen <tigersoldi@gmail.com>
;;
;; This file is not part of GNU Emacs.
;;
;;; License: GPLv3

;;; Commentary:

;;; Code:

(defconst lsp-mode-packages
  '(
    (cquery)
    ))

(defun lsp-mode/init-cquery ()
  (use-package cquery
    :defer t
    :init
    (progn
      (add-hook 'c++-mode-hook
                (lambda ()
                  (require 'cquery)
                  (make-variable-buffer-local 'company-backends)
                  (setq company-backends '(company-lsp))
                  (setq cquery-executable "/usr/bin/cquery")
                  (lsp-cquery-enable)
                  (set (make-variable-buffer-local 'company-idle-delay) 0.1)
                  (set (make-variable-buffer-local 'company-minimum-prefix-length) 2)
                  )))))

;;; packages.el ends here
