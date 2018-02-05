;;; packages.el --- myconfigs layer packages file for Spacemacs.
;;
;; Copyright (c) 2012-2016 Sylvain Benner & Contributors
;;
;; Author: Tiger Chen <chencaibin@chencaibin-macbookpro2.roam.corp.google.com>
;; URL: https://github.com/syl20bnr/spacemacs
;;
;; This file is not part of GNU Emacs.
;;
;;; License: GPLv3

;;; Code:

(defconst myconfigs-packages
  '(
    protobuf-mode
    (google-java-format :location local)
    google-c-style
    pkgbuild-mode
    realgud
    company
    (flycheck-package :requires flycheck)
    (buttercup)
    ))

(defun myconfigs/init-protobuf-mode ()
  (use-package protobuf-mode :defer t))

(defun myconfigs/init-google-java-format ()
  (use-package google-java-format
    :commands 'google-java-format-buffer
    :defer t
    :init
    (progn
      (spacemacs/set-leader-keys-for-major-mode 'java-mode
        "fb" #'google-java-format-buffer
        "fr" #'google-java-format-region
        )
      (if (eq system-type 'darwin)
          (setq google-java-format-executable (expand-file-name "/usr/local/bin/google-java-format"))
        (setq google-java-format-executable "google-java-format")))))

(defun myconfigs/init-google-c-style ()
  (add-hook 'c-mode-common-hook 'google-set-c-style))

(defun myconfigs/init-pkgbuild-mode())

(defun myconfigs/init-realgud()
  (use-package realgud
    :defer t
    :commands (realgud:gdb realgud:jdb)
    :init
    (progn
      (dolist (mode '(c-mode c++-mode))
        (spacemacs/set-leader-keys-for-major-mode mode
          "dd" 'realgud:gdb
          "de" 'realgud:cmd-eval-dwim))
      (spacemacs/set-leader-keys-for-major-mode 'java-mode
        "dd" 'realgud:jdb
        "de" 'realgud:cmd-eval-dwim)
      (advice-add 'realgud-short-key-mode-setup
                  :before #'spacemacs//short-key-state)
      (evilified-state-evilify-map realgud:shortkey-mode-map
        :eval-after-load realgud
        :mode realgud-short-key-mode
        :bindings
        "s" 'realgud:cmd-next
        "i" 'realgud:cmd-step
        "b" 'realgud:cmd-break
        "B" 'realgud:cmd-clear
        "o" 'realgud:cmd-finish
        "c" 'realgud:cmd-continue
        "e" 'realgud:cmd-eval
        "r" 'realgud:cmd-restart
        "q" 'realgud:cmd-quit
        "S" 'realgud-window-cmd-undisturb-src))))

(defun myconfigs/post-init-company ()
  ;; No delay for company completion.
  (setq company-idle-delay 0))

(defun myconfigs/init-flycheck-package ()
  (use-package flycheck-package
    :defer t
    :init
    (add-hook 'flycheck-mode-hook 'flycheck-package-setup)))

(defun myconfigs/init-buttercup ())

;;; packages.el ends here
