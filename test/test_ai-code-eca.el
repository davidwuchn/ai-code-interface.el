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

(unless (featurep 'ai-code-input)
  (defun ai-code-read-string (_prompt &optional _initial-input _candidate-list)
    "Mock for ai-code-read-string used in tests."
    "mock-input")
  (provide 'ai-code-input))

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
                  ((symbol-function 'ai-code-eca--ensure-chat-buffer)
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

(ert-deftest ai-code-test-eca-switch-force-starts-new-session ()
  "Ensure switch with force-prompt starts a new session."
  (let ((start-called nil)
        (popped-to nil)
        (chat-buffer (get-buffer-create " *ai-code-eca-test-force*")))
    (unwind-protect
        (cl-letf (((symbol-function 'ai-code-eca--ensure-available)
                   (lambda ()))
                  ((symbol-function 'ai-code-eca-start)
                   (lambda (&optional _arg) (setq start-called t)))
                  ((symbol-function 'eca-session)
                   (lambda () 'mock-session))
                  ((symbol-function 'ai-code-eca--ensure-chat-buffer)
                   (lambda (_session) chat-buffer))
                  ((symbol-function 'pop-to-buffer)
                   (lambda (buf &rest _args) (setq popped-to buf)))
                  ((symbol-function 'message)
                   (lambda (&rest _args) nil)))
          (ai-code-eca-switch '(4))
          (should start-called)
          (should (eq popped-to chat-buffer)))
      (when (buffer-live-p chat-buffer)
        (kill-buffer chat-buffer)))))

(ert-deftest ai-code-test-eca-send-command-sends-to-session ()
  "Ensure send command delegates to `eca-chat-send-prompt'."
  (let ((sent-message nil))
    (cl-letf (((symbol-function 'ai-code-eca--ensure-available)
               (lambda ()))
              ((symbol-function 'eca-session)
               (lambda () 'mock-session))
              ((symbol-function 'ai-code-eca--ensure-chat-buffer)
               (lambda (_session) nil))
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

(ert-deftest ai-code-test-eca-resume-switches-to-existing-session ()
  "Ensure resume without arg switches to existing session buffer."
  (let* ((chat-buffer (get-buffer-create " *ai-code-eca-resume-test*"))
         (popped-to nil))
    (unwind-protect
        (cl-letf (((symbol-function 'ai-code-eca--ensure-available)
                   (lambda ()))
                  ((symbol-function 'eca-session)
                   (lambda () 'mock-session))
                  ((symbol-function 'ai-code-eca--ensure-chat-buffer)
                   (lambda (_session) chat-buffer))
                  ((symbol-function 'pop-to-buffer)
                   (lambda (buf &rest _args) (setq popped-to buf)))
                  ((symbol-function 'message)
                   (lambda (&rest _args) nil)))
          (ai-code-eca-resume nil)
          (should (eq popped-to chat-buffer)))
      (when (buffer-live-p chat-buffer)
        (kill-buffer chat-buffer)))))

(ert-deftest ai-code-test-eca-resume-starts-new-when-no-session ()
  "Ensure resume starts a new session when none exists."
  (let ((start-called nil))
    (cl-letf (((symbol-function 'ai-code-eca--ensure-available)
               (lambda ()))
              ((symbol-function 'eca-session)
               (lambda () nil))
              ((symbol-function 'ai-code-eca-start)
               (lambda (&optional _arg) (setq start-called t)))
              ((symbol-function 'message)
               (lambda (&rest _args) nil)))
      (ai-code-eca-resume nil)
      (should start-called))))

(ert-deftest ai-code-test-eca-resume-force-starts-new-session ()
  "Ensure resume with prefix arg starts a new session."
  (let ((start-called-with nil))
    (cl-letf (((symbol-function 'ai-code-eca--ensure-available)
               (lambda ()))
              ((symbol-function 'ai-code-eca-start)
               (lambda (&optional arg) (setq start-called-with arg))))
      (ai-code-eca-resume '(4))
      (should (equal start-called-with '(4))))))

(ert-deftest ai-code-test-eca-ensure-chat-buffer-opens-if-not-visible ()
  "Ensure --ensure-chat-buffer calls eca-chat-open when buffer not visible."
  (let ((open-called nil))
    (cl-letf (((symbol-function 'eca-chat--get-last-buffer)
               (lambda (_session) nil))
              ((symbol-function 'eca-chat-open)
               (lambda (_session) (setq open-called t))))
      (ai-code-eca--ensure-chat-buffer 'mock-session)
      (should open-called))))

(ert-deftest ai-code-test-eca-ensure-chat-buffer-skips-open-when-visible ()
  "Ensure --ensure-chat-buffer skips eca-chat-open when buffer is visible."
  (let* ((chat-buffer (get-buffer-create " *ai-code-eca-visible-test*"))
         (open-called nil))
    (unwind-protect
        (cl-letf (((symbol-function 'eca-chat--get-last-buffer)
                   (lambda (_session) chat-buffer))
                  ((symbol-function 'get-buffer-window)
                   (lambda (_buf) t))
                  ((symbol-function 'eca-chat-open)
                   (lambda (_session) (setq open-called t))))
          (let ((result (ai-code-eca--ensure-chat-buffer 'mock-session)))
            (should (eq result chat-buffer))
            (should-not open-called)))
      (when (buffer-live-p chat-buffer)
        (kill-buffer chat-buffer)))))

(provide 'test_ai-code-eca)

;;; test_ai-code-eca.el ends here
