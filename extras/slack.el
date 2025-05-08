
;; GNU Emacs client for Slack.
;; https://github.com/emacs-slack/emacs-slack
(use-package slack
  :ensure t
  :bind (("C-c S K" . slack-stop)
         ("C-c S c" . slack-select-rooms)
         ("C-c S u" . slack-select-unread-rooms)
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

(use-package alert
  :ensure t
  :commands (alert)
  :init
  (setq alert-default-style 'notifier))
