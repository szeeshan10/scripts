#!/bin/bash
_bold=$(tput bold)
_underline=$(tput sgr 0 1)
_red=$(tput setaf 1)
_green=$(tput setaf 76)
_blue=$(tput setaf 38)
_reset=$(tput sgr0)

function _success() {
    printf '%s✔ %s%s\n' "$_green" "$@" "$_reset"
}

function _error() {
    printf '%s✖ %s%s\n' "$_red" "$@" "$_reset"
}

function _note() {
    printf '%s%s%sNote:%s %s%s%s\n' "$_underline" "$_bold" "$_blue" "$_reset" "$_blue" "$@" "$_reset"
}

email=$1
apikey=$2

if [[ -z "$email" ]]; then
    read -p "Enter your email: " email
fi

if [[ -z "$apikey" ]]; then
    read -sp "Enter your API key: " apikey
    echo
fi

opID=()
homeDir=$PWD
#server="123456"   # <-- Fixed target server ID
read -p "Enter the Server ID: " server

_note "Retrieving Access Token"

accesstoken="$(curl -s -H "Accept: application/json" -H "Content-Type:application/json" -X POST \
--data '{"email" : "'$email'", "api_key" : "'$apikey'"}' \
'https://api.cloudways.com/api/v1/oauth/access_token' | jq -r '.access_token')"

_note "Retrieving Server and Apps Information"
curl -s -X GET --header 'Accept: application/json' \
--header 'Authorization: Bearer '$accesstoken'' \
'https://api.cloudways.com/api/v1/server' > servers.json

_note "Running XML-RPC disable operation for Server ID $server"

while read app; do
    _note "Disabling XML-RPC for App ID: $app on Server: $server"
    echo ""

    resp="$(curl -s -X POST \
        --header 'Content-Type: application/x-www-form-urlencoded' \
        --header 'Accept: application/json' \
        --header 'Authorization: Bearer '$accesstoken'' \
        --data 'server_id='$server'&app_id='$app'&status=disable' \
        'https://api.cloudways.com/api/v1/app/manage/xmlrpc')"

    while [[ "$(echo $resp | jq -r '.message')" =~ ^"An operation is already in progress" ]]; do
        _note "An operation is already in progress on Server: $server"
        _note "Putting the script to sleep for 10s..."
        sleep 10
        _note "Retrying..."
        resp="$(curl -s -X POST \
            --header 'Content-Type: application/x-www-form-urlencoded' \
            --header 'Accept: application/json' \
            --header 'Authorization: Bearer '$accesstoken'' \
            --data 'server_id='$server'&app_id='$app'&status=disable' \
            'https://api.cloudways.com/api/v1/app/manage/xmlrpc')"
    done

    opID+=("$(echo "$resp" | jq -r '.operation_id')")
    _note "Sleeping for 10s to respect API rate limits."
    sleep 10

done < <(cat servers.json | jq -r '.servers[] | select(.id == "'$server'") | .apps[] | select((.application == "wordpress" or .application == "wordpressdefault") and (.is_staging == "0")) | .id')

echo ""
_note "Fetching Operation Status"
for ops in "${opID[@]}"; do
    curl -s -X GET --header 'Accept: application/json' \
    --header 'Authorization: Bearer '$accesstoken'' \
    'https://api.cloudways.com/api/v1/operation/'$ops'' > operation.json

    while [ "$(jq -r '.operation | .is_completed' operation.json)" = "0" ]; do
        _note "The operation: $(jq -r '.operation | .id' operation.json) is still running."
        _note "Sleeping for 10s..."
        sleep 10
        curl -s -X GET --header 'Accept: application/json' \
        --header 'Authorization: Bearer '$accesstoken'' \
        'https://api.cloudways.com/api/v1/operation/'$ops'' > operation.json
    done

    echo "Operation:   $(jq -r '.operation | .id' operation.json)"
    echo "Server:      $(jq -r '.operation | .server_id' operation.json)"
    echo "Application: $(jq -r '.operation | .app_id' operation.json)"
    echo "Status:      $(jq -r '.operation | .status' operation.json)"

    echo "$(jq -r '.operation | .server_id' operation.json): $(jq -r '.operation | .app_id' operation.json)" >> completed.txt
    mv operation.json /tmp/operation_$ops.json

    _note "Sleeping for 5s to respect API rate limits."
    sleep 5
done

_success "XML-RPC disabled successfully on all WordPress apps for Server ID $server."
