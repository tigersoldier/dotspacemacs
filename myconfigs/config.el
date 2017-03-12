(setq-default
 indent-tabs-mode nil)
(setq tab-width 2
      c-basic-offset 2
      mac-command-modifier 'meta
      explicit-shell-file-name (expand-file-name "~/homebrew/bin/bash"))

(defun my-java-format ()
  (setq c-basic-offset 2))

(add-hook 'java-mode-hook #'my-java-format)

(defun buildifier ()
  (interactive)
  (start-process "buildifier" nil "buildifier" (buffer-file-name)))
