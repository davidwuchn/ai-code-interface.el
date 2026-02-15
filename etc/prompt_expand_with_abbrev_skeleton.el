
;; expand prompt with abbrev + skeleton

(setq-default abbrev-mode t)

;;; expand in mini-buffer (C-c a <SPC>)
(setq enable-recursive-minibuffers t)

;;; skeletons

;;;; leetcode implement function
(define-skeleton leetcode/implement
  "Insert a note template (works in minibuffer too)."
  nil
  "Implement this function, given requirement, test cases and hints inside comments") ;; it just concat everything here include radar, you can add (read-string ...) inside

(define-abbrev-table 'global-abbrev-table
  '(("leetcode" "" (lambda () (interactive) (leetcode/implement)) :system t)))
