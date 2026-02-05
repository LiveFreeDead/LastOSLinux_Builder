#!/bin/bash

MAINDIR=$PWD

#Hill Mint Updater, so it doesn't trigger mid build
killall mintUpdate
killall mintreport-tray

#Set hide hidden files default
gsettings set org.nemo.preferences show-hidden-files false

#Make it use Win 10 Icons not the theme ones
gsettings set org.cinnamon.desktop.interface icon-theme "Windows-10-master"
sudo gsettings set org.cinnamon.desktop.interface icon-theme "Windows-10-master"
gsettings set org.gnome.desktop.interface icon-theme "Windows-10-master"
sudo gsettings set org.gnome.desktop.interface icon-theme "Windows-10-master"
gsettings set org.mate.interface icon-theme "Windows-10-master"
sudo gsettings set org.mate.interface icon-theme "Windows-10-master"

#Other Debian Fixes
#Do Tasks For Detected OS
. /etc/os-release

echo "OS ID: $ID"

case $ID in
  debian)
    cp DebianFixes/LastOS.Gamers.Runtimes.Lite_v23.04_x64+x86_ssApp.apz /LastOS/WindowsApps/
    ;;
    
  *)
    echo "Not Debian, skipped"
    ;;
esac

#Below if not required as I install apt -y install language-selector-common in the eggs setup script.
##Manual Jobs, to fix Calamares Errors.
#sudo cp -f $MAINDIR/aaJobs-Manual/*.sh /usr/lib/penguins-eggs/conf/distros/noble/calamares/libexec

echo "Running Clean up from" "$MAINDIR/LLAppsInstalls/"

/LastOS/LLStore/llstore -i -q $MAINDIR/LLAppsInstalls/LastOSLinux.Clean.Build_*_x64+x86_LLApp.tar


echo "Running Build from" "$MAINDIR/LLAppsInstalls/"

/LastOS/LLStore/llstore -i -q $MAINDIR/LLAppsInstalls/LastOSLinux.Build.ISO_*_x64+x86_LLApp.tar
nemo $HOME &
