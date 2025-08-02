#!/bin/bash
# Purpose: Debug server load with enhanced metrics

set -e

# Colors
green=$(tput setaf 76)
red=$(tput setaf 1)
blue=$(tput setaf 38)
reset=$(tput sgr0)

success() { echo -e "${green}✔ $1${reset}"; }
error() { echo -e "${red}✖ $1${reset}"; }
info() { echo -e "${blue}➤ $1${reset}"; }

HOMEDIR="/home/master/applications"
cd "$HOMEDIR" || exit 1

date_to_check=$1
time_in_UTC=$2
interval_in_mins=$3
iv=$4

# SYSTEM METRICS CHECK
check_system_metrics() {
    info "CPU Load (1/5/15 min average)"
    uptime | awk -F'load average:' '{print "Load Averages:" $2}'
    echo

    info "Memory Usage"
    free -m | awk 'NR==1 || /Mem/ {printf "%s: %sMB used / %sMB total\n", $1, $3, $2}'
    echo

    info "Disk Usage (main partition)"
    df -h / | awk 'NR==1 || NR==2'
    echo

    info "Top Resource-Consuming Processes"
    ps -eo pid,cmd,%cpu,%mem --sort=-%cpu | head -n 6 | column -t
    echo

    info "Disk I/O Wait (if >5%, disk may be overloaded)"
    if command -v iostat >/dev/null; then
        iostat -c 1 3 | awk '/^avg-cpu/ {getline; print "iowait:", $4"%"}'
    else
        echo "⚠️ iostat not found. Run: sudo apt install sysstat"
    fi
    echo

    info "Essential Service Statuses"

    {
        echo "$(tput bold)$(tput setaf 1)Nginx:$(tput sgr0)"
        systemctl status nginx --no-pager | awk '/Active/ {$1="";print $0}'

        echo "$(tput bold)$(tput setaf 1)Varnish:$(tput sgr0)"
        systemctl status varnish --no-pager | awk '/Active/ {$1="";print $0}'

        echo "$(tput bold)$(tput setaf 1)Apache:$(tput sgr0)"
        systemctl status apache2 --no-pager | awk '/Active/ {$1="";print $0}'

        echo "$(tput bold)$(tput setaf 1)PHP-FPM:$(tput sgr0)"
        systemctl status $(php -v | awk '{print "php"substr($2,1,3)"-fpm";exit}') --no-pager | awk '/Active/ {$1="";print $0}'

        echo "$(tput bold)$(tput setaf 1)MySQL/MariaDB:$(tput sgr0)"
        systemctl status mysql --no-pager | awk '/Active/ {$1="";print $0}'

        echo "$(tput bold)$(tput setaf 1)Memcached:$(tput sgr0)"
        systemctl status memcached --no-pager | awk '/Active/ {$1="";print $0}'

        echo "$(tput bold)$(tput setaf 1)Redis:$(tput sgr0)"
        systemctl status redis-server --no-pager 2>/dev/null | awk '/Active/ {$1="";print $0}'
    }
    echo
}

# GET STATS MODE
get_stats() {
    dd=$(echo "$date_to_check" | cut -d '/' -f1)
    mm=$(echo "$date_to_check" | cut -d '/' -f2)
    yy=$(echo "$date_to_check" | cut -d '/' -f3)
    date_new="$mm/$dd/$yy"

    time_a="$date_to_check:$time_in_UTC"
    time_b=$(date --date="$date_new $time_in_UTC UTC $interval_in_mins $iv" -u +'%d/%m/%Y:%H:%M')

    if [[ "$interval_in_mins" == -* ]]; then
        from_param=$time_b
        until_param=$time_a
    else
        from_param=$time_a
        until_param=$time_b
    fi

    echo -e "\n${blue}Analyzing App Load From $from_param To $until_param${reset}\n"

    top_apps=$(for app_dir in "$HOMEDIR"/*; do
        [[ -f "$app_dir/conf/server.nginx" ]] || continue
        appname=$(basename "$app_dir")
        count=$(sudo apm -s "$appname" traffic -f "$from_param" -u "$until_param" | grep -Po "\d..\",\d*" | cut -d ',' -f2 | head -n1)
        echo "$appname:$count"
    done | sort -t ":" -k2 -nr | cut -d ":" -f1 | head -n 5)

    for A in $top_apps; do
        echo -e "\n${green}App: $A${reset}"
        cat "$HOMEDIR/$A/conf/server.nginx" | awk '{print $NF}' | head -n1
        sudo apm -s "$A" traffic -n5 -f "$from_param" -u "$until_param"
        sudo apm -s "$A" mysql -n5 -f "$from_param" -u "$until_param"
        sudo apm -s "$A" php -n5 --slow_pages -f "$from_param" -u "$until_param"
    done
}

# INTERACTIVE MODE
run_interactive() {
    read -p 'Enter duration (e.g. 30m, 1h, 1d): ' dur
    info "Fetching logs for the last $dur ..."

    top_apps=$(for app_dir in "$HOMEDIR"/*; do
        [[ -f "$app_dir/conf/server.nginx" ]] || continue
        appname=$(basename "$app_dir")
        count=$(sudo apm -s "$appname" traffic --statuses -l "$dur" -j | grep -Po "\d..\",\d*" | cut -d ',' -f2 | head -n1)
        echo "$appname:$count"
    done | sort -t ":" -k2 -nr | cut -d ":" -f1 | head -n 5)

    for A in $top_apps; do
        echo -e "\n${green}App: $A${reset}"
        cat "$HOMEDIR/$A/conf/server.nginx" | awk '{print $NF}' | head -n1
        sudo apm -s "$A" traffic -l "$dur" -n5
        sudo apm -s "$A" mysql -l "$dur" -n5
        sudo apm -s "$A" php --slow_pages -l "$dur" -n5

        slow_plugins=$(grep -ai 'wp-content/plugins' "$HOMEDIR/$A/logs/php-app.slow.log" 2>/dev/null | cut -d " " -f1 --complement | cut -d '/' -f8 | sort | uniq -c | sort -nr)
        if [ -n "$slow_plugins" ]; then
            echo -e "${red}--- Slow Plugins ---${reset}"
            echo "$slow_plugins"
        fi

        echo -e "${red}--- Slowlog entries by top PIDs ---${reset}"
        access_log="$HOMEDIR/$A/logs/php-app.access.log"
        slow_log="$HOMEDIR/$A/logs/php-app.slow.log"

        if [[ -f "$access_log" && -f "$slow_log" ]]; then
            for PID in $(awk '{print}' "$access_log" | sort -nbrk 12,12 | head | awk '{print $11}'); do
                awk "/pid $PID/,/^$/" "$slow_log"
            done
        else
            echo "⚠️ Access or slow log not found for $A"
        fi
    done
}

# MAIN
info "Starting Server Load Analysis..."
check_system_metrics

if [[ $# -lt 4 ]]; then
    run_interactive
else
    [[ -z $iv ]] && iv="min"
    get_stats
fi

success "Load debug completed."
