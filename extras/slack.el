(require 'cl-lib)

;; GNU Emacs client for Slack.
;; https://github.com/emacs-slack/emacs-slack
(use-package slack
  :ensure t
  :bind (("C-c S K" . slack-stop)
         ("C-c S c" . slack-select-rooms)
         ("C-c S u" . slack-select-unread-rooms)
         ("C-c S n" . my/slack-show-unread-rooms) ; n = unread list
         ("C-c S U" . slack-user-select)
         ("C-c S s" . slack-search-from-messages)
         ("C-c S J" . slack-jump-to-browser)
         ("C-c S j" . slack-jump-to-app)
         ("C-c S e" . slack-insert-emoji)
         ("C-c S E" . slack-message-edit)
         ("C-c S r" . slack-message-add-reaction)
         ("C-c S t" . slack-thread-show-or-create)
         ("C-c S g" . slack-message-redisplay)
         ("C-c S G" . slack-conversations-list-update-quick)
         ("C-c S q" . slack-quote-and-reply)
         ("C-c S Q" . slack-quote-and-reply-with-link)
         (:map slack-mode-map
               (("@" . slack-message-embed-mention)
                ("#" . slack-message-embed-channel)))
         (:map slack-thread-message-buffer-mode-map
               (("C-c '" . slack-message-write-another-buffer)
                ("@" . slack-message-embed-mention)
                ("#" . slack-message-embed-channel)))
         (:map slack-message-buffer-mode-map
               (("C-c '" . slack-message-write-another-buffer)))
         (:map slack-message-compose-buffer-mode-map
               (("C-c '" . slack-message-send-from-buffer)))
         )
;;  :custom
  ;; (slack-extra-subscribed-channels (mapcar 'intern (list "some-channel")))
  :config
  (slack-register-team
     :name "teamdigits"
     :token "xoxc-350159074406-462173806805-8866946792372-401d219fa571a6f9cb6112b7ede959bf42fb812d0484f934b15e1cd96b12244e"
     :cookie "xoxd-zZCUNbOElL5RpAzD%2BS2I5x%2F4SmEY9TbUcw27IIpmYcuREWkzoN2RDxWB88KGpWMTxzKCvEBXKhmzVioRE4z8NXzsDQptQKPJZ2ISxNYi8N9g9pqCCncley5gB7Bndv3tf7QlmvIW%2FWyxFhdZp%2FUJKbx71Rdwd8tBZJXZ%2Bo%2BhlG92xfSU4feEcBAm2tHv2oIdlOj9omo%3D; d-s=1746664344; lc=1746664344"
     :full-and-display-names t
     :default t
     ;; :subscribed-channels nil ;; using slack-extra-subscribed-channels because I can change it dynamically
     ))

  ;; ========= Unread room list buffer =========
  (define-derived-mode slack-unread-mode tabulated-list-mode "Slack-Unread"
    "一覧で未読チャンネルを表示するモード。RET で開く。"
    (setq tabulated-list-format [("Team" 15 t)
                                 ("Room" 30 t)
                                 ("Unread" 6 t)])
    (setq tabulated-list-padding 2)
    (tabulated-list-init-header))

  (defun my/slack--collect-unread-rooms ()
    "未読メッセージがある room の (TEAM ROOM) のリストを返す。"
    (let (result)
      (dolist (team slack-teams)
        (dolist (room (append (slack-team-channels team)
                              (slack-team-groups   team)
                              (slack-team-ims      team)))
          (when (slack-room-has-unread-p room)
            (push (list team room) result))))
      (nreverse result)))

  (defun my/slack-unread-open ()
    "現在行の room を開く。"
    (interactive)
    (let* ((id   (tabulated-list-get-id))
           (spec (split-string id "|"))
           (team-id (car  spec))
           (room-id (cadr spec))
           (team (cl-find-if (lambda (t) (string= (oref t id) team-id)) slack-teams))
           (room (and team (slack-room-find room-id team))))
      (when (and team room)
        (slack-room-buffer-create room team))))

  (define-key slack-unread-mode-map (kbd "RET") #'my/slack-unread-open)

  ;; メインコマンド
  (defun my/slack-show-unread-rooms ()
    "未読のあるすべてのチャンネル / グループ / IM を一覧表示する。"
    (interactive)
    (let ((buf (get-buffer-create "*Slack Unread*")))
      (with-current-buffer buf
        (slack-unread-mode)
        (setq tabulated-list-entries
              (mapcar (lambda (pair)
                        (let* ((team (car  pair))
                               (room (cadr pair))
                               (team-name (slack-team-name team))
                               (room-name (slack-room-name room team))
                               (unread    (number-to-string (slack-room-unread-count room)))
                               (id (format "%s|%s" (oref team id) (oref room id))))
                          (list id (vector team-name room-name unread))))
                      (my/slack--collect-unread-rooms)))
        (tabulated-list-print t))
      (pop-to-buffer buf)))

(use-package alert
  :ensure t
  :commands (alert)
  :init
  (setq alert-default-style 'notifier))
