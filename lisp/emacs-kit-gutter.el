;;; emacs-kit-gutter.el --- Git diff gutter indicators in buffers  -*- lexical-binding: t; -*-
;;
;; Author: Rahul Martim Juliato
;; URL: https://github.com/LionyxML/emacs-kit
;; Package-Requires: ((emacs "30.1"))
;; Keywords: vc, convenience
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Displays git diff indicators in the left margin of file-visiting
;; buffers.  Shows added, changed, and deleted lines with colored
;; symbols.  Refreshes on save, revert, and focus changes.

;;; Code:

(require 'cl-lib)
(require 'vc-git)

(defvar-local git-gutter-diff-info nil
  "Current buffer's parsed Git gutter hunk data.
Each entry is (LINE . STATUS), where STATUS is \"added\", \"changed\", or
\"deleted\".")

(use-package emacs-kit-gutter
  :if emacs-kit-enable-buffer-gutter
  :ensure nil
  :no-require t
  :defer t
  :init
  (defun emacs-kit/goto-next-hunk ()
    "Jump cursor to the closest next hunk."
    (interactive)
    (let* ((current-line (line-number-at-pos))
           (line-numbers (mapcar #'car git-gutter-diff-info))
           (sorted-line-numbers (sort line-numbers '<))
           (next-line-number
            (if (not (member current-line sorted-line-numbers))
                ;; If the current line is not in the list, find the next closest line number
                (cl-find-if (lambda (line) (> line current-line)) sorted-line-numbers)
              ;; If the current line is in the list, find the next line number that is not consecutive
              (let ((last-line nil))
                (cl-loop for line in sorted-line-numbers
                         when (and (> line current-line)
                                   (or (not last-line)
                                       (/= line (1+ last-line))))
                         return line
                         do (setq last-line line))))))

      (when next-line-number
        (goto-char (point-min))
        (forward-line (1- next-line-number)))))

  (defun emacs-kit/goto-previous-hunk ()
    "Jump cursor to the closest previous hunk."
    (interactive)
    (let* ((current-line (line-number-at-pos))
           (line-numbers (mapcar #'car git-gutter-diff-info))
           (sorted-line-numbers (sort line-numbers '<))
           (previous-line-number
            (if (not (member current-line sorted-line-numbers))
                ;; If the current line is not in the list, find the previous closest line number
                (cl-find-if (lambda (line) (< line current-line)) (reverse sorted-line-numbers))
              ;; If the current line is in the list, find the previous line number that has no direct predecessor
              (let ((previous-line nil))
                (dolist (line sorted-line-numbers)
                  (when (and (< line current-line)
                             (not (member (1- line) line-numbers)))
                    (setq previous-line line)))
                previous-line))))

      (when previous-line-number
        (goto-char (point-min))
        (forward-line (1- previous-line-number)))))

  (defun emacs-kit/git-gutter--file-relative-to-root (file root)
    "Return FILE relative to Git ROOT."
    (let ((root (file-name-as-directory root)))
      (condition-case nil
          (file-relative-name file root)
        ;; TRAMP may need to expand remote ~ while a connection is stale.  If
        ;; that fails, fall back to local-name string handling; running git
        ;; below will reconnect through TRAMP anyway.
        (file-error
         (let ((file-local (file-local-name file))
               (root-local (file-name-as-directory (file-local-name root))))
           (when (and (string-prefix-p "~/" file-local)
                      (string-match "\\`\\(/home/[^/]+\\)/" root-local))
             (setq file-local
                   (concat (match-string 1 root-local)
                           "/"
                           (substring file-local 2))))
           (if (string-prefix-p root-local file-local)
               (substring file-local (length root-local))
             file-local))))))

  (defun emacs-kit/git-gutter--git-diff-output (file)
    "Return `git diff --unified=0' output for FILE, local or remote."
    (when-let* ((root (vc-git-root file))
                (relative-file
                 (emacs-kit/git-gutter--file-relative-to-root file root)))
      (let ((default-directory (file-name-as-directory root)))
        (with-temp-buffer
          (let ((exit-code
                 (process-file "git" nil t nil
                               "diff" "--unified=0" "--" relative-file)))
            (when (and (integerp exit-code) (zerop exit-code))
              (buffer-string)))))))

  (defun emacs-kit/git-gutter--parse-hunk-lines (diff-output)
    "Parse DIFF-OUTPUT hunk headers into gutter line/status entries."
    (let (result)
      (dolist (line (split-string diff-output "\n" t))
        (when (string-match
               "^@@ -\\([0-9]+\\)\\(?:,\\([0-9]+\\)\\)? \\+\\([0-9]+\\)\\(?:,\\([0-9]+\\)\\)? @@"
               line)
          (let* ((old-count (if (match-string 2 line)
                                (string-to-number (match-string 2 line))
                              1))
                 (new-start (string-to-number (match-string 3 line)))
                 (new-count (if (match-string 4 line)
                                (string-to-number (match-string 4 line))
                              1)))
            (cond
             ((= new-count 0)
              (push (cons (1+ new-start) "deleted") result))
             ((= old-count 0)
              (dotimes (i new-count)
                (push (cons (+ new-start i) "added") result)))
             (t
              (dotimes (i new-count)
                (push (cons (+ new-start i) "changed") result)))))))
      (nreverse result)))

  (defun emacs-kit/git-gutter-process-git-diff ()
    "Process git diff for adds/mods/removals.
Marks lines as added, deleted, or changed.  Works for local files and TRAMP
files by running git from the repository root and passing a repo-relative path."
    (interactive)
    (let* ((file-path (buffer-file-name))
           (result (and file-path
                        (condition-case nil
                            (when-let* ((output
                                         (emacs-kit/git-gutter--git-diff-output
                                          file-path)))
                              (emacs-kit/git-gutter--parse-hunk-lines output))
                          (file-error nil)))))
      (setq-local git-gutter-diff-info result)
      result))


  (defun emacs-kit/git-gutter-add-mark (&rest _args)
    "Add symbols to the left margin based on Git diff statuses.
- '+' for added lines (uses `success` face)
- '~' for changed lines (uses `warning` face)
- '-' for deleted lines (uses `error` face)."
    (interactive)
    (remove-overlays (point-min) (point-max) 'emacs-kit--git-gutter-overlay t)
    (let ((lines-status (or (emacs-kit/git-gutter-process-git-diff) '())))
      (save-excursion
        (dolist (line-status lines-status)
          (let* ((line-num (car line-status))
                 (status (cdr line-status))
                 (symbol (cond                                ;; Alternatives:
                          ((string= status "added")   "┃")    ;; +  │ ▏┃
                          ((string= status "changed") "┃")    ;; ~  │ ▏┃
                          ((string= status "deleted") "┃")))  ;; _  _‾ x
                 (face (cond
                        ((string= status "added")   'success)
                        ((string= status "changed") 'warning)
                        ((string= status "deleted") 'error))))
            (when (and line-num status)
              (goto-char (point-min))
              (forward-line (1- line-num))
              (let ((overlay (make-overlay (line-beginning-position) (line-beginning-position))))
                (overlay-put overlay 'emacs-kit--git-gutter-overlay t)
                (overlay-put overlay 'before-string
                             (propertize " "
                                         'display
                                         `((margin left-margin)
                                           ,(propertize symbol 'face face)))))))))))

  (defun emacs-kit/timed-git-gutter-on()
    (let ((buf (current-buffer)))
      (run-at-time 0.1 nil (lambda ()
                             (when (buffer-live-p buf)
                               (with-current-buffer buf
                                 (emacs-kit/git-gutter-add-mark)))))))

  (defun emacs-kit/git-gutter-off ()
    "Remove all `emacs-kit--git-gutter-overlay' marks and other overlays."
    (interactive)
    (remove-overlays (point-min) (point-max) 'emacs-kit--git-gutter-overlay t)
    (remove-hook 'find-file-hook #'emacs-kit/timed-git-gutter-on)
    (remove-hook 'after-save-hook #'emacs-kit/git-gutter-add-mark)
    (remove-hook 'after-revert-hook #'emacs-kit/timed-git-gutter-on)
    (remove-function after-focus-change-function #'emacs-kit/git-gutter-refresh-visible)
    (remove-hook 'window-selection-change-functions #'emacs-kit/git-gutter-on-window-switch))

  (defun emacs-kit/git-gutter-on ()
    (interactive)
    (add-hook 'find-file-hook #'emacs-kit/timed-git-gutter-on)
    (add-hook 'after-save-hook #'emacs-kit/git-gutter-add-mark)
    (add-hook 'after-revert-hook #'emacs-kit/timed-git-gutter-on)
    (add-function :after after-focus-change-function #'emacs-kit/git-gutter-refresh-visible)
    (add-hook 'window-selection-change-functions #'emacs-kit/git-gutter-on-window-switch)
    (when (not (string-match-p "^\\*" (buffer-name))) ; avoid *scratch*, etc.
      (emacs-kit/git-gutter-add-mark)))

  (defun emacs-kit/git-gutter-refresh-visible ()
    "Refresh gutter marks in all visible file-visiting buffers.
Runs after Emacs regains focus (e.g. switching back from terminal
after git add/commit, or after an external tool modifies files)."
    (when (frame-focus-state)
      (dolist (win (window-list))
        (let ((buf (window-buffer win)))
          (when (and (buffer-file-name buf)
                     (not (string-match-p "^\\*" (buffer-name buf)))
                     (vc-git-root (buffer-file-name buf)))
            (with-current-buffer buf
              (emacs-kit/timed-git-gutter-on)))))))

  (defun emacs-kit/git-gutter-on-window-switch (_frame)
    "Refresh gutter marks in the newly selected window's buffer.
Called by `window-selection-change-functions' on C-x o, etc."
    (let ((buf (window-buffer (selected-window))))
      (when (and (buffer-file-name buf)
                 (not (string-match-p "^\\*" (buffer-name buf)))
                 (vc-git-root (buffer-file-name buf)))
        (with-current-buffer buf
          (emacs-kit/timed-git-gutter-on)))))

  (global-set-key (kbd "M-9") 'emacs-kit/goto-previous-hunk)
  (global-set-key (kbd "M-0") 'emacs-kit/goto-next-hunk)
  (global-set-key (kbd "C-c g p") 'emacs-kit/goto-previous-hunk)
  (global-set-key (kbd "C-c g r") 'emacs-kit/git-gutter-off)
  (global-set-key (kbd "C-c g g") 'emacs-kit/git-gutter-on)
  (global-set-key (kbd "C-c g n") 'emacs-kit/goto-next-hunk)

  (add-hook 'after-init-hook #'emacs-kit/git-gutter-on))

(provide 'emacs-kit-gutter)
;;; emacs-kit-gutter.el ends here
