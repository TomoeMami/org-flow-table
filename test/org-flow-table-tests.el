;;; org-flow-table-tests.el --- Tests for org-flow-table  -*- lexical-binding: t; -*-

;;; Commentary:

;; Run with:
;;   emacs -Q --batch --eval "(setq native-comp-enable-subr-trampolines nil)" \
;;     -L . -l org-flow-table.el \
;;     -l test/org-flow-table-tests.el -f ert-run-tests-batch-and-exit
;;
;; Tests replace built-in functions such as `window-text-pixel-size';
;; disabling trampolines keeps that from needing a native compiler.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'org-flow-table)

(defun org-flow-table-tests--pixels (string)
  "Return a deterministic pixel width for STRING: 10 per display column."
  (* 10 (string-width (substring-no-properties string))))

(defmacro org-flow-table-tests--with-pixel-mocks (&rest body)
  "Run BODY with deterministic pixel measurement."
  `(cl-letf (((symbol-function 'org-flow-table--measure-string)
              (lambda (string _window)
                (org-flow-table-tests--pixels string)))
             ((symbol-function 'org-flow-table--char-pixel-width)
              (lambda (_window) 10))
             ((symbol-function 'org-flow-table--pixel-budget)
              (lambda (width _window) (* 10 width))))
     ,@body))

(defmacro org-flow-table-tests--with-org (text &rest body)
  "Run BODY in an Org buffer containing TEXT."
  (declare (indent 1))
  `(with-temp-buffer
     (insert ,text)
     (org-mode)
     (goto-char (point-min))
     ,@body))

(defun org-flow-table-tests--lines (string)
  "Split rendered STRING into lines without properties.
Pixel spaces are dropped, so the lines hold only the visible text."
  (split-string (org-flow-table-tests--visible string) "\n"))

(defun org-flow-table-tests--visible (string)
  "Return STRING without properties and without pixel spaces."
  (string-replace "\u200B" "" (substring-no-properties string)))

;;;; Parsing

(ert-deftest org-flow-table-parse-header-and-groups ()
  (org-flow-table-tests--with-org "| A | B |\n|---+---|\n| 1 | 2 |\n|---+---|\n| 3 | 4 |\n"
    (let ((table (org-flow-table--parse (point-min) (point-max))))
      (should (equal (plist-get table :header-rows) 1))
      (should (equal (plist-get table :alignments) '(left left)))
      (should (equal (mapcar (lambda (row)
                               (if (eq row 'hline)
                                   row
                                 (mapcar #'substring-no-properties row)))
                             (plist-get table :rows))
                     '(("A" "B") hline ("1" "2") hline ("3" "4")))))))

(ert-deftest org-flow-table-parse-without-hline-has-no-header ()
  (org-flow-table-tests--with-org "| a | b |\n| c | d |\n"
    (let ((table (org-flow-table--parse (point-min) (point-max))))
      (should (equal (plist-get table :header-rows) 0))
      (should (equal (length (plist-get table :rows)) 2)))))

(ert-deftest org-flow-table-parse-drops-outer-and-duplicate-rules ()
  (org-flow-table-tests--with-org "|---|\n| a |\n|---|\n|---|\n| b |\n|---|\n"
    (let ((rows (plist-get (org-flow-table--parse (point-min) (point-max))
                           :rows)))
      (should (equal (length rows) 3))
      (should (eq (nth 1 rows) 'hline)))))

(ert-deftest org-flow-table-parse-alignment-cookies ()
  (org-flow-table-tests--with-org "| Item | Qty | Price |\n| <l> | <r> | <c10> |\n|---+---+---|\n| x | 1 | 2 |\n"
    (let ((table (org-flow-table--parse (point-min) (point-max))))
      (should (equal (plist-get table :alignments) '(left right center)))
      ;; The cookie row is not displayed.
      (should (equal (length (plist-get table :rows)) 3))
      (should (equal (plist-get table :header-rows) 1)))))

(ert-deftest org-flow-table-parse-pads-short-rows ()
  (org-flow-table-tests--with-org "| a | b | c |\n| d |\n"
    (let ((rows (plist-get (org-flow-table--parse (point-min) (point-max))
                           :rows)))
      (should (equal (length (nth 1 rows)) 3))
      (should (equal (substring-no-properties (nth 2 (nth 1 rows))) "")))))

(ert-deftest org-flow-table-parse-row-without-trailing-pipe ()
  (org-flow-table-tests--with-org "| a | b\n"
    (let ((rows (plist-get (org-flow-table--parse (point-min) (point-max))
                           :rows)))
      (should (equal (mapcar #'substring-no-properties (car rows))
                     '("a" "b"))))))

(ert-deftest org-flow-table-cells-keep-faces-and-drop-other-properties ()
  (org-flow-table-tests--with-org "| *bold* | plain |\n"
    (font-lock-ensure)
    (put-text-property 3 7 'fontified t)
    (put-text-property 3 7 'line-prefix "  ")
    (let* ((cell (car (car (plist-get (org-flow-table--parse (point-min)
                                                                (point-max))
                                      :rows))))
           (faces (get-text-property 1 'face cell)))
      (should (string-equal (substring-no-properties cell) "*bold*"))
      (should (or (eq faces 'bold) (memq 'bold (ensure-list faces))
                  (eq faces 'org-bold)))
      (should-not (get-text-property 1 'line-prefix cell))
      (should-not (get-text-property 1 'fontified cell)))))

(ert-deftest org-flow-table-parse-empty-table-returns-nil ()
  (org-flow-table-tests--with-org "|---|\n"
    (should-not (org-flow-table--parse (point-min) (point-max)))))

;;;; Layout

(ert-deftest org-flow-table-render-shape ()
  (org-flow-table-tests--with-pixel-mocks
   (let* ((table (list :rows '(("A" "B") hline ("1" "22") hline ("x" "y"))
                       :alignments '(left left)
                       :header-rows 1))
          (lines (org-flow-table-tests--lines
                  (org-flow-table--render table nil 80))))
     ;; A table is drawn in the shape Org gives it: no outer frame, one
     ;; rule between the rows that the source separates.
     (should (equal (length lines) 5))
     (should (equal (nth 0 lines) "| A | B |"))
     ;; Column widths are pixels, so a rule is as wide as its column.
     (should (string-prefix-p "|---+" (nth 1 lines)))
     (should (string-suffix-p "---|" (nth 1 lines)))
     (should-not (string-match-p "[^|+-]" (nth 1 lines)))
     (should (equal (nth 2 lines) "| 1 | 22 |"))
     (should (string-prefix-p "|---+" (nth 3 lines)))
     (should (string-suffix-p "---|" (nth 3 lines)))
     (should-not (string-match-p "[^|+-]" (nth 3 lines)))
     (should (equal (nth 4 lines) "| x | y |"))
     (dolist (line lines)
       (should (string-prefix-p "|" line))
       (should (string-suffix-p "|" line))
       (should-not (string-match-p "┌\|┬\|┐\|├\|┼\|┤\|└\|┴\|┘\|─\|│" line))))))

(ert-deftest org-flow-table-render-header-face ()
  (org-flow-table-tests--with-pixel-mocks
   (let* ((table (list :rows '(("Head") hline ("data"))
                       :alignments '(left) :header-rows 1))
          (rendered (org-flow-table--render table nil 80))
          (head (string-match "Head" rendered))
          (data (string-match "data" rendered)))
     (should (memq 'org-flow-table-header
                   (ensure-list (get-text-property head 'face rendered))))
     (should-not (memq 'org-flow-table-header
                       (ensure-list (get-text-property data 'face rendered)))))))

(ert-deftest org-flow-table-render-row-faces ()
  ;; Every drawn row, the rules and the header included, takes its place in
  ;; one set of alternating bands, so the stripes run across the whole table.
  (org-flow-table-tests--with-pixel-mocks
   (let* ((table (list :rows '(("Head") hline ("1") ("2") ("3"))
                       :alignments '(left) :header-rows 1))
          (rows (org-flow-table--render-rows table nil 80))
          (faces (mapcar (lambda (row)
                           (get-text-property 0 'face (cdr row)))
                         rows)))
     (should (equal faces '((org-flow-table-header org-flow-table-row)
                            org-flow-table-zebra
                            org-flow-table-row
                            org-flow-table-zebra
                            org-flow-table-row)))))
  ;; A table with several header rows stripes all of them, and the rule below
  ;; them continues the same run of bands.
  (org-flow-table-tests--with-pixel-mocks
   (let* ((table (list :rows '(("H1") ("H2") hline ("1") ("2"))
                       :alignments '(left) :header-rows 2))
          (rows (org-flow-table--render-rows table nil 80))
          (faces (mapcar (lambda (row)
                           (get-text-property 0 'face (cdr row)))
                         rows)))
     (should (equal faces '((org-flow-table-header org-flow-table-row)
                            (org-flow-table-header org-flow-table-zebra)
                            org-flow-table-row
                            org-flow-table-zebra
                            org-flow-table-row)))))
  ;; Without zebra striping the data rows take the plain row face, while a
  ;; header row keeps its bold face and the rules keep the buffer background.
  (org-flow-table-tests--with-pixel-mocks
   (let* ((org-flow-table-zebra-stripe nil)
          (table (list :rows '(("Head") hline ("1") ("2")) :alignments '(left)
                       :header-rows 1))
          (rows (org-flow-table--render-rows table nil 80)))
     (should (equal (mapcar (lambda (row) (get-text-property 0 'face (cdr row)))
                            rows)
                    '(org-flow-table-header nil org-flow-table-row
                      org-flow-table-row))))))

(ert-deftest org-flow-table-render-wraps-long-cells ()
  (org-flow-table-tests--with-pixel-mocks
   (let* ((long (mapconcat #'identity (make-list 12 "word") " "))
          (table (list :rows `(("k" ,long)) :alignments '(left left)
                       :header-rows 0))
          (lines (org-flow-table-tests--lines
                  (org-flow-table--render table nil 30))))
     ;; A 59-column cell in a 30-column window needs several lines.
     (should (>= (length lines) 3))
     (dolist (line lines)
       (should (<= (string-width line) 30))))))

