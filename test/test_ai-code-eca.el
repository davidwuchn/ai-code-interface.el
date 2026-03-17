;;; test_ai-code-eca.el --- Tests for ECA backend -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'ai-code-backends)
(require 'ai-code-eca)

(ert-deftest ai-code-test-eca-backend-registered ()
  "ECA should be registered in ai-code-backends."
  (should (assoc 'eca ai-code-backends)))

(ert-deftest ai-code-test-eca-backend-has-required-keys ()
  "ECA backend should have all required keys."
  (let ((spec (cdr (assoc 'eca ai-code-backends))))
    (should (plist-get spec :label))
    (should (plist-get spec :require))
    (should (plist-get spec :start))
    (should (plist-get spec :switch))
    (should (plist-get spec :send))
    (should (plist-get spec :resume))
    (should (plist-get spec :upgrade))
    (should (plist-get spec :install-skills))))

(ert-deftest ai-code-test-eca-add-menu-group-when-eca-selected ()
  "Ensure ECA menu is added when ECA backend is selected."
  (let ((ai-code-eca--menu-group-added nil))
    (provide 'transient)
    (cl-letf (((symbol-function 'commandp) (lambda (_sym) t))
              ((symbol-function 'transient-append-suffix)
               (lambda (prefix loc suffix &optional _face)
                 (should (memq prefix '(ai-code-menu-default ai-code-menu-2-columns)))
                 (should (equal loc '(0 -1))))))
      (ai-code-eca--add-menu-group)
      (should ai-code-eca--menu-group-added))))

(ert-deftest ai-code-test-eca-remove-menu-group ()
  "Ensure ECA menu is removed when switching away."
  (let ((ai-code-eca--menu-group-added t)
        (removed-keys nil))
    (provide 'transient)
    (cl-letf (((symbol-function 'commandp) (lambda (_sym) t))
              ((symbol-function 'transient-remove-suffix)
               (lambda (prefix key)
                 (should (memq prefix '(ai-code-menu-default ai-code-menu-2-columns)))
                 (push key removed-keys))))
      (ai-code-eca--remove-menu-group)
      (should-not ai-code-eca--menu-group-added)
      (should (equal (length removed-keys) 18))
      (dolist (key '("A" "B" "D" "E" "F" "M" "W" "X" "Y"))
        (should (= (cl-count key removed-keys :test #'string=) 2))))))

(ert-deftest ai-code-test-eca-menu-group-not-added-when-other-backend ()
  "ECA menu should not be added when other backend is selected."
  (let ((ai-code-selected-backend 'claude-code)
        (ai-code-eca--menu-group-added nil))
    (ai-code-eca--add-menu-group)
    (should-not ai-code-eca--menu-group-added)))

(ert-deftest ai-code-test-eca-menu-group-appears-in-layout ()
  "ECA group should appear in the transient layout after adding.
This test does NOT mock transient-append-suffix; it verifies the actual
layout contains an ECA group with the expected suffixes."
  (skip-unless (featurep 'transient))
  (require 'ai-code)
  (let ((ai-code-eca--menu-group-added nil))
    (ai-code-eca--add-menu-group)
    (unwind-protect
        (dolist (prefix '(ai-code-menu-default ai-code-menu-2-columns))
          (let* ((layout (get prefix 'transient--layout))
                 (all-keys nil))
            (when (and layout (vectorp layout))
              (let ((groups (aref layout 2)))
                (dolist (group (append groups nil))
                  (when (vectorp group)
                    (dolist (item (aref group 3))
                      (when (vectorp item)
                        (let ((key (aref item 2)))
                          (when (stringp key)
                            (push key all-keys))))))))
              (dolist (expected-key '("E" "W" "D" "A" "X" "F" "M" "Y" "B"))
                (should (member expected-key all-keys)
                        (format "ECA key %s not found in %s layout (keys: %s)"
                                expected-key prefix all-keys))))))
      (setq ai-code-eca--menu-group-added nil))))

(provide 'test_ai-code-eca)

;;; test_ai-code-eca.el ends here
