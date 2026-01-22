;;; test_ai-code-notifications.el --- Tests for ai-code-notifications.el -*- lexical-binding: t; -*-

;; Author: GitHub Copilot
;; SPDX-License-Identifier: Apache-2.0

;;; Commentary:
;; Tests for the ai-code-notifications module.

;;; Code:

(require 'ert)
(require 'ai-code-notifications)

(ert-deftest ai-code-notifications-test-extract-backend-name ()
  "Test extraction of backend name from buffer name."
  (should (string= "Codex"
                   (ai-code-notifications--extract-backend-name "*codex[my-project]*")))
  (should (string= "Claude-code"
                   (ai-code-notifications--extract-backend-name "*claude-code[test]*")))
  (should (string= "Gemini"
                   (ai-code-notifications--extract-backend-name "*gemini[foo]*")))
  (should (null (ai-code-notifications--extract-backend-name "not-a-session-buffer"))))

(ert-deftest ai-code-notifications-test-extract-project-name ()
  "Test extraction of project name from buffer name."
  (should (string= "my-project"
                   (ai-code-notifications--extract-project-name "*codex[my-project]*")))
  (should (string= "test"
                   (ai-code-notifications--extract-project-name "*claude-code[test]*")))
  (should (null (ai-code-notifications--extract-project-name "not-a-session-buffer"))))

(ert-deftest ai-code-notifications-test-should-notify-when-enabled ()
  "Test that notifications are sent when enabled."
  (let ((ai-code-notifications-enabled t)
        (ai-code-notifications-only-when-not-focused nil))
    (with-temp-buffer
      (should (ai-code-notifications--should-notify-p (current-buffer))))))

(ert-deftest ai-code-notifications-test-should-not-notify-when-disabled ()
  "Test that notifications are not sent when disabled."
  (let ((ai-code-notifications-enabled nil))
    (with-temp-buffer
      (should-not (ai-code-notifications--should-notify-p (current-buffer))))))

(ert-deftest ai-code-notifications-test-should-not-notify-for-dead-buffer ()
  "Test that notifications are not sent for dead buffers."
  (let ((ai-code-notifications-enabled t)
        (dead-buffer (get-buffer-create "temp-test-buffer")))
    (kill-buffer dead-buffer)
    (should-not (ai-code-notifications--should-notify-p dead-buffer))))

(ert-deftest ai-code-notifications-test-response-complete-format ()
  "Test that response complete notifications have correct format."
  (let ((ai-code-notifications-enabled t)
        (ai-code-notifications-on-response-complete t)
        (notification-sent nil)
        (notification-title nil)
        (notification-body nil))
    ;; Mock the notification function
    (cl-letf (((symbol-function 'ai-code-notifications--send)
               (lambda (title body _buffer)
                 (setq notification-sent t
                       notification-title title
                       notification-body body))))
      (with-temp-buffer
        (rename-buffer "*codex[test-project]*")
        (ai-code-notifications-response-complete (current-buffer))
        (should notification-sent)
        (should (string= "Codex" notification-title))
        (should (string-match-p "test-project" notification-body))))))

(ert-deftest ai-code-notifications-test-error-notification-format ()
  "Test that error notifications have correct format."
  (let ((ai-code-notifications-enabled t)
        (ai-code-notifications-on-error t)
        (notification-sent nil)
        (notification-title nil)
        (notification-body nil))
    ;; Mock the notification function
    (cl-letf (((symbol-function 'ai-code-notifications--send)
               (lambda (title body _buffer)
                 (setq notification-sent t
                       notification-title title
                       notification-body body))))
      (with-temp-buffer
        (rename-buffer "*gemini[my-app]*")
        (ai-code-notifications-error (current-buffer) "Connection timeout")
        (should notification-sent)
        (should (string-match-p "Gemini" notification-title))
        (should (string= "Connection timeout" notification-body))))))

(ert-deftest ai-code-notifications-test-session-end-format ()
  "Test that session end notifications have correct format."
  (let ((ai-code-notifications-enabled t)
        (ai-code-notifications-on-session-end t)
        (notification-sent nil)
        (notification-title nil)
        (notification-body nil))
    ;; Mock the notification function
    (cl-letf (((symbol-function 'ai-code-notifications--send)
               (lambda (title body _buffer)
                 (setq notification-sent t
                       notification-title title
                       notification-body body))))
      (with-temp-buffer
        (rename-buffer "*cursor[web-app]*")
        (ai-code-notifications-session-end (current-buffer))
        (should notification-sent)
        (should (string= "Cursor" notification-title))
        (should (string-match-p "web-app" notification-body))))))

(ert-deftest ai-code-notifications-test-respect-response-complete-flag ()
  "Test that response-complete flag is respected."
  (let ((ai-code-notifications-enabled t)
        (ai-code-notifications-on-response-complete nil)
        (notification-sent nil))
    ;; Mock the notification function
    (cl-letf (((symbol-function 'ai-code-notifications--send)
               (lambda (_title _body _buffer)
                 (setq notification-sent t))))
      (with-temp-buffer
        (rename-buffer "*codex[test]*")
        (ai-code-notifications-response-complete (current-buffer))
        (should-not notification-sent)))))

(ert-deftest ai-code-notifications-test-respect-error-flag ()
  "Test that error flag is respected."
  (let ((ai-code-notifications-enabled t)
        (ai-code-notifications-on-error nil)
        (notification-sent nil))
    ;; Mock the notification function
    (cl-letf (((symbol-function 'ai-code-notifications--send)
               (lambda (_title _body _buffer)
                 (setq notification-sent t))))
      (with-temp-buffer
        (rename-buffer "*codex[test]*")
        (ai-code-notifications-error (current-buffer) "Error message")
        (should-not notification-sent)))))

(ert-deftest ai-code-notifications-test-respect-session-end-flag ()
  "Test that session-end flag is respected."
  (let ((ai-code-notifications-enabled t)
        (ai-code-notifications-on-session-end nil)
        (notification-sent nil))
    ;; Mock the notification function
    (cl-letf (((symbol-function 'ai-code-notifications--send)
               (lambda (_title _body _buffer)
                 (setq notification-sent t))))
      (with-temp-buffer
        (rename-buffer "*codex[test]*")
        (ai-code-notifications-session-end (current-buffer))
        (should-not notification-sent)))))

(provide 'test_ai-code-notifications)
;;; test_ai-code-notifications.el ends here
