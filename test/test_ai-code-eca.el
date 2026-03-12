;;; test_ai-code-eca.el --- Tests for ai-code-eca.el -*- lexical-binding: t; -*-

;; Author: Kang Tu <tninja@gmail.com>
;; SPDX-License-Identifier: Apache-2.0

;;; Commentary:
;; Tests for the ai-code-eca backend bridge.

;;; Code:

(require 'ert)
(require 'cl-lib)

(unless (featurep 'magit)
  (defun magit-toplevel (&optional _dir) nil)
  (defun magit-get-current-branch () nil)
  (defun magit-git-lines (&rest _args) nil)
  (provide 'magit))

(require 'ai-code-eca)

(ert-deftest ai-code-test-eca-start-forwards-prefix-arg ()
  "Ensure start forwards prefix args to `eca'."
  (let (called-fn seen-prefix)
    (cl-letf (((symbol-function 'ai-code-eca--ensure-available)
               (lambda ()))
              ((symbol-function 'call-interactively)
               (lambda (fn &optional _record-flag _keys)
                 (setq called-fn fn
                       seen-prefix current-prefix-arg))))
      (ai-code-eca-start '(4))
      (should (eq called-fn 'eca))
      (should (equal seen-prefix '(4))))))

(ert-deftest ai-code-test-eca-switch-uses-existing-session ()
  "Ensure switch opens and jumps to the existing ECA chat buffer."
  (let* ((chat-buffer (get-buffer-create " *ai-code-eca-test*"))
         (popped-to nil))
    (unwind-protect
        (cl-letf (((symbol-function 'ai-code-eca--ensure-available)
                   (lambda ()))
                  ((symbol-function 'eca-session)
                   (lambda () 'mock-session))
                  ((symbol-function 'eca-chat-open)
                   (lambda (_session)))
                  ((symbol-function 'eca-chat--get-last-buffer)
                   (lambda (_session) chat-buffer))
                  ((symbol-function 'pop-to-buffer)
                   (lambda (buf &rest _args)
                     (setq popped-to buf))))
          (ai-code-eca-switch nil)
          (should (eq popped-to chat-buffer)))
      (when (buffer-live-p chat-buffer)
        (kill-buffer chat-buffer)))))

(ert-deftest ai-code-test-eca-switch-errors-without-session ()
  "Ensure switch signals user-error when no ECA session exists."
  (cl-letf (((symbol-function 'ai-code-eca--ensure-available)
             (lambda ()))
            ((symbol-function 'eca-session)
             (lambda () nil)))
    (should-error (ai-code-eca-switch nil) :type 'user-error)))

(ert-deftest ai-code-test-eca-send-command-sends-to-session ()
  "Ensure send command delegates to `eca-chat-send-prompt'."
  (let ((sent-message nil))
    (cl-letf (((symbol-function 'ai-code-eca--ensure-available)
               (lambda ()))
              ((symbol-function 'eca-session)
               (lambda () 'mock-session))
              ((symbol-function 'eca-chat-open)
               (lambda (_session)))
              ((symbol-function 'eca-chat-send-prompt)
               (lambda (_session msg)
                 (setq sent-message msg))))
      (ai-code-eca-send "hello ECA")
      (should (equal sent-message "hello ECA")))))

(ert-deftest ai-code-test-eca-send-command-errors-without-session ()
  "Ensure send command signals user-error when no ECA session exists."
  (cl-letf (((symbol-function 'ai-code-eca--ensure-available)
             (lambda ()))
            ((symbol-function 'eca-session)
             (lambda () nil)))
    (should-error (ai-code-eca-send "hello") :type 'user-error)))

(ert-deftest ai-code-test-eca-resume-forwards-prefix-arg ()
  "Ensure resume forwards prefix args to `eca'."
  (let (called-fn seen-prefix)
    (cl-letf (((symbol-function 'ai-code-eca--ensure-available)
               (lambda ()))
              ((symbol-function 'call-interactively)
               (lambda (fn &optional _record-flag _keys)
                 (setq called-fn fn
                       seen-prefix current-prefix-arg))))
      (ai-code-eca-resume '(4))
      (should (eq called-fn 'eca))
      (should (equal seen-prefix '(4))))))

(provide 'test_ai-code-eca)

;;; test_ai-code-eca.el ends here
