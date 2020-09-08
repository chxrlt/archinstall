#!/bin/bash
# ------------------------------------------------
# Config
# ------------------------------------------------
vconsole_keymap="uk"
xorg_keymap="gb"
ucode="intel" # amd for AMD machines
bios="bios"

hostname="arch"
timezone="Europe/London"
lang="en_US"

pascstrap_extras="vim"

user_packages="firefox lightdm lightdm-gtk-greeter pulseaudio xfce4"
user_services=(lightdm.service)
# ------------------------------------------------

log_info() {
    prefix="\e[0m[\e[1m\e[90m*INFO*\e[0m]"
    echo -e "$prefix $1"
}

log_success() {
    prefix="\e[0m[\e[1m\e[92m*SUCCESS*\e[0m]"
    echo -e "$prefix $1"
}

log_warn() {
    prefix="\e[0m[\e[1m\e[93m*WARN*\e[0m]"
    echo -e "$prefix $1"
}

log_error() {
    prefix="\e[0m[\e[1m\e[91m*ERROR*\e[0m]"
    echo -e "$prefix $1"
}

install() {
    log_info "Loading keymap $vconsole_keymap"
    loadkeys $vconsole_keymap

    # Connect to the internet
    if ping -c 1 archlinux.org &> /dev/null; then
        log_success "The internet seems to be working!"
    else
        log_error "Could not connect to the internet!"
        exit 1
    fi

    # Update the system clock
    log_info "Running timedatectl to update the system clock"
    #timedatectl set-ntp true

    # Partitioning
    log_info "Entering partition()"
    partition

    # Install base packages with pacstrap
    log_info "Opening up /etc/pacman.d/mirrorlist for manual editing"
    vim /etc/pacman.d/mirrorlist

    log_info "Running pacstrap to install base packages"
    pacstrap /mnt base linux linux-firmware dhcpcd python $pascstrap_extras

    # Generate an fstab file
    log_info "Generating an fstab file"
    genfstab -U /mnt >> /mnt/etc/fstab

    # Enter a chroot
    log_info "Entering a chroot, chrooting in and running installer"
    cp install.sh /mnt/install.sh
    arch-chroot /mnt bash install.sh chroot_install
}

chroot_install() {
    # The rest of the install continues in a chroot up until
    # creating users and installing user packages

    log_success "Successfully entered chroot!"

    # Set the timezone
    log_info "Setting the timezone and running hwclock --systohc"
    hwclock --systohc

    # Generate locales
    log_info "Opening up /etc/locale.gen for manual editing"
    sleep 2
    vim /etc/locale.gen

    log_info "Generating locales with locale-gen"
    locale-gen
    if [ $? -eq 0 ]; then
        log_success "Successfully (re)generated locales" 
    else
        info_error "Failed to generate locales"
        exit 1
    fi

    log_info "Generating /etc/locale.conf"
    echo "LANG=$lang.UTF-8" > /etc/locale.conf

    # Keyboard layout
    log_info "Making keyboard changes persistent in /etc/vconsole.conf"
    echo "KEYMAP=$vconsole_keymap" > /etc/vconsole.conf

    # Setup the hostname
    log_info "Creating /etc/hostname and /etc/hosts file"
    echo "$hostname" > /etc/hostname

    hostsfile="
127.0.0.1   localhost
::1         localhost
127.0.1.1   $hostname.localdomain   $hostname
    "
    echo "$hostsfile" >> /etc/hosts

    # Set up a password for the root account
    log_info "Setting up root password. Please enter a new password for root"
    passwd

    # Install GRUB
    log_info "Installing GRUB bootloader"
    pacman -S --noconfirm dosfstools os-prober grub $ucode-ucode

    if [ "$bios" == "efi" ]; then
        # UEFI install
        read -p "Which partition is your EFI partition? " efipar
        mkdir /boot/efi
        mount $efipar /boot/efi

        if [ $? -eq 0 ]; then
            log_success "Successfully mounted $efipar to /boot/efi" 
        else
            info_error "Failed to mount $efipar to /boot/efi"
            exit 1
        fi
    fi

    log_info "Running grub-install and grub-mkconfig"
    if [ "$bios" == "efi" ]; then
        # UEFI install
        log_info "Installing GRUB (UEFI) to /boot/efi"
        grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=grub --recheck
    else
        # BIOS/MBR install
        log_info "Installing GRUB (BIOS/MBR)"
        read -p "Which disk is your root partition located on? " mbrdisk
        grub-install $mbrdisk
    fi

    grub-mkconfig -o /boot/grub/grub.cfg

    # Enable dhcpcd for networking when we reboot
    systemctl enable dhcpcd

    # Run the post_install script
    source ./install.sh && post_install
}

