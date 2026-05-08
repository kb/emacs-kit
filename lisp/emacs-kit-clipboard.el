;;; emacs-kit-clipboard.el --- System clipboard integration for terminals  -*- lexical-binding: t; -*-
;;
;; Author: Rahul Martim Juliato
;; URL: https://github.com/LionyxML/emacs-kit
;; Package-Requires: ((emacs "30.1"))
;; Keywords: terminals, convenience
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Enables proper copy/paste in terminal Emacs by setting up
;; `interprogram-cut-function' and `interprogram-paste-function'
;; for macOS (pbcopy/pbpaste), WSL (clip.exe), Wayland (wl-copy),
;; and X11 (xclip).

;;; Code:

(use-package emacs-kit-clipboard
  :ensure nil
  :no-require t
  :defer t
  :init
  (cond
   ;; macOS: use pbcopy/pbpaste
   ((eq system-type 'darwin)
    (setq interprogram-cut-function
          (lambda (text &optional _)
            (let ((process-connection-type nil))
              (let ((proc (start-process "pbcopy" "*Messages*" "pbcopy")))
                (process-send-string proc text)
                (process-send-eof proc)))))
    (setq interprogram-paste-function
          (lambda ()
            (with-temp-buffer
              (call-process "/usr/bin/pbpaste" nil t nil)
              (buffer-string)))))

   ;; WSL (Windows Subsystem for Linux): Use clip.exe for copy and powershell.exe for paste
   ((and (eq system-type 'gnu/linux)
         (getenv "WSLENV"))
    (setq interprogram-cut-function
          (lambda (text &optional _)
            (let ((process-connection-type nil))
              (let ((proc (start-process "clip.exe" "*Messages*" "clip.exe")))
                (process-send-string proc text)
                (process-send-eof proc)))))
    (setq interprogram-paste-function
          (lambda ()
            (string-trim (shell-command-to-string "powershell.exe -command Get-Clipboard")))))

   ;; Linux with wl-copy/wl-paste (Wayland)
   ((and (eq system-type 'gnu/linux)
         (getenv "WAYLAND_DISPLAY")
         (executable-find "wl-copy"))
    (setq interprogram-cut-function
          (lambda (text &optional _)
            (let ((process-connection-type nil))
              (let ((proc (start-process "wl-copy" "*Messages*" "wl-copy")))
                (process-send-string proc text)
                (process-send-eof proc)))))
    (setq interprogram-paste-function
          (lambda ()
            (shell-command-to-string "wl-paste -n"))))

   ;; Linux TTY without X11 (e.g. cook pod over ssh): use emacs's built-in
   ;; xterm OSC 52 clipboard handler.  Setting `xterm-extra-capabilities'
   ;; to include `setSelection' tells `xterm.el' to write the kill-ring
   ;; through to the terminal's clipboard via OSC 52, which the Mac
   ;; terminal (iTerm/Ghostty/Kitty/WezTerm) captures and writes to the
   ;; host clipboard.  Routes through emacs's standard selection
   ;; machinery rather than a hand-rolled `send-string-to-terminal' call,
   ;; so the bytes are properly flushed and the redisplay state stays
   ;; consistent.  OSC 52 is write-only -- pasting from the Mac clipboard
   ;; back into emacs is handled by the terminal's own Cmd-V.
   ((and (eq system-type 'gnu/linux)
         (not (display-graphic-p))
         (not (getenv "DISPLAY")))
    (setq select-enable-clipboard t)
    (setq xterm-extra-capabilities '(setSelection)))

   ;; Linux with xclip (X11)
   ((and (eq system-type 'gnu/linux)
         (getenv "DISPLAY")
         (executable-find "xclip"))
    (setq interprogram-cut-function
          (lambda (text &optional _)
            (let ((process-connection-type nil))
              (let ((proc (start-process "xclip" "*Messages*" "xclip" "-selection" "clipboard")))
                (process-send-string proc text)
                (process-send-eof proc)))))
    (setq interprogram-paste-function
          (lambda ()
            (shell-command-to-string "xclip -selection clipboard -o"))))))

(provide 'emacs-kit-clipboard)
;;; emacs-kit-clipboard.el ends here
