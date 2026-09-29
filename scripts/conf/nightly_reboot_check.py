#!/usr/bin/env python3

import os

import subprocess

import datetime



# Configuration

LOG_FILE = "/var/log/nightly_reboot.log"

REBOOT_REQUIRED_FILE = "/var/run/reboot-required"



def log_message(message):

    timestamp = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")

    formatted_msg = f"{timestamp} - {message}\n"

    with open(LOG_FILE, "a") as f:

        f.write(formatted_msg)



def check_reboot():

    log_message("--- Starting weekly reboot check ---")

    reboot_needed = False



    # 1. Check for the standard Ubuntu update file

    if os.path.exists(REBOOT_REQUIRED_FILE):

        log_message("Reboot required based on /var/run/reboot-required.")

        reboot_needed = True

    else:

        # 2. Use needrestart to check for kernel/library updates

        try:

            # We run needrestart and check the output for the specific string

            result = subprocess.run(['needrestart', '-r', 'i'], capture_output=True, text=True)

            if "System is asking for a reboot" in result.stdout:

                log_message("Reboot required based on needrestart output.")

                reboot_needed = True

            else:

                log_message("No reboot required.")

        except FileNotFoundError:

            log_message("Error: 'needrestart' utility not found.")



    # 3. Perform the reboot if needed

    if reboot_needed:

        log_message("Scheduling reboot in 5 minutes.")

        try:

            # shutdown -r +5 schedules the reboot

            subprocess.run(['/sbin/shutdown', '-r', '+5', "Automated nightly reboot due to system updates."], check=True)

            log_message("Reboot command executed.")

        except subprocess.CalledProcessError as e:

            log_message(f"Error: Failed to execute shutdown command: {e}")



    log_message("--- Nightly reboot check finished ---")



if __name__ == "__main__":

    # Ensure script runs as root for shutdown permissions

    if os.geteuid() != 0:

        print("This script must be run as root (use sudo).")

    else:

        check_reboot()
