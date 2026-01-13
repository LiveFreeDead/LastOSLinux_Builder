#!/bin/bash

#This fixes the error at the end of Calamares
sudo apt -y install language-selector-common 

chmod +x penguins-eggs-*-x86_64.AppImage
sudo cp -f penguins-eggs-*-x86_64.AppImage /usr/local/bin/eggs
#sudo eggs setup
yes | sudo eggs setup install
