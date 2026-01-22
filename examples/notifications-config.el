;;; Notification Configuration Examples for ai-code-interface.el

;; This file contains example configurations for the notification feature.
;; Copy the sections you want to your init.el or .emacs file.

;;; Basic Configuration (Recommended)

;; Enable notifications with default settings
;; This will notify you when:
;; - AI completes a response
;; - An error occurs
;; - A session terminates
;; Notifications only appear when the AI buffer is not focused
(use-package ai-code
  :config
  (setq ai-code-notifications-enabled t))

;;; Custom Configuration Examples

;; Example 1: Only notify on response completion
(setq ai-code-notifications-enabled t
      ai-code-notifications-on-response-complete t
      ai-code-notifications-on-error nil
      ai-code-notifications-on-session-end nil)

;; Example 2: Always notify, even when the AI buffer is focused
;; Useful if you're monitoring multiple sessions on different screens
(setq ai-code-notifications-enabled t
      ai-code-notifications-only-when-not-focused nil)

;; Example 3: Critical priority notifications with longer timeout
;; Good for important projects where you don't want to miss responses
(setq ai-code-notifications-enabled t
      ai-code-notifications-urgency 'critical
      ai-code-notifications-timeout 10000) ; 10 seconds

;; Example 4: Low priority notifications that auto-dismiss
;; Good for background monitoring
(setq ai-code-notifications-enabled t
      ai-code-notifications-urgency 'low
      ai-code-notifications-timeout -1) ; Use system default

;; Example 5: Persistent notifications (don't auto-dismiss)
;; Useful if you frequently step away and want to see what happened
(setq ai-code-notifications-enabled t
      ai-code-notifications-timeout 0) ; Never timeout

;; Example 6: Disable notifications entirely
;; If you prefer to check the AI buffer manually
(setq ai-code-notifications-enabled nil)

;;; Custom Completion Patterns

;; If you're using a custom AI backend or the default patterns don't work,
;; you can customize the completion detection patterns:
(setq ai-code-backends-infra-notification-patterns
      '(("Codex" . "\\(^>\\|100% context left\\)")
        ("Claude" . "^<claude>")
        ("Gemini" . "^Gemini>")
        ("Copilot" . "^>")
        ("MyCustomBackend" . "^Ready>"))) ; Add your custom pattern here

;;; Testing Notifications

;; You can test if notifications are working by evaluating this in a buffer
;; that looks like an AI session buffer:
;; (progn
;;   (rename-buffer "*codex[test-project]*")
;;   (ai-code-notifications-response-complete (current-buffer)))

;;; Troubleshooting

;; If notifications aren't appearing:
;; 1. Check if notifications are enabled:
;;    M-: ai-code-notifications-enabled RET
;;    Should return 't'
;;
;; 2. Check if your system supports notifications:
;;    M-: (featurep 'dbusbind) RET
;;    Should return 't' on systems with D-Bus support
;;
;; 3. Check if the notifications package is available:
;;    M-: (require 'notifications nil t) RET
;;    Should return 'notifications' if available
;;
;; 4. Check the completion patterns match your backend's output:
;;    Look at the actual terminal output and ensure the pattern matches
;;
;; 5. Make sure you're not in the AI buffer when expecting a notification
;;    (if ai-code-notifications-only-when-not-focused is t)
