#!/bin/bash

# Install and set up the LL Store (keeps sudo alive internally via -KeepSudo)
env GDK_BACKEND=x11 "LL_Store/llstore" -setup -KeepSudo

# Fix permissions on the LLStore install directory
#sudo chmod -R 777 /opt/LastOS/LLStore
