#!/bin/bash

# Install and set up the LL Store (keeps sudo alive internally via -KeepSudo) Don't use keep sudo here as the old one wont have lastos-users group
env GDK_BACKEND=x11 "LL_Store/llstore" -setup

# Fix permissions on the LLStore install directory
#sudo chmod -R 777 /opt/LastOS/LLStore
