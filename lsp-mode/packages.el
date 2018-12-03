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
  (with-eval-after-load 'projectile
    (setq projectile-project-root-files-top-down-recurring
          (append '("compile_commands.json"
                    ".cquery")
                  projectile-project-root-files-top-down-recurring)))
  (defun cquery//enable ()
    (require 'company-lsp)
    (make-variable-buffer-local 'company-backends)
    (setq company-backends '(company-lsp))
    (set (make-variable-buffer-local 'company-idle-delay) 0.1)
    (set (make-variable-buffer-local 'company-minimum-prefix-length) 2)
    (condition-case nil
        (lsp-cquery-enable)
      (user-error nil)))
  (use-package cquery
    :defer t
    :commands lsp-cquery-enable
    :config
    (setq cquery-executable
          (seq-find
           #'file-executable-p
           (list
            "/usr/bin/cquery"
            "/usr/local/bin/cquery"
            (expand-file-name "~/homebrew/bin/cquery"))))
    :init
    (add-hook 'c-mode-hook #'cquery//enable)
    (add-hook 'c++-mode-hook #'cquery//enable)
    ))

;;; packages.el ends here
