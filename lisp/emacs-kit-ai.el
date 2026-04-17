;;; emacs-kit-ai.el --- AI assistant integration (Ollama, Gemini, Claude)  -*- lexical-binding: t; -*-
;;
;; Author: Rahul Martim Juliato
;; URL: https://github.com/LionyxML/emacs-kit
;; Package-Requires: ((emacs "30.1"))
;; Keywords: tools, convenience
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Provides interactive functions to launch AI chat sessions
;; (Ollama, Gemini, Claude).  Claude uses `vterm' buffers for
;; robust TUI rendering.  Ollama and Gemini use `eat'.
;; Supports sending selected regions as context.

;;; Code:

(use-package emacs-kit-ai
  :ensure nil
  :no-require t
  :defer t
  :after eat
  :init
  (defun emacs-kit/ollama-run-model ()
    "Run `ollama list`, let the user choose a model.
And open it in `eat'.
If a region is selected, use it as a query.
If a prompt is provided, it's prepended."
    (interactive)
    (let* ((output (shell-command-to-string "ollama list"))
           (models (mapcar (lambda (line) (car (split-string line)))
                           (cdr (split-string output "\n" t))))
           (selected (completing-read "Select Ollama model: " models nil t))
           (region-text (when (use-region-p)
                          (buffer-substring-no-properties (region-beginning)
                                                          (region-end))))
           (prompt (read-string "Ollama Prompt (optional): " nil nil nil)))
      (when (and selected (not (string-empty-p selected)))
        (let* ((body (string-join (delq nil (list prompt region-text)) "\n"))
               (escaped-body (replace-regexp-in-string "\"" "\\\\\"" body))
               (command (format "printf \"%s\" | ollama run %s" escaped-body selected))
               (buf (eat-make (generate-new-buffer-name "ollama") "/bin/sh" nil)))
          (pop-to-buffer buf)
          (run-at-time 0.5 nil
                       (lambda (b cmd)
                         (when (buffer-live-p b)
                           (with-current-buffer b
                             (eat-term-send-string eat-terminal cmd)
                             (eat-term-send-string eat-terminal "\n"))))
                       buf command)))))


  (defun emacs-kit/gemini-chat ()
    "Start a new interactive `gemini` session in an `eat' buffer."
    (interactive)
    (let* ((default-directory (or (vc-root-dir)
                                  (and emacs-kit-ai-scratch-path
                                       (file-directory-p emacs-kit-ai-scratch-path)
                                       emacs-kit-ai-scratch-path)
                                  default-directory))
           (buffer-name (generate-new-buffer-name
                         (format "gemini-chat:%s"
                                 (file-name-nondirectory (directory-file-name default-directory))))))
      (let ((buf (eat-make buffer-name "gemini" nil)))
        (pop-to-buffer buf)
        (with-current-buffer buf
          (setq-local column-number-mode nil))))))

(provide 'emacs-kit-ai)
;;; emacs-kit-ai.el ends here
