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

(ert-deftest ai-code-test-github-copilot-cli-start-passes-multiline-sequence ()
  "Starting Copilot should pass the configured multiline sequence to infra."
  (let ((captured-sequence :unset)
        (captured-env-vars :unset))
    (cl-letf (((symbol-function 'ai-code-backends-infra--session-working-directory)
               (lambda () "/tmp/test-copilot"))
              ((symbol-function 'ai-code-backends-infra--resolve-start-command)
               (lambda (&rest _args)
                 (list :command "copilot")))
              ((symbol-function 'ai-code-backends-infra--toggle-or-create-session)
               (lambda (&rest args)
                 (cl-destructuring-bind
                     (_working-dir _buffer-name _process-table _command
                                   &optional _escape-fn _cleanup-fn
                                   _instance-name _prefix _force-prompt
                                   env-vars multiline-input-sequence)
                     args
                   (setq captured-env-vars env-vars)
                   (setq captured-sequence multiline-input-sequence))
                 nil)))
      (let ((ai-code-github-copilot-cli-extra-env-vars '("TERM_PROGRAM=vscode"))
            (ai-code-github-copilot-cli-multiline-input-sequence "\\\r\n"))
        (ai-code-github-copilot-cli)
        (should (equal captured-env-vars '("TERM_PROGRAM=vscode")))
        (should (equal captured-sequence "\\\r\n"))))))

(provide 'test_ai-code-github-copilot-cli)

;;; test_ai-code-github-copilot-cli.el ends here
