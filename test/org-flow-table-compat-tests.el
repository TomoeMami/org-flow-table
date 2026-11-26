;;; org-flow-table-compat-tests.el --- Optional compatibility tests -*- lexical-binding: t; -*-

;;; Commentary:

;; Load this file in a graphical Emacs with org-modern and its dependencies
;; on load-path, then run M-x ert RET org-flow-table-compat- RET.
;; These tests intentionally use real fontification, measurement and redisplay.

;;; Code:

(require 'ert)
(require 'org-flow-table)
(defvar org-modern-table)
(declare-function org-modern-mode "org-modern" (&optional arg))

(ert-deftest org-flow-table-compat-org-modern-enable-order ()
  (skip-unless (display-graphic-p))
  (skip-unless (require 'org-modern nil t))
  (dolist (via-hook '(nil t))
    (dolist (order '((org-modern-mode org-flow-table-mode)
                     (org-flow-table-mode org-modern-mode)))
      (with-temp-buffer
        (save-window-excursion
          (switch-to-buffer (current-buffer))
          (insert "* TODO Heading\n- [ ] Task\n\n| a |\n| b |\n")
          (goto-char (point-min))
          (let ((org-modern-table nil)
                (org-mode-hook (and via-hook order)))
            (unwind-protect
                (progn
                  (org-mode)
                  (unless via-hook
                    (dolist (mode order) (funcall mode 1)))
                  (dotimes (_ 2)
                    (font-lock-ensure)
                    (redisplay t)
                    (should (eq (get-text-property 3 'face) 'org-modern-todo))
                    (should (get-text-property 1 'display))
                    (should (get-text-property 18 'display))
                    ;; One overlay for each of the table's two rows.
                    (should (= (length org-flow-table--overlays) 2))
                    (org-flow-table-refresh)))
              (org-flow-table-mode -1)
              (org-modern-mode -1))))))))

(provide 'org-flow-table-compat-tests)
;;; org-flow-table-compat-tests.el ends here
