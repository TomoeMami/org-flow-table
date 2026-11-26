;;; bench.el --- Measure GUI table scenarios -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; Run from any directory:
;; /opt/homebrew/bin/Emacs -Q -l /Users/chenyibin/Documents/emacs/package/org-flow-table/demos/bench.el
;; GUI Emacs.app does NOT inherit the shell cwd.  Use absolute -l, --eval
;; file names, and log paths, or pass --chdir with the repository first.
;; Prefer --batch for checks that do not need real pixels.
;; Writes bench.log and huge-cpu-profile.sexp, then exits the isolated Emacs.
;;; Code:
(require 'cl-lib)
(require 'benchmark)
(require 'profiler)

(defconst org-flow-table-bench--directory
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory containing benchmark inputs and outputs.")
(add-to-list 'load-path (expand-file-name ".." org-flow-table-bench--directory))
(require 'org-flow-table)

(defun org-flow-table-bench--log (format-string &rest args)
  "Append FORMAT-STRING formatted with ARGS to the benchmark log."
  (write-region (concat (apply #'format format-string args) "\n") nil
                (expand-file-name "bench.log" org-flow-table-bench--directory)
                t 'silent))

(defvar-local org-flow-table-bench--source-hash nil
  "Hash of the original benchmark buffer characters.")

(defvar-local org-flow-table-bench--source-size nil
  "Original benchmark buffer size in characters.")

(defun org-flow-table-bench--verify ()
  "Reject timings if layout changed source text or buffer restrictions."
  (org-flow-table-bench--log
   "INVARIANT size=%d expected=%d bounds=(%d %d) source-unchanged=%S"
   (buffer-size) org-flow-table-bench--source-size (point-min) (point-max)
   (save-restriction
     (widen)
     (equal org-flow-table-bench--source-hash
            (secure-hash 'sha1 (current-buffer)))))
  (cl-assert (not (buffer-narrowed-p)))
  (cl-assert (= (buffer-size) org-flow-table-bench--source-size))
  (cl-assert (equal org-flow-table-bench--source-hash
                    (secure-hash 'sha1 (current-buffer)))))

(defun org-flow-table-bench--memory (gc)
  "Return live Lisp bytes estimated from garbage collection data GC."
  (cl-loop for (_type size used . _rest) in gc sum (* size used)))

(defun org-flow-table-bench--profile ()
  "Write a CPU profile and the ten hottest exclusive and inclusive frames."
  (profiler-stop)
  (let* ((profile (profiler-cpu-profile))
         (log (profiler-profile-log profile))
         (self (make-hash-table :test 'equal))
         (inclusive (make-hash-table :test 'equal))
         (total 0))
    (let ((make-backup-files nil))
      (profiler-write-profile profile
                              (expand-file-name "huge-cpu-profile.sexp"
                                                org-flow-table-bench--directory)))
    (save-window-excursion (profiler-report))
    (maphash
     (lambda (stack count)
       (cl-incf total count)
       (let ((frames (delq nil (append (profiler-fixup-backtrace stack) nil))))
         (puthash (car frames) (+ count (gethash (car frames) self 0)) self)
         (dolist (frame (delete-dups frames))
           (puthash frame (+ count (gethash frame inclusive 0)) inclusive))))
     log)
    (dolist (kind (list (cons 'self self) (cons 'inclusive inclusive)))
      (let (entries)
        (maphash (lambda (frame count) (push (cons frame count) entries)) (cdr kind))
        (setq entries (sort entries (lambda (a b) (> (cdr a) (cdr b)))))
        (org-flow-table-bench--log "PROFILE %s total-weight=%d" (car kind) total)
        (dolist (entry (seq-take entries 10))
          (org-flow-table-bench--log "  %.2f%% %S weight=%d"
                                       (* 100.0 (/ (float (cdr entry)) (max 1 total)))
                                       (car entry) (cdr entry)))))))

(defun org-flow-table-bench--run (name enabled)
  "Benchmark demo NAME with widgets ENABLED or disabled."
  (set-frame-size nil 1400 800 t)
  (let ((buffer (generate-new-buffer (format " *bench-%s-%s*" name enabled))))
    (unwind-protect
        (with-current-buffer buffer
          (insert-file-contents (expand-file-name name org-flow-table-bench--directory))
          (org-mode)
          (setq-local org-flow-table-relayout-delay 3600)
          (switch-to-buffer buffer)
          (goto-char (point-min))
          (set-window-start nil (point-min))
          (set-buffer-modified-p nil)
          (setq org-flow-table-bench--source-hash
                (secure-hash 'sha1 (current-buffer))
                org-flow-table-bench--source-size (buffer-size))
          (org-flow-table-bench--log "BEGIN %s mode=%s body=%dpx" name enabled
                                       (window-body-width nil t))
          (let* ((gc-before (garbage-collect))
                 (cold (benchmark-run 1
                         (if enabled (org-flow-table-mode 1) (font-lock-ensure))))
                 (gc-after (garbage-collect))
                 (delta (- (org-flow-table-bench--memory gc-after)
                           (org-flow-table-bench--memory gc-before))))
            (org-flow-table-bench--log "cold=%S memory-bytes=%d overlays=%d\ngc-before=%S\ngc-after=%S"
                                         cold delta (length org-flow-table--overlays)
                                         gc-before gc-after))
          (org-flow-table-bench--verify)
          (org-flow-table-bench--log "STATE after-cold point=%d min=%d max=%d tables=%d overlays=%d"
                                       (point) (point-min) (point-max)
                                       (length (org-flow-table--tables))
                                       (length org-flow-table--overlays))
          (goto-char (point-min))
          (org-flow-table-bench--log
           "warm=%S" (benchmark-run 1
                       (if enabled (org-flow-table-refresh) (font-lock-ensure))))
          (org-flow-table-bench--verify)
          (org-flow-table-bench--log "STATE after-warm point=%d tables=%d overlays=%d"
                                       (point) (length (org-flow-table--tables))
                                       (length org-flow-table--overlays))
          (goto-char (point-min))
          (set-frame-size nil 1100 800 t)
          (org-flow-table--cancel-relayout)
          (org-flow-table-bench--log
           "resize=%S body=%dpx"
           (benchmark-run 1
             (if enabled (org-flow-table--run-relayout buffer) (redisplay t)))
           (window-body-width nil t))
          (org-flow-table-bench--verify)
          (org-flow-table-bench--log "STATE after-resize point=%d tables=%d overlays=%d"
                                       (point) (length (org-flow-table--tables))
                                       (length org-flow-table--overlays))
          (let ((beg (caar (org-flow-table--tables))))
            (goto-char beg)
            (org-flow-table-bench--log
             "enter=%S" (benchmark-run 1
                          (when enabled (org-flow-table-toggle))))
            (goto-char (point-min))
            (org-flow-table-bench--log
             "leave=%S" (benchmark-run 1
                          (when enabled (org-flow-table--post-command)))))
          (org-flow-table-bench--verify)
          (org-flow-table-bench--log "STATE after-leave point=%d tables=%d overlays=%d"
                                       (point) (length (org-flow-table--tables))
                                       (length org-flow-table--overlays))
          (goto-char (point-min))
          (set-window-start nil (point-min))
          (org-flow-table-bench--log "redisplay5=%S"
                                       (benchmark-run 5 (redisplay t)))
          (goto-char (point-min))
          (set-window-start nil (point-min))
          ;; End-of-buffer is a valid scrolling result for a replacement overlay.
          (let ((ends 0))
            (org-flow-table-bench--log
             "scroll20=%S" (benchmark-run 20
                             (condition-case nil (scroll-up-command)
                               (end-of-buffer (cl-incf ends)))))
            (org-flow-table-bench--log "scroll-end-of-buffer=%d" ends))
          (org-flow-table-bench--log "END %s mode=%s modified=%S" name enabled
                                       (buffer-modified-p)))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer (org-flow-table-mode -1))
        (kill-buffer buffer)))))

(defun org-flow-table-bench-main ()
  "Run baseline, widget benchmarks, and a separate huge cold CPU profile."
  (condition-case err
      (progn
        (set-face-attribute 'default nil :family "Iosevka" :height 150)
        (set-face-attribute 'fixed-pitch nil :family "Iosevka" :height 150)
        (write-region "" nil (expand-file-name "bench.log" org-flow-table-bench--directory))
        (org-flow-table-bench--log "Emacs=%s graphic=%S font=%S gc-cons-threshold=%d time=%s"
                                     emacs-version (display-graphic-p) (face-font 'default)
                                     gc-cons-threshold (current-time-string))
        (dolist (name '("large.org" "huge.org"))
          (org-flow-table-bench--run name nil)
          (org-flow-table-bench--run name t))
        (set-frame-size nil 1400 800 t)
        (find-file (expand-file-name "huge.org" org-flow-table-bench--directory))
        (goto-char (point-min))
        (setq-local org-flow-table-relayout-delay 3600)
        (garbage-collect)
        (profiler-start 'cpu)
        (org-flow-table-mode 1)
        (org-flow-table-bench--profile)
        (org-flow-table-bench--log "COMPLETE"))
    (error (org-flow-table-bench--log "ERROR %S" err)))
  (kill-emacs))

(unless noninteractive
  (run-with-timer 1 nil #'org-flow-table-bench-main))

(provide 'org-flow-table-demo-bench)
;;; bench.el ends here
