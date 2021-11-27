(defconst bazel-packages
  '(
    bazel
    ))

(defun bazel/init-bazel ()
  (use-package bazel
    :init
    (progn
      (setq bazel-buildifier-before-save t))
    :config
    (progn
      (spacemacs/set-leader-keys-for-major-mode 'bazel-build-mode
        "=" 'bazel-buildifier)
      (spacemacs/set-leader-keys-for-major-mode 'bazel-workspace-mode
        "=" 'bazel-buildifier)
      (spacemacs/set-leader-keys-for-major-mode 'bazel-skylark-mode
        "=" 'bazel-buildifier)))
  )
