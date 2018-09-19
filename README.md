# gpg-managing-container

## What's this?

This is (almost) secure environment to generate and manage your GPG master key on your computer.
A USB stick is used to store your credentials. And the partition is encrypted with LUKS, whose key will be stored in your computer, encrypted with your passphrase.

## Requirement

- A secure Arch Linux machine (with encrypted root, recommended), called host machine
- New USB stick, used entirely by LUKS encrypted fs to store your master key.

## The way

1. Invoke the system-wide update with `sudo pacman -Syu` and then reboot.
1. Do the basic setup of `gnupg` on your host machine.
1. Run `./run.sh` and follow the guide. A USB stick is required to continue.
1. It opens a shell in a (almost) secure container, which is separated from the host and the Internet.
1. You can create GPG master keys and subkeys in the container. The files in the `~` will be stored safely in the USB stick.
1. Also you can use any file you like, if it was copied to the `files` directory.
1. If you want to apply your new subkeys (not master) to the host, run `apply-subkey` in the container.
1. If you want to copy your revocation certificate to your host's `~/.gnupg/XXXXX.gpg-revocation-certificate`, run `export-revocation-certificate`.
1. Press Ctrl-D to exit from the container.
1. If you want to manage the same key later, use the same USB key, and automatically the LUKS key file in your host's `/opt/gpg-maintaining-container` will be used to decrypt it.

## Moving the host LUKS key

1. Just copy `/opt/gpg-managing-container`. Do not forget to set the right permissions.

## Todo

- Yubikey support
