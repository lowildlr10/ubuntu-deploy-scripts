#!/bin/bash

# setup.sh
# Author: Lowil Ray Delos Reyes

set -e

while true; do
  echo "-----------------------------------------------------------------------------"
  echo "                   Server Deployment & Maintenance Toolkit                   "
  echo "-----------------------------------------------------------------------------"
  echo ""
  echo "Choose an action:"
  echo "1) Run server_setup.sh  ---------------------  (Initial system setup)"
  echo ""
  echo "2) Run deploy.sh  ---------------------------  (Deploy a new app)"
  echo ""
  echo "3) Run supervisor_setup.sh  -----------------  (Configure queue workers)"
  echo ""
  echo "4) Run github_action_setup.sh  --------------  (Set up GitHub Actions runner)"
  echo "   └─ ⚠ You must be logged in as the Linux user who owns the deployed app"
  echo ""
  echo "5) Run undeploy.sh  -------------------------  (Remove a deployed app)"
  echo ""
  echo "6) Run server_purge.sh  ---------------------  (Full system purge)"
  echo ""
  echo "7) Exit"
  echo ""

  read -rp "Enter your choice [1-6]: " ACTION

  case $ACTION in
    1)
      echo "Running server_setup.sh..."
      chmod +x server_setup.sh
      sudo ./server_setup.sh
      break
      ;;
    2)
      echo "Running deploy.sh..."
      chmod +x deploy.sh
      sudo ./deploy.sh
      break
      ;;
    3)
      echo "Running supervisor_setup.sh..."
      chmod +x supervisor_setup.sh
      sudo ./supervisor_setup.sh
      break
      ;;
	4)
      echo "Running github_action_setup.sh..."
      chmod +x github-action-script/github_action_setup.sh
      ./github-action-script/github_action_setup.sh
      break
      ;;
    5)
      echo "Running undeploy.sh..."
      chmod +x undeploy.sh
      sudo ./undeploy.sh
      break
      ;;
    6)
      echo "Running server_purge.sh..."
      chmod +x server_purge.sh
      sudo ./server_purge.sh
      break
      ;;
    7)
      echo "Exiting."
      break
      ;;
    *)
      echo ""
      echo "❌ Invalid option. Please choose a number from 1 to 6."
      echo ""
      ;;
  esac
done

echo ""