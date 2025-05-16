#!/bin/bash
export LC_ALL=C
# this script needs to be symlinked from /etc/NetworkManager/dispatcher.d/
# owner needs to be root:root and given 744 permissions

enable_disable_wifi ()
{
    result=$(nmcli dev | grep "ethernet" | grep -w "connected")
    if [ -n "$result" ]; then
        nmcli radio wifi off
	sudo -u jex DISPLAY=:0 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus notify-send 'Ethernet detected. Wifi disconnected.'

    else
        nmcli radio wifi on
	sudo -u jex DISPLAY=:0 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus notify-send 'Ethernet disconnected. Wifi enabled.'
    fi
}

if [ "$2" = "up" ]; then
    enable_disable_wifi
fi

if [ "$2" = "down" ]; then
    enable_disable_wifi
fi
