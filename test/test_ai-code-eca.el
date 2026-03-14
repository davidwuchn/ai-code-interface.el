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

(defvar package-vc-selected-packages)

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

(ert-deftest ai-code-test-eca-get-sessions-formats-session-info ()
  "Ensure `ai-code-eca-get-sessions' formats session metadata."
  (cl-letf (((symbol-function 'eca-list-sessions)
             (lambda ()
               '((:id 7 :workspace-folders ("/a" "/b") :chat-count 3)))))
    (should (equal (ai-code-eca-get-sessions)
                   '((7 . "Session 7: /a, /b (3 chats)"))))))

(ert-deftest ai-code-test-eca-toggle-auto-switch-cycles-values ()
  "Ensure auto-switch toggles nil -> prompt -> t -> nil."
  (let ((eca-auto-switch-session nil))
    (cl-letf (((symbol-function 'message) (lambda (&rest _args) nil)))
      (ai-code-eca-toggle-auto-switch)
      (should (eq eca-auto-switch-session 'prompt))
      (ai-code-eca-toggle-auto-switch)
      (should (eq eca-auto-switch-session t))
      (ai-code-eca-toggle-auto-switch)
      (should (null eca-auto-switch-session)))))

(ert-deftest ai-code-test-eca-sync-project-workspaces-adds-missing-root ()
  "Ensure project workspace sync adds missing roots only once."
  (let (added)
    (cl-letf (((symbol-function 'ai-code-eca--ensure-available) (lambda ()))
              ((symbol-function 'eca-session) (lambda () 'mock-session))
              ((symbol-function 'projectile-project-root) (lambda () "/repo"))
              ((symbol-function 'eca-list-workspace-folders) (lambda (_session) nil))
              ((symbol-function 'eca-add-workspace-folder)
               (lambda (folder _session) (push folder added)))
              ((symbol-function 'eca--session-id) (lambda (_session) 9)))
      (with-temp-buffer
        (setq buffer-file-name "/repo/file.el")
        (ai-code-eca-sync-project-workspaces))
      (should (equal added '("/repo"))))))

(ert-deftest ai-code-test-eca-verify-health-noninteractive ()
  "Ensure `ai-code-eca-verify-health' returns non-nil for ready sessions."
  (cl-letf (((symbol-function 'ai-code-eca--ensure-available) (lambda ()))
            ((symbol-function 'eca-session) (lambda () 'mock-session))
            ((symbol-function 'eca--session-status) (lambda (_session) 'ready))
            ((symbol-function 'eca--session-workspace-folders)
             (lambda (_session) '("/repo"))))
    (should (ai-code-eca-verify-health))))

(ert-deftest ai-code-test-eca-share-file-delegates-to-eca-ext ()
  "Ensure shared file wrapper delegates to eca-ext."
  (let (shared-file)
    (cl-letf (((symbol-function 'eca-share-file-context)
               (lambda (file-path) (setq shared-file file-path))))
      (ai-code-eca-share-file "/tmp/example.txt")
      (should (equal shared-file "/tmp/example.txt")))))

(ert-deftest ai-code-test-eca-upgrade-vc-uses-package-vc-when-selected ()
  "Ensure VC-installed ECA upgrades through `package-vc-upgrade'."
  (let ((package-vc-selected-packages '((eca . "https://example.test/eca.git")))
        called)
    (provide 'package-vc)
    (cl-letf (((symbol-function 'package-vc-upgrade)
               (lambda (pkg) (setq called pkg)))
              ((symbol-function 'message) (lambda (&rest _args) nil)))
      (ai-code-eca-upgrade-vc)
      (should (eq called 'eca)))))

(ert-deftest ai-code-test-eca-sync-context-delegates-to-context-helpers ()
  "Ensure `ai-code-eca-sync-context' sends file and cursor context."
  (let (file-calls cursor-calls)
    (cl-letf (((symbol-function 'eca-session) (lambda () 'mock-session))
              ((symbol-function 'eca-chat-add-file-context)
               (lambda (_session file-path) (push file-path file-calls)))
              ((symbol-function 'eca-chat-add-cursor-context)
               (lambda (_session file-path pos)
                 (push (list file-path pos) cursor-calls)))
              ((symbol-function 'message) (lambda (&rest _args) nil)))
      (with-temp-buffer
        (setq buffer-file-name "/tmp/example.el")
        (goto-char (point-min))
        (ai-code-eca-sync-context))
      (should (equal file-calls '("/tmp/example.el")))
      (should (equal cursor-calls '(("/tmp/example.el" 1)))))))

(ert-deftest ai-code-test-eca-add-menu-suffixes-appends-all-groups ()
  "Ensure ECA backend appends all ai-code-menu transient groups."
  (let ((ai-code-selected-backend 'eca)
        (ai-code-eca--menu-suffixes-added nil)
        calls)
    (provide 'transient)
    (cl-letf (((symbol-function 'ai-code-menu) (lambda () nil))
              ((symbol-function 'transient-append-suffix)
               (lambda (prefix loc suffix &optional _face)
                 (push (list prefix loc suffix) calls))))
      (ai-code-eca--add-menu-suffixes)
      (should ai-code-eca--menu-suffixes-added)
      (should (= (length calls) 4))
      (should (equal (mapcar #'cadr (nreverse calls))
                     '("Other Tools"
                       "ECA Workspace"
                       "ECA Context"
                       "ECA Shared Context"))))))

(ert-deftest ai-code-test-eca-remove-menu-suffixes-removes-all-groups ()
  "Ensure ECA transient groups are removed when switching away."
  (let ((ai-code-eca--menu-suffixes-added t)
        calls)
    (provide 'transient)
    (cl-letf (((symbol-function 'ai-code-menu) (lambda () nil))
              ((symbol-function 'transient-remove-suffix)
               (lambda (prefix suffix)
                 (push (list prefix suffix) calls))))
      (ai-code-eca--remove-menu-suffixes)
      (should-not ai-code-eca--menu-suffixes-added)
      (should (equal (mapcar #'cadr (nreverse calls))
                     ai-code-eca--menu-group-order)))))

(provide 'test_ai-code-eca)

;;; test_ai-code-eca.el ends here
