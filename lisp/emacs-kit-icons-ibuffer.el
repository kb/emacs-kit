;;; emacs-kit-icons-ibuffer.el --- File type icons for ibuffer  -*- lexical-binding: t; -*-
;;
;; Author: Rahul Martim Juliato
;; URL: https://github.com/LionyxML/emacs-kit
;; Package-Requires: ((emacs "30.1"))
;; Keywords: faces, convenience
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Adds a custom icon column to ibuffer that shows file type or
;; mode-based icons for each buffer.

;;; Code:

(use-package emacs-kit-icons-ibuffer
  :if (memq 'ibuffer emacs-kit-icon-modules)
  :ensure nil
  :no-require t
  :defer t
  :init
  (defun emacs-kit/ibuffer-icon-for-buffer (buf)
    "Return an icon for BUF: file-extension emoji if visiting a file,
otherwise mode-based emoji."
    (with-current-buffer buf
      (if-let* ((file (buffer-file-name)))
          ;; File-based icons
          (let* ((ext (file-name-extension file))
                 (icon (and ext (emacs-kit/file-icon (downcase ext)))))
            (or icon (emacs-kit/file-icon "diredfile")))
        ;; Mode-based icons for non-file buffers
        (cond
         ((derived-mode-p 'dired-mode)  (emacs-kit/file-icon "direddir"))
         ((derived-mode-p 'eshell-mode) (emacs-kit/file-icon "terminal"))
         ((derived-mode-p 'org-mode)    (emacs-kit/file-icon "terminal"))
         ((derived-mode-p 'shell-mode)  (emacs-kit/file-icon "terminal"))
         ((derived-mode-p 'term-mode)   (emacs-kit/file-icon "terminal"))
         ((derived-mode-p 'help-mode)   (emacs-kit/file-icon "info"))
         ((derived-mode-p 'erc-mode)    (emacs-kit/file-icon "hash"))
         ((derived-mode-p 'rcirc-mode)  (emacs-kit/file-icon "hash"))
         ((derived-mode-p 'gnus-mode)   (emacs-kit/file-icon "mail"))
         ((derived-mode-p 'newsticker-treeview-mode)   (emacs-kit/file-icon "news"))
         (t                             (emacs-kit/file-icon "wranch"))))))

  (define-ibuffer-column icon
    (:name " ")
    (emacs-kit/ibuffer-icon-for-buffer buffer))

  ;; Update ibuffer formats
  (setq ibuffer-formats
        '((mark modified read-only locked " "
                (icon 2 2 :left) " "
                (name 30 30 :left :elide) " "
                (size 9 -1 :right) " "
                (mode 16 16 :left :elide) " "
                filename-and-process))))

(provide 'emacs-kit-icons-ibuffer)
;;; emacs-kit-icons-ibuffer.el ends here
