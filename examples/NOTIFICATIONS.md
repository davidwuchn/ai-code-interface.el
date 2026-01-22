# Desktop Notifications Implementation Guide

## Overview

This document explains how desktop notifications work in ai-code-interface.el and how they are implemented.

## Architecture

The notification system consists of three main components:

### 1. Notification Module (`ai-code-notifications.el`)

This module provides the core notification functionality:
- Desktop notification API wrapper (using Emacs `notifications-notify`)
- Configuration options for enabling/disabling notifications
- Helper functions for extracting backend and project information
- Fallback to echo area messages on systems without D-Bus support

### 2. Backend Integration (`ai-code-backends-infra.el`)

The backend infrastructure monitors terminal output and triggers notifications:
- **Output Monitoring**: Hooks into both vterm and eat terminal backends
- **Pattern Matching**: Uses configurable regex patterns to detect response completion
- **State Management**: Tracks whether a notification has been sent for each response
- **Process Sentinels**: Monitors session lifecycle for termination notifications

### 3. Pattern Detection

Each AI backend has a unique prompt pattern that indicates response completion:

| Backend | Pattern | Example |
|---------|---------|---------|
| Codex | `^>` or `100% context left` | When the `>` prompt returns |
| Claude | `^<claude>` | When the Claude prompt appears |
| Gemini | `^Gemini>` | When the Gemini prompt appears |
| Copilot | `^>` | When the `>` prompt returns |
| Others | `^>` | Default prompt pattern |

## How It Works

### Response Completion Detection

1. **User sends a command** to the AI backend
   - `ai-code-backends-infra--send-line-to-session` resets notification state
   - The command is sent to the terminal

2. **AI processes and responds**
   - Output flows through the terminal (vterm or eat)
   - Each chunk of output is checked against completion patterns

3. **Completion pattern detected**
   - The pattern matching function checks if:
     - A completion pattern is matched in the output
     - A notification hasn't been sent yet for this response
   - If both conditions are true:
     - Set the notification-sent flag
     - Call `ai-code-notifications-response-complete`

4. **Notification is displayed**
   - Check if notifications should be sent (enabled, buffer not focused, etc.)
   - Send desktop notification or fall back to echo area message
   - Notification includes backend name and project name

### Session Termination Detection

Process sentinels monitor when AI sessions end:

```elisp
(set-process-sentinel process
  (lambda (proc event)
    (when (string-match-p "\\(finished\\|exited\\)" event)
      (ai-code-notifications-session-end (process-buffer proc)))))
```

## Implementation Details

### For vterm Backend

The notification check is integrated into the smart renderer:

```elisp
(defun ai-code-backends-infra--vterm-smart-renderer (orig-fun process input)
  ;; ... existing code ...
  (with-current-buffer (process-buffer process)
    ;; Check for completion patterns and send notifications
    (ai-code-backends-infra--check-completion-pattern (current-buffer) input)
    ;; ... rest of rendering logic ...
    ))
```

### For eat Backend

A process filter is added after creating the terminal:

```elisp
(when-let ((proc (get-buffer-process buffer)))
  (add-function :after (process-filter proc)
               #'ai-code-backends-infra--process-output-filter))
```

## Configuration Options

All configuration is done through customize variables:

### Main Toggle
- `ai-code-notifications-enabled` - Master enable/disable switch

### Event Types
- `ai-code-notifications-on-response-complete` - Notify when AI completes
- `ai-code-notifications-on-error` - Notify on errors
- `ai-code-notifications-on-session-end` - Notify when session ends

### Behavior
- `ai-code-notifications-only-when-not-focused` - Only notify if buffer not visible
- `ai-code-notifications-urgency` - Notification priority (low/normal/critical)
- `ai-code-notifications-timeout` - How long notification persists (ms)

### Pattern Customization
- `ai-code-backends-infra-notification-patterns` - Regex patterns for each backend

## System Requirements

### Supported Systems
- GNU/Linux with D-Bus support
- Any system with the `notifications` package available

### Fallback Behavior
On systems without notification support:
- Notifications fall back to `(message "...")` in the echo area
- All other functionality works normally
- No errors are raised

## Testing

### Unit Tests
See `test/test_ai-code-notifications.el` for comprehensive tests covering:
- Pattern extraction (backend and project names)
- Notification enabling/disabling logic
- Focus detection
- Message formatting

### Manual Testing
To test notifications manually:

```elisp
;; 1. Create a mock AI session buffer
(with-current-buffer (get-buffer-create "*codex[test]*")
  ;; 2. Trigger a response complete notification
  (ai-code-notifications-response-complete (current-buffer)))
```

## Customization Examples

### Only Notify for Critical Events
```elisp
(setq ai-code-notifications-on-response-complete nil
      ai-code-notifications-on-error t
      ai-code-notifications-on-session-end t)
```

### Add Custom Backend Pattern
```elisp
(setq ai-code-backends-infra-notification-patterns
      (cons '("MyBackend" . "^Ready:")
            ai-code-backends-infra-notification-patterns))
```

### Persistent Notifications
```elisp
(setq ai-code-notifications-timeout 0) ; Never timeout
```

## Troubleshooting

### Notifications Not Appearing

1. **Check if enabled**: `M-: ai-code-notifications-enabled`
2. **Check D-Bus**: `M-: (featurep 'dbusbind)`
3. **Check notifications package**: `M-: (require 'notifications nil t)`
4. **Check buffer focus**: Ensure AI buffer is not selected
5. **Check pattern**: Verify completion pattern matches actual output

### Notifications Appearing Too Frequently

- The pattern might be matching intermediate output
- Adjust the pattern to be more specific
- Check that notification state is being reset properly

### Notifications Not Appearing on Session End

- Process sentinel might not be installed
- Check if the process actually exited (vs. crashed)
- Enable debug logging in the process sentinel

## Future Enhancements

Possible future improvements:
- More granular pattern matching (per-command patterns)
- Notification action buttons (e.g., "Switch to Buffer")
- Sound notifications
- Custom notification icons per backend
- Notification history/log
- Integration with system notification settings
