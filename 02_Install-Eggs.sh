#!/bin/bash

#Added Penguins Eggs back to preset, should work now excludes is disabled.
#Nope put back due to needing the deb as the one I made isn't working with mkisofs
#Yep was lack of isolinux depends etc in the penguins eggs package.
#Nope Still dodgy
sudo ./nodesource_setup.sh

sudo apt -y install nodejs
sudo apt install -y --fix-broken
sudo dpkg -i ./penguins-eggs*amd64.deb
sudo apt install -y --fix-broken

#This fixes the error at the end of Calamares
sudo apt -y install language-selector-common 

#Manual Jobs, to fix Calamares Theme and grub, may not work or be needed as the grub updates require eggs to do the heavy lifting to get the kernel version.
MAINDIR=$PWD
#sudo mkdir -p /usr/lib/penguins-eggs
#sudo cp -rf $MAINDIR/CalamaresTheme/* /usr/lib/penguins-eggs/