post_install() {
    # Post installation for the installer

    # Install sudo, and the xorg server (for later on)
    pacman -S sudo xorg

    # Create a new user account
    read -p "Enter your username: " username
    log_info "Creating a new user account for $username"

    useradd -m -G wheel $username
    if [ $? -eq 0 ] then;
        log_success "Created a new user account for username"
    else
        log_error "Failed to create a user account for $username"
        exit 1
    fi

    # Add the user to the sudoers file
	log_warn "Adding $username to /etc/sudoers, if this goes wrong you will need to edit manually"
    echo "$username	ALL=(ALL) ALL" >> /etc/sudoers

	# Copy the install script to the users home directory
	cp install.sh /home/$username/install.sh

	# Run the user install script as the newly created user
	log_info "Running userinstall script as $username using sudo"
	sudo -u $username -H /bin/bash -c "source /home/$username/install.sh && user_install"
}

user_install() {
	# Install all the user packages
	user=$(whoami)

	# Sanity check to ensure we're not running as root
	if [ "$user" == "root" ]; then
		log_error "User install was ran as root! Make sure this script is *only* ran as the newly created user!"
		exit 1
	fi

	log_info "Installing packages for user $user"
	pacman -S $user_packages

	# Start all the services
	for service in ${user_services[*]}; do
		log_info "Enabling systemd service $service"

		if [ "$service" == "pulseaudio" ]; then
			# PulseAudio needs to be ran a user service
			systemctl --user enable pulseaudio.service
		else
			systemctl enable $service
		fi

		# Check if the service was enabled
		[ $? -eq 0 ] && log_success "Successfully enabled $service" || log_error "Failed to enable service $service"
	done
}

partition() {
    clear
    log_info "To list all, the disks type \"lsdisks\". To partition a disk, type \"pardisk\""

    exit_wizard="0"
    while [ "$exit_wizard" != "1" ]; do
        read -p "? " prompt

        case $prompt in
            lsdisks) fdisk -l;;
            pardisk) 
                read -p "Which disk to partition? " disk

                log_info "Running cfdisk on $disk"
                cfdisk $disk

                log_info "Finished running cfdisk, resuming partition process"
                read -p  "Which partition is your root partition? " rootpar
                log_info "Making root partition ($rootpar), ext4 on $disk"

                mkfs.ext4 $rootpar
                log_success "Made a root partition ($rootpar), ext4 on $disk"

                # Swap partition is optional
                read -p "Do you want to make a swap partition? " makeswap
                case $makeswap in
                    [Yy]*)
                        read -p "Which partition is your swap partition? " swappar
                        mkswap $swappar

                        log_success "Made a swap partition ($swappar) on $disk"
                        swapon $swappar
                        break;;
                    [Nn]*)
                        log_info "No need to make a swap partition, continuing.."
                        break;;
                esac

                log_info "Mounting $rootpar to /mnt"
                mount $rootpar /mnt

                log_success "Finished. To exit the wizard, type \"exit\"";;

            exit   ) exit_wizard="1";;
        esac
    done
}