(ert-deftest org-flow-table-longest-token-pixels ()
  (org-flow-table-tests--with-pixel-mocks
   (should (= (org-flow-table--longest-token-pixels "ab cdef g" nil) 40))
   (should (= (org-flow-table--longest-token-pixels "用户面只留" nil) 20))
   (should (= (org-flow-table--longest-token-pixels "" nil) 0))))

(ert-deftest org-flow-table-short-columns-keep-natural-width ()
  (org-flow-table-tests--with-pixel-mocks
   (let* ((giant (mapconcat #'identity (make-list 100 "lorem") " "))
          (rows `(("id" "status" ,giant)))
          (widths (org-flow-table--widths rows 3 1000 10 nil)))
     ;; "id" and "status" fit their natural width exactly, since their
     ;; growth above the minimum is well within the flexible space; the
     ;; giant column takes what is left over.
     (should (equal widths '(40 80 840))))))

(defconst org-flow-table-tests--issue-2-rows
  '(("sequence" "100 m" "200 m" "400 m" "G path" "spins" "portals")
    hline
    ("kartom-04" "0.6296 %" "0.3853 %" "0.4070 %" "773.8 m" "6828" "187")
    ("kartom-05" "0.8801 %" "0.5603 %" "0.2783 %" "695.1 m" "5834" "166")
    ("kartom-02" "0.6750 %" "0.5293 %"
     "this is some longer text that seems to cause trouble" "290.5 m"
     "3007" "69"))
  "Issue #2 table: short numeric cells beside a long text column.")

(ert-deftest org-flow-table-issue-2-short-numeric-columns-stay-whole ()
  (org-flow-table-tests--with-pixel-mocks
   (dolist (case '((800 . (110 100 100 160 90 70 90))
                   (1000 . (110 100 100 360 90 70 90))
                   (1100 . (110 100 100 460 90 70 90))))
     (should (equal (org-flow-table--widths
                     org-flow-table-tests--issue-2-rows 7 (car case) 10 nil)
                    (cdr case))))
   ;; Only 30 px exist above the minimums, too little to settle the
   ;; short columns at their natural width.
   (should (equal (org-flow-table--widths
                   org-flow-table-tests--issue-2-rows 7 700 10 nil)
                  '(110 82 82 113 73 70 90)))))

(ert-deftest org-flow-table-tight-budget-settles-cheapest-column-only ()
  (org-flow-table-tests--with-pixel-mocks
   (let* ((rows `(("ab cd" "abcd efgh" "abcd efgh"
                   ,(mapconcat #'identity (make-list 10 "word") " "))))
          (widths (org-flow-table--widths rows 4 410 10 nil)))
     (should (equal widths '(70 85 85 120))))))

(ert-deftest org-flow-table-two-long-columns-share-evenly ()
  (org-flow-table-tests--with-pixel-mocks
   (let* ((a20 (mapconcat #'identity (make-list 20 "alpha") " "))
          (rows `(("k" ,a20 ,a20)))
          (widths (org-flow-table--widths rows 3 500 10 nil)))
     (should (equal widths '(30 215 215))))))

(ert-deftest org-flow-table-rounding-spreads-the-remainder ()
  (org-flow-table-tests--with-pixel-mocks
   (let* ((cell (mapconcat #'identity (make-list 8 "ab") " "))
          (rows (list (list cell cell cell))))
     (let ((widths (org-flow-table--widths rows 3 270 10 nil)))
       (should (equal widths '(76 77 77)))
       (should (= (apply #'+ widths) 230)))
     (let ((widths (org-flow-table--widths rows 3 260 10 nil)))
       (should (equal widths '(73 73 74)))
       (should (= (apply #'+ widths) 220))))))

(ert-deftest org-flow-table-capped-token-does-not-overfeed-short-columns ()
  (org-flow-table-tests--with-pixel-mocks
   (let* ((rows '(("supertag-node-delete-everything" "ab cd" "ef gh")))
          (widths (org-flow-table--widths rows 3 400 10 nil)))
     ;; The old proportional split over-fed short columns beyond their
     ;; natural width: (201 79 80).  The capped weight must not do that.
     (should (equal widths '(220 70 70))))))

(ert-deftest org-flow-table-shares-recompute-after-every-grant ()
  (org-flow-table-tests--with-pixel-mocks
   (let ((widths (org-flow-table--widths
                  '(("ab cd ef g" "abcdefghijklmnop xyz")) 2 350 10 nil)))
     ;; Granting both columns against shares computed once per pass
     ;; would return (120 220) = 340, overflowing the 320 available.
     (should (equal widths '(100 220)))
     (should (= (apply #'+ widths) 320)))))

(ert-deftest org-flow-table-issue-2-render-keeps-numeric-cells-whole ()
  (org-flow-table-tests--with-pixel-mocks
   (let* ((table (list :rows org-flow-table-tests--issue-2-rows
                       :alignments (make-list 7 'left)
                       :header-rows 1))
          (lines (org-flow-table-tests--lines
                  (org-flow-table--render table nil 100)))
          (plain (mapconcat #'identity lines "\n")))
     (should (string-match-p (regexp-quote "0.6296 %") plain))
     (should (string-match-p (regexp-quote "773.8 m") plain))
     ;; One line per row, plus the rules between them; wrapped rows add more.
     (should (>= (length lines) 6)))))

(ert-deftest org-flow-table-minimum-keeps-unbreakable-token ()
  (org-flow-table-tests--with-pixel-mocks
   (let* ((rows '(("supertag-node-delete" "x")))
          (widths (org-flow-table--widths rows 2 400 10 nil)))
     ;; 20 chars = 200px + 20 padding; the token is never split.
     (should (= (nth 0 widths) 220)))))

(ert-deftest org-flow-table-right-alignment-pads-left ()
  (org-flow-table-tests--with-pixel-mocks
   (let* ((padded (org-flow-table--pad "7" 50 nil 'right)))
     (should (string-prefix-p "​" padded))
     (should (string-suffix-p "7" padded)))))

(ert-deftest org-flow-table-grapheme-clusters ()
  (should (equal (org-flow-table--grapheme-ends "🇯🇵a" 0) '(2 3)))
  (should (equal (org-flow-table--grapheme-ends "👨‍👩‍👧x" 0) '(5 6))))

;;;; Overlays

(ert-deftest org-flow-table-rest-entry-direction ()
  ;; Point lands on a row whatever direction it came from; the row keeps its
  ;; source while the other rows of the table stay drawn.
  (dolist (case '((previous-line below last)
                  (next-line below last) ; Negative prefix argument.
                  (next-line above first)
                  (isearch-backward below first)))
    (org-flow-table-tests--with-org "Before\n| a |\n| b |\n| c |\nAfter\n"
      (save-window-excursion
        (switch-to-buffer (current-buffer))
        (org-flow-table-tests--with-pixel-mocks
         (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t)))
           (org-flow-table-mode 1)
           (unwind-protect
               (let* ((table (car (org-flow-table--tables)))
                      (this-command (car case))
                      (real-this-command this-command))
                 (goto-char (if (eq (nth 1 case) 'below) (cdr table) (point-min)))
                 (run-hooks 'pre-command-hook)
                 (goto-char (car table))
                 (run-hooks 'post-command-hook)
                 (should (= (line-number-at-pos)
                            (if (eq (nth 2 case) 'last) 4 2)))
                 ;; The row point rests on is source, the others stay drawn.
                 (should-not (org-flow-table--overlay-at (point)))
                 (should (= (length org-flow-table--overlays) 2)))
             (org-flow-table-mode -1))))))))

(ert-deftest org-flow-table-rest-skipped-table ()
  ;; A display-based Down can cross several rows in one step; point backs up
  ;; to the row next to the one it left.
  (dolist (case '((next-line below first) (previous-line above last)))
    (org-flow-table-tests--with-org "Before\n| a |\n| b |\nAfter\n"
      (save-window-excursion
        (switch-to-buffer (current-buffer))
        (org-flow-table-mode 1)
        (unwind-protect
            (let* ((table (car (org-flow-table--tables)))
                   (this-command (car case))
                   (real-this-command this-command)
                   (current-prefix-arg nil))
              (unless (org-flow-table--overlay-at (car table))
                (org-flow-table--display-table
                 (car table) (cdr table) (selected-window) 80))
              (goto-char (if (eq (nth 1 case) 'below) (point-min) (cdr table)))
              (run-hooks 'pre-command-hook)
              (goto-char (if (eq (nth 1 case) 'below) (cdr table) (point-min)))
              (run-hooks 'post-command-hook)
              (ert-info ((format "%S" case))
                (should (= (point) (if (eq (nth 2 case) 'first)
                                       (car table)
                                     (save-excursion
                                       (goto-char (car table))
                                       (line-beginning-position 2)))))
                (should-not (org-flow-table--overlay-at (point)))))
          (org-flow-table-mode -1))))))

(ert-deftest org-flow-table-rest-vertical-interactive ()
  ;; Redisplay is required: batch line motion ignores the row geometry.
  (skip-unless (not noninteractive))
  (dolist (visual '(nil t))
    (dolist (command '(next-line previous-line))
      (org-flow-table-tests--with-org "Before\n| a |\n| b |\n| c |\nAfter\n"
        (save-window-excursion
          (switch-to-buffer (current-buffer))
          (when visual (visual-line-mode 1))
          (goto-char (point-max))
          (org-flow-table-mode 1)
          (unwind-protect
              (let ((table (car (org-flow-table--tables))))
                (goto-char (if (eq command 'next-line) (point-min) (cdr table)))
                (redisplay t)
                (let ((this-command command)
                      (real-this-command command))
                  (run-hooks 'pre-command-hook)
                  (call-interactively command)
                  (run-hooks 'post-command-hook))
                (should (= (line-number-at-pos)
                           (if (eq command 'next-line) 2 4)))
                (should-not (org-flow-table--overlay-at (point))))
            (org-flow-table-mode -1)))))))

(ert-deftest org-flow-table-rest-steps-over-rows ()
  ;; (COMMAND FROM LANDING EXPECTED): where a command left point, and where
  ;; point settles.  Display-based vertical motion can skip rows.
  (dolist (case '((next-line before end start)
                  (next-line before second start)
                  (next-line start end second)
                  (previous-line end start second)
                  (previous-line second start start)
                  (previous-line end second second)
                  (next-line before inside start)   ; Logical line motion.
                  ;; Point may rest anywhere inside a row: that row is source.
                  (goto-char end inside inside)))
    (org-flow-table-tests--with-org "Before\n| a |\n| b |\nAfter\n"
      (save-window-excursion
        (switch-to-buffer (current-buffer))
        (org-flow-table-tests--with-pixel-mocks
         (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t)))
           (org-flow-table-mode 1)
           (unwind-protect
               (let* ((table (car (org-flow-table--tables)))
                      (second (+ (car table) 6))
                      (places `((before . ,(point-min)) (start . ,(car table))
                                (inside . ,(+ (car table) 3)) (second . ,second)
                                (end . ,(cdr table))))
                      (this-command (nth 0 case))
                      (real-this-command this-command))
                 (goto-char (alist-get (nth 1 case) places))
                 (run-hooks 'pre-command-hook)
                 (goto-char (alist-get (nth 2 case) places))
                 (run-hooks 'post-command-hook)
                 (ert-info ((format "%S" case))
                   (should (= (point) (alist-get (nth 3 case) places)))
                   ;; The row point rests on is source, not a drawn row.
                   (should-not (and (org-flow-table--overlay-at (point))
                                    (overlay-get (org-flow-table--overlay-at (point))
                                                 'org-flow-table-row)))))
             (org-flow-table-mode -1))))))))

(ert-deftest org-flow-table-terminal-rendering-follows-option ()
  (org-flow-table-tests--with-org "Before\n| a | b |\n"
    (save-window-excursion
      (switch-to-buffer (current-buffer))
      (org-flow-table-tests--with-pixel-mocks
        (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) nil)))
          (goto-char (point-min))
          (dolist (enabled '(nil t))
            (let ((org-flow-table-enable-in-terminal enabled))
              (org-flow-table-refresh)
              (should (eq enabled (and org-flow-table--overlays t))))))))))

(ert-deftest org-flow-table-edit-row-in-place ()
  (org-flow-table-tests--with-org "Before\n| a | b |\n| c | d |\nAfter\n"
    (save-window-excursion
      (switch-to-buffer (current-buffer))
      (org-flow-table-tests--with-pixel-mocks
       (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t)))
         (let ((org-flow-table-relayout-delay 3600)
               (start (caar (org-flow-table--tables))))
           (unwind-protect
               (progn
                 (org-flow-table-mode 1)
                 (goto-char start)
                 (org-flow-table--post-command)
                 (should-not (org-flow-table--overlay-at start))
                 (should (org-flow-table--overlay-at
                          (save-excursion
                            (goto-char start)
                            (line-beginning-position 2))))
                 (goto-char start)
                 (forward-char 2)
                 (insert "X")
                 (should (string-match-p "| Xa | b |" (buffer-string)))
                 (org-flow-table--post-command)
                 ;; The edit drops the rows; the next command draws them
                 ;; again, leaving the row point rests on as source.
                 (should-not (org-flow-table--overlay-at start))
                 (forward-line 1)
                 (org-flow-table--post-command)
                 (should (org-flow-table--overlay-at start))
                 (should-not (org-flow-table--overlay-at (point)))
                 (goto-char (point-max))
                 (org-flow-table--post-command)
                 (should (= (length org-flow-table--overlays) 2))
                 (should (org-flow-table--overlay-at start)))
             (org-flow-table-mode -1))))))))

(ert-deftest org-flow-table-editing-waits-to-lay-the-table-out ()
  ;; A table is not laid out while point stays on the row being edited:
  ;; redrawing it there makes the rows around the cursor jump, and a run of
  ;; edits then costs one layout when the row is left instead of one per
  ;; character.  Point leaving the row, for another row of the table or for
  ;; text outside it, lays the table out once.
  (org-flow-table-tests--with-org "Before\n| a | b |\n| c | d |\n| e | f |\nAfter\n"
    (save-window-excursion
      (switch-to-buffer (current-buffer))
      (org-flow-table-tests--with-pixel-mocks
       (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t)))
         (let ((org-flow-table-relayout-delay 3600)
               (layouts 0))
           (unwind-protect
               (progn
                 (org-flow-table-mode 1)
                 (cl-letf (((symbol-function 'org-flow-table--lay-out-edited)
                            (lambda (beg)
                              (setq layouts (1+ layouts))
                              (org-flow-table--draw-table beg))))
                   ;; Type into one row: no layout while point stays there.
                   (goto-char (point-min))
                   (forward-line 2)
                   (org-flow-table--pre-command)
                   (org-flow-table--post-command)
                   (dotimes (_ 3)
                     (org-flow-table--pre-command)
                     (forward-char 2)
                     (insert "X")
                     (org-flow-table--post-command))
                   (should (= layouts 0))
                   (should (memq (caar (org-flow-table--tables))
                                 org-flow-table--dirty))
                   ;; Leaving that row lays the table out exactly once.
                   (org-flow-table--pre-command)
                   (forward-line 1)
                   (org-flow-table--post-command)
                   (should (= layouts 1))
                   (should-not org-flow-table--dirty)
                   ;; Same for leaving the table altogether after another
                   ;; edit: the layout waits for point to go, then runs once.
                   (org-flow-table--pre-command)
                   (forward-char 2)
                   (insert "Q")
                   (org-flow-table--post-command)
                   (should (= layouts 1))
                   (org-flow-table--pre-command)
                   (goto-char (point-min))
                   (org-flow-table--post-command)
                   (should (= layouts 2))
                   (should-not org-flow-table--dirty)))
             (org-flow-table-mode -1))))))))

(ert-deftest org-flow-table-editing-does-not-schedule-a-relayout ()
  ;; Only a change of the layout inputs schedules an idle relayout.  An edit
  ;; waits for point to leave its row, so no timer redraws the table while
  ;; the person is still typing.
  (org-flow-table-tests--with-org "Before\n| a | b |\n| c | d |\nAfter\n"
    (save-window-excursion
      (switch-to-buffer (current-buffer))
      (org-flow-table-tests--with-pixel-mocks
       (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t)))
         (let ((org-flow-table-relayout-delay 0.15))
           (unwind-protect
               (progn
                 (org-flow-table-mode 1)
                 (search-forward "| c | d |")
                 (goto-char (match-beginning 0))
                 (org-flow-table--pre-command)
                 (org-flow-table--post-command)
                 (org-flow-table--pre-command)
                 (insert "X")
                 (org-flow-table--post-command)
                 (should-not org-flow-table--timer))
             (org-flow-table-mode -1))))))))

(ert-deftest org-flow-table-deleting-on-the-source-row-keeps-its-source ()
  ;; Deleting a character on the row point rests on can turn that line into
  ;; something other than a table row, for instance when the leading pipe
  ;; goes.  The row then belongs to no table as far as the buffer text and
  ;; the overlays are concerned, but the table it came from must still be
  ;; told about the edit: otherwise its stale layout draws the row again from
  ;; spans that now cover the rows below, and the rows flash over the source.
  (dolist (case '((delete-leading-pipe . beginning-of-line)
                  (delete-letter-in-cell . search-forward)))
    (org-flow-table-tests--with-org
        "Prose\n| Name | Qty |\n|------+-----|\n| apple | 3 |\n| pear | 12 |\n| fig | 777 |\n"
      (save-window-excursion
        (switch-to-buffer (current-buffer))
        (org-flow-table-tests--with-pixel-mocks
         (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t)))
           (let ((org-flow-table-relayout-delay 3600))
             (unwind-protect
                 (progn
                   (org-flow-table-mode 1)
                   ;; Point rests on the "apple" row, which stays as source.
                   (search-forward "apple")
                   (beginning-of-line)
                   (org-flow-table--post-command)
                   (should-not (org-flow-table--overlay-at (point)))
                   (pcase (car case)
                     ('delete-leading-pipe (beginning-of-line))
                     ('delete-letter-in-cell (search-forward "ppl")))
                   (org-flow-table--pre-command)
                   (delete-char (if (eq (car case) 'delete-letter-in-cell) 1 1))
                   ;; Nothing may draw over the line point rests on: its
                   ;; source is what the user is editing.
                   (should-not
                    (and (org-flow-table--overlay-at (point))
                         (overlay-get (org-flow-table--overlay-at (point))
                                      'org-flow-table-row)))
                   (org-flow-table--post-command)
                   (should-not
                    (and (org-flow-table--overlay-at (point))
                         (overlay-get (org-flow-table--overlay-at (point))
                                      'org-flow-table-row))))
               (org-flow-table-mode -1)))))))))

(ert-deftest org-flow-table-delete-at-row-start-marks-the-table-dirty ()
  ;; A deletion reports BEG equal to END, so an overlay that starts exactly
  ;; at the edit still covers it.  Missing that leaves the table's layout
  ;; cached against source that has moved.
  (org-flow-table-tests--with-org "| a | b |\n| c | d |\n"
    (save-window-excursion
      (switch-to-buffer (current-buffer))
      (org-flow-table-tests--with-pixel-mocks
       (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t)))
         (let ((org-flow-table-relayout-delay 3600)
               (start (caar (org-flow-table--tables))))
           (unwind-protect
               (progn
                 (org-flow-table-mode 1)
                 ;; Point is on the first row, so that row has no overlay and
                 ;; the second row's overlay starts exactly where the edit
                 ;; lands once the first row's newline goes.
                 (goto-char start)
                 (org-flow-table--post-command)
                 (end-of-line)
                 (org-flow-table--pre-command)
                 (delete-char 1)
                 (should (memq start org-flow-table--dirty)))
             (org-flow-table-mode -1))))))))

(ert-deftest org-flow-table-toggle-reveals-and-draws-a-table ()
  (org-flow-table-tests--with-org "Before\n| a | b |\n| c | d |\nAfter\n"
    (save-window-excursion
      (switch-to-buffer (current-buffer))
      (org-flow-table-tests--with-pixel-mocks
       (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t)))
         (let ((org-flow-table-relayout-delay 3600)
               (start (caar (org-flow-table--tables))))
           (unwind-protect
               (progn
                 (org-flow-table-mode 1)
                 (goto-char start)
                 (org-flow-table--post-command)
                 (org-flow-table-toggle)
                 (should (org-flow-table--revealed-p start))
                 (should-not (org-flow-table--table-overlays start))
                 (org-flow-table-refresh)
                 (should-not (org-flow-table--table-overlays start))
                 (org-flow-table-toggle)
                 (should-not (org-flow-table--revealed-p start))
                 (should (= (length (org-flow-table--table-overlays start)) 1))
                 (org-flow-table-toggle)
                 (should (org-flow-table--revealed-p start))
                 (goto-char (point-max))
                 (org-flow-table--post-command)
                 (should-not (org-flow-table--revealed-p start))
                 (should (= (length (org-flow-table--table-overlays start)) 2)))
             (org-flow-table-mode -1))))))))

(ert-deftest org-flow-table-toggle-outside-a-table-signals ()
  (org-flow-table-tests--with-org "Before\n| a | b |\nAfter\n"
    (should-error (progn (goto-char (point-min))
                         (org-flow-table-toggle))
                  :type 'user-error)))

(ert-deftest org-flow-table-tables-skips-table-el ()
  (org-flow-table-tests--with-org "text\n| a |\n| b |\n\n+---+\n| c |\n+---+\n\n| d |\n"
    (let ((tables (org-flow-table--tables)))
      (should (equal (length tables) 2)))))

(ert-deftest org-flow-table-mode-requires-org ()
  (with-temp-buffer
    (should-error (org-flow-table-mode 1) :type 'user-error)
    (should-not org-flow-table-mode)))

(ert-deftest org-flow-table-mode-without-window-keeps-buffer-clean ()
  (org-flow-table-tests--with-org "| a |\n| b |\n"
    (set-buffer-modified-p nil)
    (org-flow-table-mode 1)
    (should-not (buffer-modified-p))
    (should (markerp org-flow-table--previous-point))
    (should (memq #'org-flow-table--pre-command pre-command-hook))
    (org-flow-table-mode -1)
    (should-not org-flow-table--previous-point)
    (should-not (memq #'org-flow-table--pre-command pre-command-hook))
    (should-not org-flow-table--overlays)))

(ert-deftest org-flow-table-overlay-preserves-pixel-spaces-and-newlines ()
  (dolist (source '("| a | longer |\n| b | x |\n"
                    "| a | longer |\n| b | x |"))
    (org-flow-table-tests--with-org source
      (org-flow-table-tests--with-pixel-mocks
       (font-lock-ensure)
       (set-buffer-modified-p nil)
       (let* ((before (buffer-string))
              (undo buffer-undo-list)
              (overlay (org-flow-table--display-table
                        (point-min) (point-max) (selected-window) 80))
              (rendered (overlay-get overlay 'before-string)))
         (should (stringp rendered))
         ;; Pixel padding survives in the overlay strings.
         (let ((all (mapconcat (lambda (segment)
                                 (overlay-get segment 'before-string))
                               (org-flow-table--segments overlay)
                               "\n")))
           (should (text-property-any 0 (length all)
                                      'org-flow-table-spacing t all)))
         (should-not (string-suffix-p "\n" rendered))
         ;; One overlay for each row of the table.
         (should (= (length org-flow-table--overlays) 2))
         (should (equal (org-flow-table--segments overlay)
                        (sort (copy-sequence org-flow-table--overlays)
                              (lambda (a b) (< (overlay-start a) (overlay-start b))))))
         (should (eq overlay (org-flow-table--overlay-at (point-min))))
         (let ((last (org-flow-table--overlay-at (1- (point-max)))))
           (should-not (eq overlay last))
           (should (= (overlay-start last) (overlay-end overlay)))
           (should (= (overlay-end last) (point-max)))
           (should (equal (overlay-get last 'display)
                          (if (string-suffix-p "\n" source) "\n" " "))))
         (should-not (org-flow-table--overlay-at (point-max)))
         (org-flow-table--remove-overlay overlay)
         (should-not (overlay-buffer overlay))
         (should-not org-flow-table--overlays)
         (should (equal-including-properties before (buffer-string)))
         (should (eq undo buffer-undo-list))
         (should-not (buffer-modified-p)))))))

(ert-deftest org-flow-table-overlay-lifecycle ()
  (org-flow-table-tests--with-org "Before\n| a | longer |\n\nAfter\n| b | c |\n"
    (save-window-excursion
      (switch-to-buffer (current-buffer))
      (org-flow-table-tests--with-pixel-mocks
       (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t)))
         (font-lock-ensure)
         (buffer-enable-undo)
         (set-buffer-modified-p nil)
         (let ((before (buffer-string))
               (undo buffer-undo-list)
               (org-flow-table-relayout-delay 0))
           (unwind-protect
               (progn
                 (org-flow-table-mode 1)
                 ;; Both tables are drawn, one overlay per row.
                 (should (= (length org-flow-table--overlays) 2))
                 (let ((old (copy-sequence org-flow-table--overlays)))
                   (org-flow-table-refresh)
                   (should (seq-every-p
                            (lambda (overlay) (not (overlay-buffer overlay)))
                            old)))
                 ;; Point on a row leaves that row as source.
                 (goto-char (caar (org-flow-table--tables)))
                 (org-flow-table--post-command)
                 (should-not (org-flow-table--overlay-at (point)))
                 (should (= (length org-flow-table--overlays) 1))
                 (goto-char (point-min))
                 (org-flow-table--post-command)
                 (should (= (length org-flow-table--overlays) 2))
                 ;; Toggle reveals one table's source and draws it again.
                 (goto-char (caar (org-flow-table--tables)))
                 (let ((beg (caar (org-flow-table--tables))))
                   (org-flow-table-toggle)
                   (should (org-flow-table--revealed-p beg))
                   (should-not (org-flow-table--table-overlays beg))
                   (org-flow-table-toggle)
                   (should-not (org-flow-table--revealed-p beg))
                   ;; The table has one row and point rests on it, so the
                   ;; table is source again: drawing it leaves no overlay.
                   (should-not (org-flow-table--table-overlays beg)))
                 ;; Force the same callback that a changed window width uses.
                 (let ((old (copy-sequence org-flow-table--overlays)))
                   (setq org-flow-table--width 1)
                   (org-flow-table--window-changed)
                   (should (= (length org-flow-table--overlays) 1))
                   (should (seq-every-p
                            (lambda (overlay) (not (overlay-buffer overlay)))
                            old)))
                 (let ((old (copy-sequence org-flow-table--overlays)))
                   (org-flow-table-mode -1)
                   (should-not org-flow-table--overlays)
                   (should (seq-every-p
                            (lambda (overlay) (not (overlay-buffer overlay)))
                            old)))
                 (should (equal-including-properties before (buffer-string)))
                 (should (eq undo buffer-undo-list))
                 (should-not (buffer-modified-p)))
             (org-flow-table-mode -1))))))))

(ert-deftest org-flow-table-edit-keeps-the-other-rows-drawn ()
  ;; Editing a row keeps the rest of the table rendered: the overlays stay
  ;; where they are and follow the text as it changes.
  (dolist (offset '(0 3 15 17))
    (org-flow-table-tests--with-org "| a | longer |\n| b | x |\n"
      (org-flow-table-tests--with-pixel-mocks
       (let* ((overlay (org-flow-table--display-table
                        (point-min) (point-max) (selected-window) 80))
              (segments (org-flow-table--segments overlay)))
         (should (= (length segments) 2))
         (goto-char (+ (point-min) offset))
         (insert "x")
         ;; The rows are still drawn, and the edit is planned for a relayout.
         (should (seq-every-p #'overlay-buffer segments))
         (should org-flow-table--dirty)
         (should-not org-flow-table--render-cache)
         (should (org-flow-table--table-overlays (point-min))))))))

(ert-deftest org-flow-table-redraw-does-not-stack-overlays ()
  ;; Overlays are found from the list of them when a table is dropped, not
  ;; from the per-row index.  A lost or replaced index entry used to leave
  ;; the old overlay on screen, drawing over the redrawn table.
  (org-flow-table-tests--with-org "Before\n| a | 1 |\n| b | 2 |\n| c | 3 |\n"
    (save-window-excursion
      (switch-to-buffer (current-buffer))
      (org-flow-table-tests--with-pixel-mocks
       (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t)))
         (let ((org-flow-table-relayout-delay 3600))
           (unwind-protect
               (progn
                 (org-flow-table-mode 1)
                 ;; Point rests outside the table, so every row is drawn and
                 ;; a redraw must replace them all.
                 (let* ((table (car (org-flow-table--tables)))
                        (beg (car table))
                        (end (cdr table))
                        (drawn (length org-flow-table--overlays)))
                   (should (> drawn 0))
                   ;; Lose the index, as an overwritten entry does.
                   (setq org-flow-table--row-index
                         (make-hash-table :test 'equal))
                   (org-flow-table--display-table
                    beg end (selected-window) 80)
                   ;; Redrawing replaces the drawing instead of adding to it.
                   (should (= (length org-flow-table--overlays) drawn))))
             (org-flow-table-mode -1))))))))

(ert-deftest org-flow-table-row-drawn-once ()
  ;; Drawing a row twice must not leave the first overlay behind, where
  ;; nothing could reach it to delete it again.
  (org-flow-table-tests--with-org "Before\n| a | 1 |\n| b | 2 |\n"
    (save-window-excursion
      (switch-to-buffer (current-buffer))
      (org-flow-table-tests--with-pixel-mocks
       (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t)))
         (let ((org-flow-table-relayout-delay 3600))
           (unwind-protect
               (progn
                 (org-flow-table-mode 1)
                 ;; Point stays on "Before", outside the table, so every
                 ;; row of the table is drawn.
                 (let* ((beg (car (car (org-flow-table--tables))))
                        (cached (gethash beg org-flow-table--render-cache))
                        (widget (nth 1 cached))
                        (spans (nth 2 cached))
                        (span (car spans))
                        (drawn (length org-flow-table--overlays)))
                   ;; The first row is drawn already, so drawing it again
                   ;; takes the same index entry.
                   (should (org-flow-table--row-overlay
                            (cons beg (car span))))
                   (org-flow-table--make-row-overlay beg span widget)
                   (should (= (length org-flow-table--overlays) drawn))))
             (org-flow-table-mode -1))))))))

(ert-deftest org-flow-table-spans-start-at-line-beginnings ()
  ;; A rendering can lose the source line it was laid out for, leaving a
  ;; repeated or out-of-order offset.  Spans are located from the table start
  ;; rather than by stepping on from the previous row, so none of them can
  ;; begin inside a line: a span that did would have `display' replace only
  ;; part of its source line, and the rest of the line would show through
  ;; beside the drawing.
  (org-flow-table-tests--with-org "| a | 1 |\n| b | 2 |\n| c | 3 |\n| d | 4 |\n"
    (let ((beg (point-min))
          (end (point-max)))
      (dolist (rows (list (list (cons 0 "r0") (cons 1 "r1") (cons 2 "r2"))
                          ;; Every offset collapsed to the default value.
                          (list (cons 0 "r0") (cons 0 "r1") (cons 0 "r2"))
                          ;; Out of order.
                          (list (cons 2 "r2") (cons 0 "r0") (cons 3 "r3"))
                          ;; Repeated, and nil for a missing offset.
                          (list (cons 0 "r0") (cons 1 "r1") (cons 1 "r1b"))
                          (list (cons nil "r0") (cons 1 "r1"))))
        (dolist (span (org-flow-table--drop-empty-spans
                       (org-flow-table--row-spans beg end rows)))
          (should (< (nth 2 span) (nth 3 span)))
          (should (or (= (nth 2 span) beg)
                      (eq (char-before (nth 2 span)) ?\n))))))))

(ert-deftest org-flow-table-spans-cover-the-whole-table ()
  ;; Between them, the spans replace every line of the table exactly once,
  ;; and the last one reaches the end.
  (org-flow-table-tests--with-org "| a | 1 |\n| b | 2 |\n| c | 3 |\n"
    (let* ((beg (point-min))
           (end (point-max))
           (rows (list (cons 0 "r0") (cons 1 "r1") (cons 2 "r2")))
           (spans (org-flow-table--drop-empty-spans
                   (org-flow-table--row-spans beg end rows))))
      (should (= (nth 2 (car spans)) beg))
      (should (= (nth 3 (car (last spans))) end))
      (cl-loop for (a b) on spans
               while b
               do (should (= (nth 3 a) (nth 2 b)))))))

(ert-deftest org-flow-table-rows-cover-their-source-lines ()
  ;; Source lines a row does not draw itself, such as alignment cookies,
  ;; join the row above them, so no source line stays uncovered.
  (org-flow-table-tests--with-org
      (concat "|---+---|\n| A | B |\n| <l> | <r> |\n|---+---|\n| 1 | 2 |\n"
              "|---+---|\n|---+---|\n| 3 | 4 |\n|---+---|\nAfter\n")
    (org-flow-table-tests--with-pixel-mocks
     (let* ((table (car (org-flow-table--tables)))
            (overlay (org-flow-table--display-table
                      (car table) (cdr table) (selected-window) 80))
            (segments (org-flow-table--segments overlay)))
       (should (eq overlay (car segments)))
       (should (equal (mapcar (lambda (segment)
                                (list (line-number-at-pos (overlay-start segment))
                                      (line-number-at-pos (overlay-end segment))
                                      (length (org-flow-table-tests--lines
                                               (overlay-get segment 'before-string)))))
                              segments)
                      '((1 4 1)
                        (4 5 1)
                        (5 6 1)
                        (6 8 1)
                        (8 10 1))))
       (should (= (overlay-end (car (last segments))) (cdr table)))
       (dolist (segment segments)
         (should (eq (overlay-get segment 'org-flow-table-table) (car table)))
         (should (org-flow-table-tests--lines
                  (overlay-get segment 'before-string))))
       (org-flow-table--remove-overlay (nth 2 segments))
       (should-not (seq-some #'overlay-buffer segments))
       (should-not org-flow-table--overlays)))))

(ert-deftest org-flow-table-rows-replace-only-their-own-line ()
  ;; Redisplay extends a `display' replacement to the next change of the
  ;; property's value and compares values with `eq', so rows sharing one
  ;; string object are replaced as a single stretch: only the first row's
  ;; `before-string' is drawn and the rest of the table disappears.
  (org-flow-table-tests--with-org
      "| A | B |\n|---+---|\n| 1 | 2 |\n| 3 | 4 |\nAfter\n"
    (org-flow-table-tests--with-pixel-mocks
     (let* ((table (car (org-flow-table--tables)))
            (overlay (org-flow-table--display-table
                      (car table) (cdr table) (selected-window) 80))
            (segments (org-flow-table--segments overlay)))
       (should (= (length segments) 4))
       (dolist (segment segments)
         (should (= (next-single-char-property-change (overlay-start segment)
                                                      'display)
                    (overlay-end segment))))))))

(ert-deftest org-flow-table-parse-column-group-metadata ()
  (org-flow-table-tests--with-org
      "| / | < | > | <> | |\n| Name | A | B | C | D |\n|---+---+---+---+---|\n| x | 1 | 2 | 3 | 4 |\n"
    (let ((table (org-flow-table--parse (point-min) (point-max))))
      (should (= (plist-get table :header-rows) 1))
      (should (= (length (plist-get table :rows)) 3))
      (should (equal (caar (plist-get table :rows)) "Name")))))

(ert-deftest org-flow-table-parse-metadata-only-is-empty ()
  (dolist (source '("| / | <> | |\n"
                    "|---+---|\n| / | <> |\n| <l> | <r> |\n|---+---|\n"))
    (org-flow-table-tests--with-org source
      (should-not (org-flow-table--parse (point-min) (point-max))))))

(ert-deftest org-flow-table-parse-slash-data-is-not-metadata ()
  (org-flow-table-tests--with-org "| / | ordinary data |\n"
    (should (equal (caar (plist-get (org-flow-table--parse
                                    (point-min) (point-max)) :rows)) "/"))))

(ert-deftest org-flow-table-measure-cache-keeps-properties-and-owns-keys ()
  (with-temp-buffer
    (save-window-excursion
      (switch-to-buffer (current-buffer))
      (let ((calls 0)
            (plain "text")
            (styled (propertize "text" 'face 'bold)))
        (cl-letf (((symbol-function 'org-flow-table--measure-string)
                   (lambda (string _window)
                     (cl-incf calls)
                     (if (get-text-property 0 'face string) 20 10))))
          (org-flow-table--with-cached-measurements (selected-window)
            (should (= 10 (org-flow-table--measure-string plain nil)))
            (should (= 20 (org-flow-table--measure-string styled nil)))
            (should (= 20 (org-flow-table--measure-string (copy-sequence styled) nil)))
            (should (= calls 2))
            (remove-text-properties 0 4 '(face nil) styled)
            (should (= 10 (org-flow-table--measure-string styled nil)))
            (let ((before calls))
              (should (= 20 (org-flow-table--measure-string
                             (propertize "text" 'face 'bold) nil)))
              (should (= calls before)))))))))

(ert-deftest org-flow-table-measure-cache-invalidates-on-font-remapping ()
  (with-temp-buffer
    (save-window-excursion
      (switch-to-buffer (current-buffer))
      (let ((cache (org-flow-table--measurements (selected-window))))
        (should (eq cache (org-flow-table--measurements (selected-window))))
        (setq-local face-remapping-alist '((default (:height 1.2) default)))
        (should-not (eq cache (org-flow-table--measurements (selected-window))))))))

(ert-deftest org-flow-table-layout-gc-threshold-is-dynamically-scoped ()
  (org-flow-table-tests--with-org "| a |\n"
    (let ((gc-cons-threshold 800000)
          observed)
      (cl-letf (((symbol-function 'org-flow-table--render-rows)
                 (lambda (&rest _)
                   (setq observed gc-cons-threshold)
                   (error "Test layout failure"))))
        (should-error (org-flow-table--display-table
                       (point-min) (point-max) (selected-window) 80))
        (should (= observed (* 64 1024 1024)))
        (should (= gc-cons-threshold 800000))))))

(ert-deftest org-flow-table-render-cache-reuses-and-invalidates ()
  (org-flow-table-tests--with-org "Before\n| a | longer |\n| b | x |\n\nAfter\n"
    (save-window-excursion
      (switch-to-buffer (current-buffer))
      (let ((calls 0)
            (width 80)
            (font 1)
            (layout (symbol-function 'org-flow-table--render-rows))
            (org-flow-table-relayout-delay 3600))
        (org-flow-table-tests--with-pixel-mocks
         (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t))
                   ((symbol-function 'org-flow-table--layout-width)
                    (lambda (_window) width))
                   ((symbol-function 'org-flow-table--font-signature)
                    (lambda (_window) (list font)))
                   ((symbol-function 'org-flow-table--render-rows)
                    (lambda (table window columns &optional budget)
                      (cl-incf calls)
                      (funcall layout table window columns budget))))
           (unwind-protect
               (progn
                 (org-flow-table-mode 1)
                 (should (= calls 1))
                 (let ((rendered (overlay-get (car org-flow-table--overlays)
                                              'before-string)))
                   (org-flow-table-refresh)
                   (should (= calls 1))
                   (should (eq rendered (overlay-get
                                         (car org-flow-table--overlays)
                                         'before-string))))
                 ;; Moving onto a row only removes that row's overlay.
                 (goto-char (caar (org-flow-table--tables)))
                 (org-flow-table--post-command)
                 (should (= (length org-flow-table--overlays) 1))
                 (goto-char (point-min))
                 (org-flow-table--post-command)
                 (should (= calls 1))
                 (should (= (length org-flow-table--overlays) 2))
                 ;; Fonts and widths invalidate the layout.
                 (setq font 2)
                 (org-flow-table-refresh)
                 (should (= calls 2))
                 (setq width 60)
                 (org-flow-table-refresh)
                 (should (= calls 3))
                 ;; Editing drops the cache and the rows; the next command
                 ;; lays the table out again.
                 (goto-char (caar (org-flow-table--tables)))
                 (org-flow-table--post-command)
                 (search-forward "a")
                 (insert " edited")
                 (should-not org-flow-table--render-cache)
                 ;; The rows stay drawn while the edit is made.
                 (should (org-flow-table--table-overlays
                          (caar (org-flow-table--tables))))
                 ;; The next command that leaves the edited row lays the
                 ;; table out again.
                 (goto-char (point-min))
                 (org-flow-table--post-command)
                 (should (= calls 4))
                 ;; "edited" is in the row point rests on, so it is source
                 ;; rather than a drawn row; the rendering holds it either
                 ;; way, and neighbouring rows are drawn from it.
                 (should (string-match-p
                          "edited"
                          (mapconcat (lambda (cached)
                                       (mapconcat
                                        (lambda (span)
                                          (org-flow-table-tests--visible
                                           (nth 1 span)))
                                        (nth 2 cached) ""))
                                     (let (entries)
                                       (maphash (lambda (_key value)
                                                  (push value entries))
                                                org-flow-table--render-cache)
                                       entries)
                                     "")))
                 (goto-char (point-min))
                 (insert "New paragraph\n")
                 ;; The edit is outside any table: the cache keeps the
                 ;; tables it already laid out.
                 (should org-flow-table--render-cache)
                 (goto-char (point-min))
                 (org-flow-table-refresh)
                 (should (= calls 5))
                 ;; One overlay for each of the table's two rows.
                 (should (= (length org-flow-table--overlays) 2)))
             (org-flow-table-mode -1)
             (should-not org-flow-table--render-cache)
             (should-not (memq #'org-flow-table--after-change
                               after-change-functions)))))))))

(ert-deftest org-flow-table-render-cache-checks-source-properties ()
  (org-flow-table-tests--with-org "| a |\n"
    (save-window-excursion
      (switch-to-buffer (current-buffer))
      (let ((calls 0))
        (cl-letf (((symbol-function 'font-lock-ensure) #'ignore)
                  ((symbol-function 'org-flow-table--render-rows)
                   (lambda (&rest _) (cl-incf calls) nil)))
          (org-flow-table--display-table (point-min) (point-max) (selected-window) 80)
          (org-flow-table--clear)
          ;; No live overlay and the mode is off: the key itself must detect
          ;; property-only changes, not just an invalidation hook.
          (put-text-property 3 4 'face 'bold)
          (org-flow-table--display-table (point-min) (point-max) (selected-window) 80)
          (should (= calls 2)))))))

(ert-deftest org-flow-table-measure-preserves-source-when-point-moves ()
  (dolist (fail '(nil t))
    (with-temp-buffer
      (insert "Keep source bytes\n")
      (buffer-enable-undo)
      (set-buffer-modified-p nil)
      (save-window-excursion
        (switch-to-buffer (current-buffer))
        (let ((before (buffer-string)) (undo buffer-undo-list))
          (cl-letf (((symbol-function 'window-text-pixel-size)
                     (lambda (&rest _)
                       (goto-char (point-min))
                       (if fail (error "Test measurement failure") '(10 . 10)))))
            (if fail
                (should-error (org-flow-table--measure-string "probe" (selected-window)))
              (should (= 10 (org-flow-table--measure-string "probe" (selected-window)))))
            (should (equal-including-properties before (buffer-string)))
            (should (eq undo buffer-undo-list))
            (should-not (buffer-modified-p))))))))

(ert-deftest org-flow-table-measure-ignores-line-numbers ()
  (with-temp-buffer
    (insert "Source\n")
    (setq-local display-line-numbers t)
    (save-window-excursion
      (switch-to-buffer (current-buffer))
      (let (numbers)
        (cl-letf (((symbol-function 'window-text-pixel-size)
                   (lambda (&rest _)
                     (push display-line-numbers numbers)
                     '(10 . 10))))
          (should (= 10 (org-flow-table--measure-string "probe"
                                                          (selected-window))))
          (should (equal numbers '(nil)))
          (should (eq display-line-numbers t)))))))

(ert-deftest org-flow-table-measure-isolates-probe-line ()
  ;; An overlay string shown at the end of the buffer must not be
  ;; measured along with the probe.
  (with-temp-buffer
    (insert "Source")
    (save-window-excursion
      (switch-to-buffer (current-buffer))
      (let (measured)
        (cl-letf (((symbol-function 'window-text-pixel-size)
                   (lambda (_window from to &rest _)
                     (setq measured (list (buffer-substring from to)
                                          (char-before from) (char-after to)))
                     '(10 . 10))))
          (org-flow-table--measure-string "probe" (selected-window))
          (should (equal measured '("probe" ?\n ?\n)))
          (should (equal (buffer-string) "Source")))))))

(ert-deftest org-flow-table-prefix-reduces-layout-budgets-and-invalidates-cache ()
  (org-flow-table-tests--with-org "| a | b |\n"
    (save-window-excursion
      (switch-to-buffer (current-buffer))
      (let ((beg (point-min)) (end (point-max)) seen)
        (org-flow-table-tests--with-pixel-mocks
          (cl-letf (((symbol-function 'window-font-width) (lambda (&rest _) 10))
                    ;; Both fringes shown: no continuation column is kept.
                    ((symbol-function 'org-flow-table--reserves-continuation-p)
                     #'ignore)
                    ((symbol-function 'font-lock-ensure) #'ignore)
                    ((symbol-function 'org-flow-table--render-rows)
                     (lambda (_table _window width &optional budget)
                       (push (list width budget) seen)
                       nil)))
            (org-flow-table--display-table beg end (selected-window) 80)
            (should (equal (car seen) '(80 800)))
            (setq-local line-prefix "  ")
            (org-flow-table--display-table beg end (selected-window) 80)
            (should (equal (car seen) '(78 780)))
            ;; Text properties take precedence over buffer-local variables.
            (put-text-property beg end 'line-prefix "    ")
            (org-flow-table--display-table beg end (selected-window) 80)
            (should (equal (car seen) '(76 760)))
            (setq-local wrap-prefix "      ")
            (org-flow-table--display-table beg end (selected-window) 80)
            (should (equal (car seen) '(74 740)))
            (put-text-property beg end 'wrap-prefix "   ")
            (org-flow-table--display-table beg end (selected-window) 80)
            (should (equal (car seen) '(76 760)))
            (org-flow-table--display-table beg end (selected-window) 80)
            (should (= 5 (length seen)))
            (setq-local line-prefix nil wrap-prefix nil)
            (remove-text-properties beg end '(line-prefix nil wrap-prefix nil))
            (org-flow-table--display-table beg end (selected-window) 80)
            (should (equal (car seen) '(80 800)))))))))

(ert-deftest org-flow-table-continuation-column-reduces-layout-budget ()
  (skip-unless (boundp 'overflow-newline-into-fringe))
  (org-flow-table-tests--with-org "| a | b |\n"
    (save-window-excursion
      (switch-to-buffer (current-buffer))
      (let ((beg (point-min)) (end (point-max)) (fringes '(8 8 nil nil)) seen)
        (org-flow-table-tests--with-pixel-mocks
          (cl-letf (((symbol-function 'window-font-width) (lambda (&rest _) 10))
                    ((symbol-function 'window-fringes)
                     (lambda (&rest _) fringes))
                    ((symbol-function 'font-lock-ensure) #'ignore)
                    ((symbol-function 'org-flow-table--render-rows)
                     (lambda (_table _window width &optional budget)
                       (push (list width budget) seen)
                       nil)))
            (let ((overflow-newline-into-fringe t))
              (org-flow-table--display-table beg end (selected-window) 80)
              (should (equal (car seen) '(80 800)))
              ;; Without either fringe the continuation glyph takes the
              ;; last column, and the cached full-width layout is dropped.
              (dolist (without '((0 0 nil nil) (8 0 nil nil) (0 8 nil nil)))
                (setq fringes without)
                (org-flow-table--display-table beg end (selected-window) 80)
                (should (equal (car seen) '(79 790)))))
            (setq fringes '(8 8 nil nil))
            (let ((overflow-newline-into-fringe nil))
              (org-flow-table--display-table beg end (selected-window) 80)
              (should (equal (car seen) '(79 790))))
            ;; One layout with and one without the reserved column.
            (should (= 2 (length seen)))))))))

(ert-deftest org-flow-table-line-numbers-reduce-layout-budget ()
  (org-flow-table-tests--with-org "| a | b |\n"
    (save-window-excursion
      (switch-to-buffer (current-buffer))
      (let ((beg (point-min)) (end (point-max))
            (numbers '(50 . 3)) (body-height 20) seen)
        (org-flow-table-tests--with-pixel-mocks
          (cl-letf (((symbol-function 'window-font-width) (lambda (&rest _) 10))
                    ((symbol-function 'org-flow-table--reserves-continuation-p)
                     #'ignore)
                    ((symbol-function 'line-number-display-width)
                     (lambda (&optional pixelwise)
                       (if pixelwise (car numbers) (cdr numbers))))
                    ((symbol-function 'window-body-height)
                     (lambda (&rest _) body-height))
                    ((symbol-function 'font-lock-ensure) #'ignore)
                    ((symbol-function 'org-flow-table--render-rows)
                     (lambda (_table _window width &optional budget)
                       (push (list width budget) seen)
                       nil)))
            (org-flow-table--display-table beg end (selected-window) 80)
            (should (equal (car seen) '(80 800)))
            (setq-local display-line-numbers t)
            ;; Three digits and two blanks of 10 px each; no reachable line
            ;; (2 + 20 + 5) needs more digits.
            (org-flow-table--display-table beg end (selected-window) 80)
            (should (equal (car seen) '(75 750)))
            ;; Two digits fit the current window start, but scrolling can
            ;; reach line 2 + 93 + 5 = 100: reserve five 12 px glyphs.
            (setq numbers '(48 . 2) body-height 93)
            (org-flow-table--display-table beg end (selected-window) 80)
            (should (equal (car seen) '(74 740)))
            (setq-local display-line-numbers nil)
            (org-flow-table--display-table beg end (selected-window) 80)
            (should (equal (car seen) '(80 800)))))))))

(ert-deftest org-flow-table-line-number-toggle-schedules-relayout ()
  (org-flow-table-tests--with-org "| a |\n"
    (save-window-excursion
      (switch-to-buffer (current-buffer))
      (let ((org-flow-table-relayout-delay 3600))
        (org-flow-table-mode 1)
        (unwind-protect
            (progn
              (should-not org-flow-table--timer)
              (display-line-numbers-mode 1)
              (should org-flow-table--timer))
          (display-line-numbers-mode -1)
          (org-flow-table-mode -1))
        (should-not org-flow-table--timer)
        (should-not (memq #'org-flow-table--schedule-relayout
                          display-line-numbers-mode-hook))))))

(ert-deftest org-flow-table-prefix-measures-display-specifications ()
  (org-flow-table-tests--with-org "| a |\n"
    (save-window-excursion
      (switch-to-buffer (current-buffer))
      (let ((display '(space :width (23))) measured)
        (put-text-property (point-min) (point-max) 'line-prefix
                           (propertize " " 'display display))
        (setq-local wrap-prefix '(space :width (17)))
        (cl-letf (((symbol-function 'org-flow-table--measure-string)
                   (lambda (string _window)
                     (push (get-text-property 0 'display string) measured)
                     (if (equal (car measured) display) 23 17))))
          (should (= 23 (org-flow-table--prefix-width
                         (point-min) (selected-window))))
          (should (equal measured '((space :width (17)) (space :width (23))))))))))

(ert-deftest org-flow-table-revert-does-not-duplicate-previews ()
  "Repeated real file reverts keep one preview and leave source unchanged."
  (let ((file (make-temp-file "otw-revert-" nil ".org"
                              "Before\n| a | b |\n| c | d |\n\nAfter\n"))
        (org-mode-hook '(org-flow-table-mode))
        (org-flow-table-relayout-delay 3600))
    (unwind-protect
        (save-window-excursion
          (org-flow-table-tests--with-pixel-mocks
            (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t)))
              (find-file file)
              (goto-char (point-min))
              (org-flow-table-refresh)
              (dolist (preserve-modes '(nil nil t nil t))
                (revert-buffer t t preserve-modes)
                (should org-flow-table-mode)
                (should (equal (buffer-string)
                               "Before\n| a | b |\n| c | d |\n\nAfter\n"))
                ;; One overlay for each of the table's two rows.
                (should (= 2 (length org-flow-table--overlays)))
                (should (= 2 (length
                              (seq-filter
                               (lambda (ov) (overlay-get ov 'org-flow-table))
                               (append (car (overlay-lists))
                                       (cdr (overlay-lists)))))))))))
      (when-let* ((buffer (find-buffer-visiting file)))
        (with-current-buffer buffer (org-flow-table-mode -1))
        (kill-buffer buffer))
      (delete-file file))))

(ert-deftest org-flow-table-major-mode-change-releases-owned-resources ()
  "Mode changes release previews, markers and timers, not other overlays."
  (org-flow-table-tests--with-org "Before\n| a | b |\n\nAfter\n"
    (save-window-excursion
      (switch-to-buffer (current-buffer))
      (let ((org-flow-table-relayout-delay 3600))
        (org-flow-table-tests--with-pixel-mocks
          (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t)))
            (unwind-protect
                (progn
                  (org-flow-table-mode 1)
                  (org-flow-table--pre-command)
                  (org-flow-table--schedule-relayout)
                  (let ((previews (copy-sequence org-flow-table--overlays))
                        (marker org-flow-table--previous-point)
                        (timer org-flow-table--timer)
                        (unrelated (make-overlay 1 3)))
                    (should previews)
                    (should (marker-position marker))
                    (should (timerp timer))
                    (fundamental-mode)
                    (should-not org-flow-table-mode)
                    (dolist (overlay previews)
                      (should-not (overlay-buffer overlay)))
                    (should-not (marker-position marker))
                    (should-not (memq timer timer-idle-list))
                    (should (eq (overlay-buffer unrelated) (current-buffer)))
                    (delete-overlay unrelated)))
              (org-flow-table-mode -1))))))))

(ert-deftest org-flow-table-disable-removes-major-mode-cleanup-hook ()
  "Explicit disable removes its buffer-local major-mode cleanup hook."
  (org-flow-table-tests--with-org "| a | b |\n"
    (org-flow-table-mode 1)
    (should (memq #'org-flow-table--before-major-mode-change
                  change-major-mode-hook))
    (org-flow-table-mode -1)
    (should-not (memq #'org-flow-table--before-major-mode-change
                      change-major-mode-hook))))

(ert-deftest org-flow-table-relayout-after-org-indent-prefixes ()
  "Tables are laid out again once `org-indent-mode' has prefixed the buffer."
  (org-flow-table-tests--with-org "| a | b |\n"
    (let ((refreshes 0)
          (org-flow-table-relayout-delay 0))
      (org-flow-table-mode 1)
      (unwind-protect
          (cl-letf (((symbol-function 'org-flow-table-refresh)
                     (lambda () (setq refreshes (1+ refreshes)))))
            ;; The hook is buffer-local: other buffers do not relayout ours.
            (with-temp-buffer
              (run-hook-with-args 'org-indent-post-buffer-init-functions
                                  (current-buffer)))
            (should (= refreshes 0))
            (run-hook-with-args 'org-indent-post-buffer-init-functions
                                (current-buffer))
            (should (= refreshes 1)))
        (org-flow-table-mode -1))
      (should-not (memq #'org-flow-table--indent-initialized
                        org-indent-post-buffer-init-functions)))))

;;;; Sticky header

(ert-deftest org-flow-table-sticky-header-string ()
  (org-flow-table-tests--with-org
      "| A | 50% |\n|---+---|\n| 1 | 2 |\n| 3 | 4 |\n"
    (org-flow-table-tests--with-pixel-mocks
     (let* ((overlay (org-flow-table--display-table
                      (point-min) (point-max) (selected-window) 80))
            (widget (overlay-get overlay 'org-flow-table))
            (header (widget-get widget :sticky-header))
            (a (string-match "A" header)))
       ;; The header row as Org draws it, with `%' escaped for the header
       ;; line.
       (should (string-match-p "| A |\\s-*50%%\\s-*|" (substring-no-properties header)))
       ;; The doubled `%' keeps the cell's faces, and so its width.
       (let ((percent (string-match "%%" header)))
         (should (equal (get-text-property percent 'face header)
                        (get-text-property (1+ percent) 'face header)))
         (should (memq 'org-flow-table-header
                       (ensure-list (get-text-property (1+ percent) 'face
                                                       header)))))
       (should-not (text-property-any 0 (length header) 'cursor t header))
       (let ((faces (ensure-list (get-text-property a 'face header))))
         (should (memq 'org-flow-table-header faces))
         (should (eq (car (last faces)) 'default)))
       (should (widget-get widget :sticky-indent)))))
  (org-flow-table-tests--with-org "| a | b |\n| c | d |\n"
    (org-flow-table-tests--with-pixel-mocks
     (let ((overlay (org-flow-table--display-table
                     (point-min) (point-max) (selected-window) 80)))
       (should-not (widget-get (overlay-get overlay 'org-flow-table)
                               :sticky-header))))))

(ert-deftest org-flow-table-sticky-header-follows-window-start ()
  (org-flow-table-tests--with-org
      "Before\n| A | B |\n|---+---|\n| 1 | 2 |\n| 3 | 4 |\nAfter\n"
    (save-window-excursion
      (switch-to-buffer (current-buffer))
      (org-flow-table-tests--with-pixel-mocks
       (let* ((window (selected-window))
              (table (car (org-flow-table--tables)))
              (overlay (org-flow-table--display-table
                        (car table) (cdr table) window 80))
              (widget (overlay-get overlay 'org-flow-table))
              (segments (org-flow-table--segments overlay)))
         (setq header-line-format "Mine")
         (setq org-flow-table-mode t)
         (unwind-protect
             (progn
               ;; Header on screen, or no table at the top: no sticky header.
               (dolist (start (list (point-min) (overlay-start overlay)))
                 (should-not (org-flow-table--sticky-widget window start)))
               ;; The rule below the header and the rows after it.
               (dolist (segment (cdr segments))
                 (should (eq (org-flow-table--sticky-widget
                              window (overlay-start segment))
                             widget)))
               (should-not (org-flow-table--sticky-widget window (cdr table)))
               (set-window-start window (overlay-start (nth 2 segments)))
               (org-flow-table--update-sticky-header)
               (should (eq header-line-format
                           org-flow-table--sticky-header-format))
               (should (string-suffix-p
                        "| A | B |"
                        (string-trim-right
                         (substring-no-properties
                          (org-flow-table--sticky-header-line)))))
               ;; A second update keeps the replaced header line.
               (org-flow-table--update-sticky-header)
               (should (equal org-flow-table--saved-header-line "Mine"))
               ;; Scrolling back to the header restores it.
               (org-flow-table--update-sticky-header window (point-min))
               (should (equal header-line-format "Mine"))
               (set-window-start window (overlay-start (nth 2 segments)))
               (let ((org-flow-table-sticky-header nil))
                 (org-flow-table--update-sticky-header)
                 (should (equal header-line-format "Mine")))
               (org-flow-table--update-sticky-header)
               (should (eq header-line-format
                           org-flow-table--sticky-header-format))
               (org-flow-table-mode -1)
               (should (equal header-line-format "Mine")))
           (org-flow-table-mode -1)))))))

(provide 'org-flow-table-tests)
;;; org-flow-table-tests.el ends here
