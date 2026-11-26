;;; org-flow-table-demo-tests.el --- Scenario checks -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; Load after org-flow-table-tests.el, then run all ERT tests.
;; Check content-row counts independently of normalized rules and metadata.
;;; Code:
(require 'ert)
(require 'cl-lib)
(require 'org-flow-table-tests)

(defconst org-flow-table-demo-tests--directory
  (expand-file-name "../demos" (file-name-directory
                                (or load-file-name buffer-file-name)))
  "Directory containing scenario fixtures.")

(defun org-flow-table-demo-tests--content-rows (beg)
  "Count non-rule, non-metadata rows in the Org source table at BEG."
  (save-excursion
    (goto-char beg)
    (cl-count-if
     (lambda (row)
       (and (listp row)
            (not (and (equal (car row) "/")
                      (seq-every-p (lambda (cell) (member cell '("" "<" ">" "<>")))
                                   (cdr row))))
            (not (and (seq-some (lambda (cell) (not (string-empty-p cell))) row)
                      (seq-every-p
                       (lambda (cell)
                         (or (string-empty-p cell)
                             (string-match-p "\\`<[lrc]?[0-9]*>\\'" cell)))
                       row)))))
     (org-table-to-lisp))))

(defun org-flow-table-demo-tests--check (file)
  "Check table overlays and buffer invariants for demo FILE."
  (with-temp-buffer
    (insert-file-contents file)
    (org-mode)
    (org-fold-show-all)
    (goto-char (point-min))
    (buffer-enable-undo)
    (set-buffer-modified-p nil)
    (save-window-excursion
      (switch-to-buffer (current-buffer))
      (let* ((before (buffer-substring-no-properties (point-min) (point-max)))
             (undo buffer-undo-list)
             ;; Independent discovery: Org's AST excludes example blocks.
             (tables (org-element-map (org-element-parse-buffer) 'table
                                      (lambda (table)
                                        (when (eq (org-element-property :type table) 'org)
                                          (org-element-property :post-affiliated table)))))
             (org-flow-table-reveal-on-point nil)
             problems)
        (unwind-protect
            (org-flow-table-tests--with-pixel-mocks
              (cl-letf (((symbol-function 'display-graphic-p)
                         (lambda (&rest _) t))
                        ((symbol-function 'org-flow-table--layout-width)
                         (lambda (_window) 120)))
                (org-flow-table-mode 1)
                (should (equal before (buffer-substring-no-properties
                                       (point-min) (point-max))))
                (should-not (buffer-modified-p))
                (should (eq undo buffer-undo-list))
                ;; Each table is displayed by one overlay per row.
                (let* ((firsts (seq-filter
                                (lambda (overlay)
                                  (eq overlay (car (org-flow-table--segments
                                                    overlay))))
                                org-flow-table--overlays))
                       (starts (sort (mapcar #'overlay-start firsts) #'<)))
                  (unless (equal starts tables)
                    (push (list :expected-table-starts tables :actual starts)
                          problems))
                  (dolist (overlay firsts)
                    (let* ((beg (overlay-start overlay))
                           (source-rows (org-flow-table-demo-tests--content-rows beg))
                           (lines (apply #'+
                                         (mapcar
                                          (lambda (segment)
                                            (length (split-string
                                                     (overlay-get segment 'before-string)
                                                     "\n")))
                                          (org-flow-table--segments overlay)))))
                      ;; A table without an outer frame draws at least one
                      ;; line per content row.
                      (unless (>= lines source-rows)
                        (push (list :line (line-number-at-pos beg)
                                    :source-rows source-rows :rendered-lines lines)
                              problems)))))
                (ert-info ((format "%s: %S" (file-name-nondirectory file)
                                   (reverse problems)))
                          (should-not problems))))
          (org-flow-table-mode -1))))))

(dolist (file (directory-files org-flow-table-demo-tests--directory
                               t "\\.org\\'"))
  (unless (equal (file-name-nondirectory file) "huge.org")
    (eval `(ert-deftest ,(intern (concat "org-flow-table-demo-"
                                         (file-name-base file))) ()
             (org-flow-table-demo-tests--check ,file)) t)))
(ert-deftest org-flow-table-demo-formula-recalculation ()
  (with-temp-buffer
    (insert-file-contents
     (expand-file-name "formulas.org" org-flow-table-demo-tests--directory))
    (org-mode)
    (goto-char (point-min))
    (re-search-forward "^#\\+TBLFM:")
    (org-ctrl-c-ctrl-c)
    (goto-char (point-min))
    (re-search-forward "^| Item")
    (let ((actual (org-table-to-lisp)))
      (re-search-forward "^#\\+NAME: invoice-recalculated")
      (re-search-forward "^| Item")
      (should (equal actual (org-table-to-lisp))))))
(ert-deftest org-flow-table-demo-column-groups-are-metadata ()
  (with-temp-buffer
    (insert-file-contents
     (expand-file-name "groups-and-rules.org" org-flow-table-demo-tests--directory))
    (org-mode)
    (let* ((bounds (nth 1 (org-flow-table--tables)))
           (table (org-flow-table--parse (car bounds) (cdr bounds))))
      ;; Org's / row declares column groups; it is not a header/data row.
      (should (= (plist-get table :header-rows) 1))
      (should-not (equal (caar (plist-get table :rows)) "/")))))

(provide 'org-flow-table-demo-tests)
;;; org-flow-table-demo-tests.el ends here
