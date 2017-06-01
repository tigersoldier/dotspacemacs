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
    company
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
          (setq google-java-format-executable (expand-file-name "~/homebrew/bin/google-java-format"))
        (setq google-java-format-executable "google-java-format")))))

(defun myconfigs/init-google-c-style ()
  (add-hook 'c-mode-common-hook 'google-set-c-style))

(defun myconfigs/init-pkgbuild-mode())

(defun myconfigs/post-init-company ()
  ;; No delay for company completion.
  (setq company-idle-delay 0))

;;; packages.el ends here
