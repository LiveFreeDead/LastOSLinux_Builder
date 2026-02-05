#!/bin/bash

#Set Builder Flag
echo "Builder Running" > /tmp/LastOSLinux-Builder

#Install LLStore and apps
CurDir=$PWD

#cd LLStore
#./setup.sh
#cd $CurDir

#Get Best Terminal
terms=(gnome-terminal konsole x-terminal-emulator xterm xfce4-terminal)
for t in ${terms[*]}
do
    if [ $(command -v $t) ]
    then
        OSTERM=$t
        break
    fi
done

#Use some cached files if available
sudo cp -rf Cache/. /var/cache/apt/archives
sudo cp -rf cache/. /var/cache/apt/archives

#Apply Updates first.
sudo apt update && sudo apt upgrade -y
sudo apt autoremove -y

#Wine downloaded MSI's
if [ -f wine/wine-gecko-2.47.4-x86.msi ]; then
    mkdir -p $HOME/.cache/wine
    cp -r "wine/". "$HOME/.cache/wine"
    sudo mkdir -p /etc/skel/.cache/wine
    sudo cp -r "wine/". "/etc/skel/.cache/wine/"
fi

#Google Chrome
cp google-chrome-stable_current_amd64.deb /tmp/

#Install Store
env GDK_BACKEND=x11 ./LL_Store/llstore -setup -KeepSudo

#Fix Permissions
sudo chmod -R 777 /LastOS/LLStore

#Replace from another file, to correct path
sed "s!\/home/lastos/LastOSLinux-RC5/LLAppsInstalls!$PWD/LLAppsInstalls!g" LLL_Store_Linux_Manual_Locations_Orig.ini > LLL_Store_Linux_Manual_Locations.ini
cp LLL_Store_Linux_Manual_Locations.ini /LastOS/LLStore

cp LLL_Settings.ini /LastOS/LLStore

##As Icons crash things, do them first
/LastOS/LLStore/llstore -i -q -KeepSudo -p $CurDir/Icons_Preset.ini

##As Fonts crash things, do them first too
/LastOS/LLStore/llstore -i -q -KeepSudo -p $CurDir/Fonts_Preset.ini

#Do VLC and Java fonts
sudo apt -y install fonts-freefont-ttf fonts-dejavu-extra fonts-ipafont-gothic fonts-ipafont-mincho fonts-wqy-microhei fonts-wqy-zenhei fonts-indic libsdl-ttf2.0-0 libsdl2-ttf-2.0-0

##Microsoft Fonts (EULA bypassed)
echo ttf-mscorefonts-installer msttcorefonts/accepted-mscorefonts-eula select true | sudo debconf-set-selections
echo fonts-wine msttcorefonts/accepted-mscorefonts-eula select true | sudo debconf-set-selections

sudo apt -y install ttf-mscorefonts-installer

#Do Font Cache at the end, doesn't matter if it crashes at this stage
#I have bad font(s) I need to find and remove!
fc-cache -f -v
#Not sure sudo is needed
sudo fc-cache -f -v

#Below 2 are too big IMO to include out of the box, I am including the fonts above so they don't crash in LastOSLinux
##These two cause the LLStore to crash so have been move out of the internel scripts.
#sudo apt -y install default-jre
#sudo apt -y install vlc

#Numlock On
sudo apt -y install numlockx
numlockx on

#I think this downloads a flatpak repo, moving it to the firstlogon.sh script
##FlatPaks - Integrated System Wide
#$OSTERM -e "flatpak install --system -y --noninteractive flathub it.mijorus.gearlever"


#Remove Firefox
sudo apt -y remove firefox firefox-locale-en

#Change default to Chrome from Firefox and add LLStore
gsettings set org.cinnamon favorite-apps "['google-chrome.desktop', 'mintinstall.desktop', 'cinnamon-settings.desktop', 'llstore.desktop', 'org.gnome.Terminal.desktop', 'nemo.desktop']"

#Install Apps from Preset
/LastOS/LLStore/llstore -i -p $CurDir/LastOSLinux_Preset.ini
#> $HOME/Desktop/LLStore-Results.txt
#I removed quit from above after -i
#-q 

#Quit Sudo Terminal
echo "Done" > /tmp/LLSudoDone

cp LLL_Settings-Overlay.ini /LastOS/LLStore/LLL_Settings.ini

#Clean Debugging desktop stuff
rm -rf "$HOME/Desktop/LLStore Debug-Logs"


#Panel to Center (Instead of Menu etc being far left)
#dconf write /org/cinnamon/enabled-applets "['panel1:center:0:menu@cinnamon.org:0', 'panel1:center:1:separator@cinnamon.org:1', 'panel1:center:2:grouped-window-list@cinnamon.org:2', 'panel1:right:0:systray@cinnamon.org:3', 'panel1:right:1:xapp-status@cinnamon.org:4', 'panel1:right:2:notifications@cinnamon.org:5', 'panel1:right:3:printers@cinnamon.org:6', 'panel1:right:4:removable-drives@cinnamon.org:7', 'panel1:right:5:keyboard@cinnamon.org:8', 'panel1:right:6:favorites@cinnamon.org:9', 'panel1:right:7:network@cinnamon.org:10', 'panel1:right:8:sound@cinnamon.org:11', 'panel1:right:9:power@cinnamon.org:12', 'panel1:right:10:calendar@cinnamon.org:13', 'panel1:right:11:cornerbar@cinnamon.org:14']"

#Make Root have my preferences in view modes
sudo gsettings set org.nemo.preferences default-folder-viewer 'compact-view'

#Set show hidden files default for Root
sudo gsettings set org.nemo.preferences show-hidden-files true

#Install Themes and fixes in Debian
sudo ./Debian_Fixes.sh


##Setup Portable Eggs
#chmod +x penguins-eggs-*.AppImage
#sudo cp -f penguins-eggs-*.AppImage /usr/local/bin/eggs
#sudo eggs setup
#sudo eggs setup --install


#Remove Builder Flag
rm -f /tmp/LastOSLinux-Builder
