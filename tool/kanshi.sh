# ドメイン死活監視処理
csv=./url.csv
logs=""
err_logs=""
chk=""
cnt_ok=0
cnt_warning=0
cnt_alert=0

## ドメイン死活監視対象の定義ファイルを1行ずつ読みこむ
for urls in `cat ${csvfile} | grep -v ^#`
do
    ## ドメイン死活監視対象の定義ファイルの内容を変数化
    request_url=`echo ${urls} | cut -d ',' -f 1`
    ans_status=`echo ${urls} | cut -d ',' -f 2`
    ans_redirect_url=`echo ${urls} | cut -d ',' -f 3`

    ## リクエストURLをCURLで叩いた結果を変数化
    get_url=$(curl -skL "${request_url}" -o /dev/null -w '%{url_effective}\n')
    get_status=$(curl -sk "${request_url}" -o /dev/null -w '%{http_code}\n')

    # 結果チェック
    if [ ${get_status} = ${ans_status} ]; then
        if [ ! ${ans_status:0:1} = 3 ]; then
            # 実行結果と期待結果のステータスが一致していればOK
            chk="OK"
            cnt_ok=$(( cnt_ok + 1 ))
        else
            # 期待結果のステータスが3xxの場合はリダイレクト先URLも確認
            if [ ${get_url} = ${ans_redirect_url} ]; then
                # 実行結果と期待結果のリダイレクトURLが一致していればOK
                chk="OK"
                cnt_ok=$(( cnt_ok + 1 ))
            else
                # 実行結果と期待結果のリダイレクトURLが一致していなければWARNING_REDIRECT
                chk="WARNING_REDIRECT"
                cnt_warning=$(( cnt_warning + 1 ))
            fi
        fi
    elif [ ${get_status:0:1} = 5 ]; then
        # 実行結果が5xxの場合はALERT
        chk="ALERT"
        cnt_alert=$(( cnt_alert + 1 ))
    else
        # 実行結果と期待結果のステータスが一致していなければWARNING_STATUS
        chk="WARNING_STATUS"
        cnt_warning=$(( cnt_warning + 1 ))
    fi

    # ログ出力
    logs+="[${chk}] REQ: ${ans_status}, ${request_url} --> GET: ${get_status}, ${get_url}\n"
    printf "[${chk}] REQ: %s, %s --> GET: %s, %s\n" $chk $ans_status $request_url $get_status $get_url
    if [ ${chk} = "WARNING_REDIRECT" ]; then
        logs+=" (Assumed RedirectUrl = ${ans_redirect_url})\n"
        errlogs+="[${chk}] REQ: ${ans_status}, ${request_url} --> GET: ${get_status}, ${get_url}\n"
        errlogs+=" (Assumed RedirectUrl = ${ans_redirect_url})\n"
        echo " (Assumed RedirectUrl = ${ans_redirect_url})\n"
    elif [ ${chk} = "WARNING_STATUS" ]; then
        logs+=" (Assumed Status = ${ans_status})\n"
        errlogs+="[${chk}] REQ: ${ans_status}, ${request_url} --> GET: ${get_status}, ${get_url}\n"
        errlogs+=" (Assumed Status = ${ans_status})\n"
        echo " (Assumed Status = ${ans_status})\n"
    elif [ ${chk} = "ALERT" ]; then
        logs+=" (Server Error)\n"
        errlogs+="[${chk}] REQ: ${ans_status}, ${request_url} --> GET: ${get_status}, ${get_url}\n"
        errlogs+=" (Server Error)\n"
        echo " (Server Error)\n"
    fi

    # sleep 1s では ALB で Alertあり, 2秒に1回にする
    sleep 2s
done < ./url.csv
echo ${errlogs}

# 実行結果のメール配信
export PATH=$PATH:/usr/sbin
MAIL_FROM="xxx@yyy.zzz"
MAIL_TO="xxx@yyy.zzz"
subject="Domain Check Bot"
alert_subject="** Alert ** "
warning_subject="* Warning * "

## ALERT, WARNING発生時はメール件名を更新
if [ $cnt_alert -gt 0 ]; then
    echo 'alert';
    subject=${alert_subject}${subject}
elif [ $cnt_warning -gt 0 ]; then
    echo 'warning';
    subject=${warning_subject}${subject}
fi

## メール配信
mail_send () {
cat << EOD | nkf -j -m0 | sendmail -t
From: ${MAIL_FROM}
To: ${MAIL_TO}
Subject: ${subject}
MIME-Version: 1.0
Content-Type: text/plain; charset="ISO-2022-JP"
Content-Transfer-Encoding: 7bit
■ドメイン死活監視結果
- OK:`echo -e ${cnt_ok}`
- WARNING:`echo -e ${cnt_warning}`
- ALERT:`echo -e ${cnt_alert}`

■結果ログ
`echo -e ${logs}`
EOD
}
mail_send

#Slack通知準備
SLACK_URL="https://hooks.slack.com/services/xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
FALLBACK="ドメイン死活監視"
TITLE="該当ログは以下の通りです（OK含む全件ログはメーリングリスト宛に配信しています）"
TITLE_LINK=""
TEXT=$errlogs
COLOR_BAR="#FF0000"
EMOJI=:eyes:_BAR
USER="DomainChk.bot"
FOOTER="※問題を検知した上記URLの状態を確認してください"

slack_push=0
message=""
if [ $cnt_warning -gt 0 ]; then
    slack_push=1
    message="ドメイン死活監視で [WARNING] が発生しました"
    pretext=":warning:：WARNING：[2xx]を想定 ⇒ [3xx] または [4xx] を返されたURLがあります"
fi
if [ $cnt_alert -gt 0 ]; then
    slack_push=1
    message="ドメイン死活監視で [ALERT] が発生しました"
    pretext=":sos:：ALERT：[2xx]を想定 ⇒ [2xx]を想定 ⇒ [5xx] が返されたものがあります"
fi

ATTACHMENTS='{'\
'"fallback": "'$FALLBACK'",'\
'"pretext": "'$pretext'",'\
'"title": "'$title'",'\
'"text": "'$TEXT'",'\
'"color": "'$COLOR_BAR'",'\
'"footer": "'$FOOTER'"'\
'}'

PAYLOAD=''\
'payload={"text": "'$message'", '\
'"icon_emoji": "'$EMOJI'", '\
'"username": "'$USER'", '\
'"attachments":['$ATTACHMENTS']}'

# WARNING, ALERT時はSlack通知用準備
if [ $slack_push -eq 1 ]; then
    curl -X POST --data-urlencode "$PAYLOAD" $SLACK_URL
fi

echo 'complate!';