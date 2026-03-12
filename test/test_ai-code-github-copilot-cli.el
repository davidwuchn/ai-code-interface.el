;;; test_ai-code-github-copilot-cli.el --- Tests for ai-code-github-copilot-cli -*- lexical-binding: t; -*-

;; Author: Kang Tu <tninja@gmail.com>
;; SPDX-License-Identifier: Apache-2.0

;;; Commentary:
;; Tests for the ai-code-github-copilot-cli module.

;;; Code:

(require 'ert)
(require 'cl-lib)
(unless (featurep 'magit)
  (defun magit-toplevel (&optional _dir) nil)
  (defun magit-get-current-branch () nil)
  (defun magit-git-lines (&rest _args) nil)
  (provide 'magit))
(require 'ai-code-github-copilot-cli)

(ert-deftest ai-code-test-github-copilot-cli-configure-buffer-binds-multiline-keys ()
  "Shift+Enter and Ctrl+Enter should send the Copilot multiline sequence."
  (let ((buffer (generate-new-buffer " *ai-code-copilot-test*"))
        (calls nil)
        (ai-code-github-copilot-cli-multiline-input-sequence "\\\r\n"))
    (unwind-protect
        (cl-letf (((symbol-function 'ai-code-backends-infra--terminal-send-string)
                   (lambda (string)
                     (push string calls))))
          (ai-code-github-copilot-cli--configure-buffer buffer)
          (with-current-buffer buffer
            (call-interactively (key-binding (kbd "S-<return>")))
            (call-interactively (key-binding (kbd "C-<return>"))))
          (should (equal (nreverse calls) '("\\\r\n" "\\\r\n"))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest ai-code-test-github-copilot-cli-start-configures-session-buffer ()
  "Starting Copilot should configure the selected session buffer."
  (let ((buffer (generate-new-buffer " *ai-code-copilot-start*"))
        (configured nil))
    (unwind-protect
        (cl-letf (((symbol-function 'ai-code-backends-infra--session-working-directory)
                   (lambda () "/tmp/test-copilot"))
                  ((symbol-function 'ai-code-backends-infra--resolve-start-command)
                   (lambda (&rest _args)
                     (list :command "copilot")))
                  ((symbol-function 'ai-code-backends-infra--toggle-or-create-session)
                   (lambda (&rest _args) nil))
                  ((symbol-function 'ai-code-backends-infra--select-session-buffer)
                   (lambda (&rest _args) buffer))
                  ((symbol-function 'ai-code-github-copilot-cli--configure-buffer)
                   (lambda (target)
                     (setq configured target))))
          (ai-code-github-copilot-cli)
          (should (eq configured buffer)))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(provide 'test_ai-code-github-copilot-cli)

;;; test_ai-code-github-copilot-cli.el ends here
