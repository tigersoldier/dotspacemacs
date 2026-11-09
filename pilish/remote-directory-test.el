;;; remote-directory-test.el --- Remote directory picker tests. -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)

;; Dynamic variables bound by `pilish-test--with-cache'.
(defvar pilish/remote-directory-cache-ttl)
(defvar pilish//remote-directory-list-cache)
(defvar pilish//remote-directory-prefetch-done)
(defvar pilish//remote-directory-prefetch-pending)
(defvar pilish//remote-directory-prefetch-queue)
(defvar pilish//remote-directory-prefetch-process)

(defvar spacemacs-cache-directory temporary-file-directory)
(defvar helm-pattern "")

(load (expand-file-name
       "funcs.el"
       (file-name-directory (or load-file-name buffer-file-name)))
      nil t)

(defmacro pilish-test--with-cache (&rest body)
  "Run BODY with fresh remote directory cache tables."
  `(let ((pilish//remote-directory-list-cache (make-hash-table :test 'equal))
         (pilish//remote-directory-prefetch-done (make-hash-table :test 'equal))
         (pilish//remote-directory-prefetch-pending (make-hash-table :test 'equal))
         (pilish//remote-directory-prefetch-queue nil)
         (pilish//remote-directory-prefetch-process nil)
         (pilish/remote-directory-cache-ttl 60))
     ,@body))

(ert-deftest pilish-remote-directory-parse-find-output ()
  "Two find levels become one child list and a per-child child alist."
  (let ((parsed (pilish//remote-directory-parse-find-output
                 (concat "./a\n./a/x\n./a/y\n./b\n./a/x/z\n"
                         "./space dir\n./space dir/sub\n./.git\n"))))
    (should (equal '(".git" "a" "b" "space dir") (car parsed)))
    (should (equal '((".git") ("a" "x" "y") ("b") ("space dir" "sub"))
                   (cdr parsed)))
    (should (equal '("x" "y") (cdr (assoc "a" (cdr parsed)))))
    (should-not (cdr (assoc "b" (cdr parsed))))))

(ert-deftest pilish-remote-directory-cache-store-keeps-fresh-entry ()
  "An asynchronous result must not replace a synchronous listing."
  (pilish-test--with-cache
    (let ((directory "/ssh:testhost:/home/pi/foo/"))
      (pilish//remote-directory-cache-store directory '("a"))
      (should (equal '("a")
                     (cdr (pilish//remote-directory-cache-entry directory))))
      (pilish//remote-directory-cache-store directory '("b"))
      (should (equal '("a")
                     (cdr (pilish//remote-directory-cache-entry directory))))
      ;; An expired listing counts as a miss and is replaced.
      (puthash (pilish//remote-directory-cache-key directory)
               (cons (- (float-time) 120) '("old"))
               pilish//remote-directory-list-cache)
      (pilish//remote-directory-cache-store directory '("new"))
      (should (equal '("new")
                     (cdr (pilish//remote-directory-cache-entry directory)))))))

(ert-deftest pilish-remote-directory-cache-store-disabled ()
  "A zero TTL disables both reuse and asynchronous cache filling."
  (pilish-test--with-cache
    (let ((pilish/remote-directory-cache-ttl 0)
          (directory "/ssh:testhost:/home/pi/foo/"))
      (pilish//remote-directory-cache-store directory '("a"))
      (should-not (gethash (pilish//remote-directory-cache-key directory)
                           pilish//remote-directory-list-cache)))))

(ert-deftest pilish-remote-directory-prefetch-apply-fills-children ()
  "Applying a find listing fills children but preserves the shown entry."
  (pilish-test--with-cache
    (let* ((foo "/ssh:testhost:/home/pi/foo/")
           (bar (concat foo "bar/"))
           (baz (concat foo "baz/")))
      ;; The synchronous listing of foo is newer than the async walk.
      (puthash (pilish//remote-directory-cache-key foo)
               (cons (float-time) '("bar" "baz"))
               pilish//remote-directory-list-cache)
      (puthash (pilish//remote-directory-cache-key bar)
               (cons (- (float-time) 120) '("stale"))
               pilish//remote-directory-list-cache)
      (pilish//remote-directory-prefetch-apply foo "./bar\n./bar/qux\n./baz\n")
      (should (equal '("bar" "baz")
                     (cdr (pilish//remote-directory-cache-entry foo))))
      (should (equal '("qux")
                     (cdr (pilish//remote-directory-cache-entry bar))))
      ;; A child with no subdirectories is cached as known-empty.
      (should (pilish//remote-directory-cache-entry baz))
      (should-not (cdr (pilish//remote-directory-cache-entry baz)))
      ;; The walk is throttled for the same TTL as the cache.
      (should (gethash (pilish//remote-directory-cache-key foo)
                       pilish//remote-directory-prefetch-done)))))

(ert-deftest pilish-remote-directory-typed-children-uses-cache ()
  "Typing a cached directory with a slash renders its children in place."
  (pilish-test--with-cache
    (let* ((prefix "/ssh:testhost:")
           (home (concat prefix "/home/pi/"))
           (foo (concat home "foo/")))
      (puthash (pilish//remote-directory-cache-key foo)
               (cons (float-time) '("bar" "baz"))
               pilish//remote-directory-list-cache)
      (let ((helm-pattern "foo/")
            (pilish//remote-directory-picker-current home)
            (pilish//remote-directory-picker-home home)
            (pilish//remote-directory-picker-prefix prefix)
            prefetch-calls)
        (cl-letf (((symbol-function 'pilish//remote-directory-prefetch)
                   (lambda (directory &optional force notify)
                     (push (list directory force notify) prefetch-calls))))
          (should (equal
                   '(("foo/bar/" . "/ssh:testhost:/home/pi/foo/bar/")
                     ("foo/baz/" . "/ssh:testhost:/home/pi/foo/baz/"))
                   (pilish//remote-directory-typed-children)))
          ;; Displaying the children also warms their own children.
          (should (equal (list (list foo nil nil)) prefetch-calls)))))))

(ert-deftest pilish-remote-directory-typed-children-fetches-on-slash ()
  "A slash for an uncached directory starts an asynchronous listing."
  (pilish-test--with-cache
    (let* ((prefix "/ssh:testhost:")
           (home (concat prefix "/home/pi/"))
           (foo (concat home "foo/")))
      (let ((helm-pattern "foo/")
            (pilish//remote-directory-picker-current home)
            (pilish//remote-directory-picker-home home)
            (pilish//remote-directory-picker-prefix prefix)
            prefetch-calls)
        (cl-letf (((symbol-function 'pilish//remote-directory-prefetch)
                   (lambda (directory &optional force notify)
                     (push (list directory force notify) prefetch-calls)
                     '("not-a-candidate"))))
          (should-not (pilish//remote-directory-typed-children))
          (should (equal (list (list foo t t)) prefetch-calls)))))))

(ert-deftest pilish-remote-directory-picker-show-clears-input ()
  "Entering a directory clears the stale Helm pattern before updating."
  (pilish-test--with-cache
    (let* ((prefix "/ssh:testhost:")
           (home (concat prefix "/home/pi/"))
           (foo (concat home "foo/"))
           calls)
      (let ((pilish//remote-directory-picker-current home)
            (pilish//remote-directory-picker-children '("foo"))
            (pilish//remote-directory-picker-home home)
            (pilish//remote-directory-picker-prefix prefix))
        (cl-letf (((symbol-function 'helm-get-selection)
                   (lambda (&rest _) foo))
                  ((symbol-function 'pilish//remote-directory-validate)
                   #'identity)
                  ((symbol-function 'pilish//remote-directory-cached-children)
                   (lambda (_directory) '("bar" "baz")))
                  ((symbol-function 'helm-set-pattern)
                   (lambda (pattern &optional noupdate)
                     (push (list 'set-pattern pattern noupdate) calls)))
                  ((symbol-function 'helm-force-update)
                   (lambda (&rest args)
                     (push (cons 'force-update args) calls))))
          (pilish//remote-directory-picker-enter)
          (should (equal foo pilish//remote-directory-picker-current))
          (should (equal '("bar" "baz")
                         pilish//remote-directory-picker-children))
          ;; The empty pattern must be installed before the forced update.
          (should (equal '((force-update nil)
                           (set-pattern "" t))
                         calls)))))))
