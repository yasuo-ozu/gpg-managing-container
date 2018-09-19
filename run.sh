#!/bin/bash

ask() {
	echo ""
	echo -n "Is that OK? [Y/n] : "
	read  SIGN

	if [ -n "$SIGN" -a ! "$SIGN" = Y -a ! "$SIGN" = y ]; then
		echo "Cancelled."
		exit 1
	fi
	return 0
}

create_device_list() {
	MOUNTED=`mount | sed -e 's/^\([^ ]*\) on .*$/\1/'`
	DISKS=
	for DISK in `lsblk -nlp -o NAME,TYPE | awk '{if($2=="disk"||$2~/^raid/) print $1}' | tr '\n' ' '`; do
		if echo "$MOUNTED" | grep -q "$DISK"; then
			:
		elif echo "$DISK" | grep -q "fd"; then
			:
		else
			if [ -z "$DISKS" ]; then DISKS="$DISK"
			else DISKS=`/bin/echo -e "${DISKS}\n$DISK"`
			fi
		fi
	done
	echo "$DISKS" | sort | uniq
	unset DISKS
	unset MOUNTED
	return 0
}

errorexit() {
	echo "$1 error" 1>&2
	exit 1
}

export TRAP_CMD=":"
trap_receiver() {
	bash -c "$TRAP_CMD"
	TRAP_CMD=
	exit 1
}
trap "trap_receiver" EXIT

# Check environment

if [ -z "$ORIG_USER" ]; then
	if [ "$USER" = "root" ]; then
		echo "Please run this script as normal user (not root)." 1>&2
		exit 1
	fi
	export ORIG_USER="$USER"
	export ORIG_UID=`id -u`
	export ORIG_GID=`id -g`
	sudo -E "$0" "$@"
	exit "$?"
fi

cat /etc/os-release | grep -q "Arch Linux" || (
	echo "This script is for Arch Linux." 1>&2
	exit 1
)

DEPS=(mktemp parted pacman wipefs cryptsetup systemd-nspawn mknod chroot)

NOT_INSTALLED=
for DEP in "$DEPS"; do
	which "$DEP" &> /dev/null || (
		NOT_INSTALLED=`echo "$NOT_INSTALLED'$DEP' "`
	)
done
if [ ! -z "$NOT_INSTALLED" ]; then
	echo "command ${NOT_INSTALLED}is required, but not installed." 1>&2
	exit 1
fi

# Main proceedure

PACKAGES="coreutils findutils util-linux shadow sed bash gnupg"
PACKAGE_DIR="/opt/gpg-maintaining-container"

echo "Please prepare a USB stick which stores credentials."
echo "Ensure that the USB stick is not attached to this PC."
ask

DEVICE_LIST_BEFORE="`create_device_list`"
echo "$DEVICE_LIST_BEFORE"
echo "Insert the USB stick now."
while : ; do
	ask
	sleep 1

	DEVICE_LIST_AFTER="`create_device_list`"

	DIFFRESULT=`diff <(echo "$DEVICE_LIST_BEFORE") <(echo "$DEVICE_LIST_AFTER")`
	DEVICE=`echo "$DIFFRESULT" | sed -ne '/^>/p' | sed -e 's/^> \(.*\)$/\1/'`
	DEVUCE_COUNT=`echo "$DEVICE" | wc -l`

	if [ "$DEVUCE_COUNT" = 0 ]; then
		echo "No device is recognized. Is the USB stick really attached and unmounted?"
		echo "Try again."
	elif [ "$DEVUCE_COUNT" -gt 1 ]; then
		echo "Too many devuces detected. Try again."
	else
		echo "Ok."
		break
	fi
done

echo "Selected devuce is $DEVICE."

TMPDIR=`mktemp -d`
TMP_KEYFILE="$TMPDIR/keyfile"
ROOT="$TMPDIR/root"
LUKS_NAME="gpg-devuce"
DEV_FS="/dev/mapper/$LUKS_NAME"
SERIAL=`lsblk --ascii -lo NAME,SERIAL "$DEVICE" | sed -e 1d | head -n 1 | sed -e 's/^.* \([^ ]*\)$/\1/'`
KEYFILE="$PACKAGE_DIR/$SERIAL"
TRAP_CMD="rm -rf \"$TMPDIR\";$TRAP_CMD"
WORKING_DIR="`pwd`"

echo "Keyfile is $KEYFILE"
if [ -e "$KEYFILE" ]; then
	echo "Keyfile found."
	while :; do
		read -sp "Password for keyfile: " PASSWORD
		if echo "$PASSWORD" | gpg --batch --passphrase-fd 0 --output "$TMP_KEYFILE" --decrypt "$KEYFILE" ; then
			TRAP_CMD="rm \"$TMP_KEYFILE\";$TRAP_CMD"
			echo "OK."
			break
		else
			echo ""
			echo "Cannot decrypt your keyfile. Try again."
			continue
		fi
	done
	echo "Keyfile is unlocked."
else
	read -sp "Password for keyfile:" PASSWORD
	echo ""
	if [ -z "$PASSWORD" ]; then
		echo "Password should be used to encrypt keyfile." 1>&2
		exit 1
	fi
	read -sp "Password(again):" PASSWORD2
	echo ""
	if [ ! "$PASSWORD" = "$PASSWORD2" ]; then
		echo "Passwords mismatch" 1>&2
		exit 1
	fi

	mkdir -m 0700 -p "$PACKAGE_DIR"
	echo "All data in $DEVICE is destroyed."
	ask

	echo "Creating new fs and LUKS encrypted partition..."

	mkdir -p "$ROOT"

	echo "Creating keyfile. Move mouse cursor if it takes long..."
	dd bs=512 count=4 if=/dev/random of=$TMP_KEYFILE 2>/dev/null || errorexit "creating key"

	echo "Done. Creating fs."
	wipefs "$DEVICE" || errorexit "wipefs"
	parted -s -a cylinder "$DEVICE" -- mklabel msdos mkpart primary 1 -1 > /dev/null || errorexit "parted"
fi

DEV_LUKS=`LANG=C fdisk -l -o Device "$DEVICE" | tail -n 1`
if [ ! -e "$KEYFILE" ]; then
	echo "Creating LUKS partition..."
	cryptsetup luksFormat "$DEV_LUKS" --key-file=$TMP_KEYFILE || errorexit "cryptsetup"
fi

echo "Unlocking LUKS partition..."
cryptsetup luksOpen "$DEV_LUKS" "$LUKS_NAME" --key-file=$TMP_KEYFILE || errorexit "cryptsetup luksOpen"
TRAP_CMD="cryptsetup close \"$LUKS_NAME\";$TRAP_CMD"

if [ ! -e "$KEYFILE" ]; then
	echo "Creating ext4 fs..."
	mkfs.ext4 "$DEV_FS" || errorexit "mkfs.ext4"
fi

echo "Mounting fs..."
ROOT_HOME="$ROOT/home/$ORIG_USER"

echo "Installing system in container..."
mkdir -m 0755 -p "$ROOT"/var/{cache/pacman/pkg,lib/pacman,log} "$ROOT"/{dev,run,etc}
mkdir -m 1777 -p "$ROOT"/tmp
mkdir -m 0555 -p "$ROOT"/{sys,proc}
cd "$ROOT/dev"
mknod -m 0666 null c 1 3
mknod -m 0666 zero c 1 5
mknod -m 0666 random c 1 8
mknod -m 0666 urandom c 1 9
pacman -r "$ROOT" -Sy $PACKAGES --cachedir="$ROOT/var/cache/pacman/pkg" --noconfirm || errorexit "pacman"
cat > "$ROOT"/bin/apply-subkey <<'EOF'
#!/bin/bash
echo -n "Enter your name or e-mail address: "
read NAME
echo ""
GPG_RES=`LANG=C gpg --list-keys --with-colons "$NAME" 2>&/dev/null | grep -e "^pub" -A 1 | tail -n 1 |  sed -e 's/^.*:\([^:]*\):$/\1/'`
if [ -z "$GPG_RES" ]; then
	echo "I cannot find your master key."
	exit 1
fi
echo -n "Your master key is $GPG_RES, right [Y/n]? "
read SIGN
echo ""
if [ ! "$SIGN" = "y" -a ! "$SIGN" = "Y" -a -n "$SIGN" ]; then
	echo "Exit."
	exit 1
fi
gpg --output /exported-subkeys --export-secret-subkeys $GPG_RES || (
	echo "Export error."
	exit 1
)
echo "Finished."
exit 0
EOF
cat > "$ROOT"/bin/export-revocation-certificate <<'EOF'
#!/bin/bash
echo -n "Enter your name or e-mail address: "
read NAME
echo ""
GPG_RES=`LANG=C gpg --list-keys --with-colons "$NAME" 2>&/dev/null | grep -e "^pub" -A 1 | tail -n 1 |  sed -e 's/^.*:\([^:]*\):$/\1/'`
if [ -z "$GPG_RES" ]; then
	echo "I cannot find your master key."
	exit 1
fi
echo -n "Your master key is $GPG_RES, right [Y/n]? "
read SIGN
echo ""
if [ ! "$SIGN" = "y" -a ! "$SIGN" = "Y" -a -n "$SIGN" ]; then
	echo "Exit."
	exit 1
fi
gpg --output /$GPG_RES.gpg-revocation-certificate --gen-revoke $GPG_RES || (
	echo "Export error."
	exit 1
)
echo "Finished."
exit 0
EOF

echo "Creating users..."
NEW_UID=1000
NEW_GID=1000
chroot "$ROOT" groupadd -g "$NEW_GID" "$ORIG_USER"
chroot "$ROOT" useradd -m -u "$NEW_UID" -g "$ORIG_USER" -s "/bin/bash" "$ORIG_USER"
mount "$DEV_FS" "$ROOT_HOME" || errorexit "mount"
while read FILE; do
	if [ ! "$FILE" = "." -a ! -e "$ROOT_HOME/$FILE" ]; then
		cp -r "$ROOT/etc/skel/$FILE" "$ROOT_HOME/$FILE"
		chroot "$ROOT" chown "$ORIG_USER:$ORIG_USER" "/home/$ORIG_USER/$FILE"
	fi
done <<<`cd "$ROOT/etc/skel"; find .`
if [ -d "$WORKING_DIR/files" ]; then
	while read FILE; do
		if [ ! "$FILE" = "." ]; then
			cp -rf "$WORKING_DIR/files/$FILE" "$ROOT_HOME/$FILE"
			chroot "$ROOT" chown "$ORIG_USER:$ORIG_USER" "/home/$ORIG_USER/$FILE"
		fi
	done <<<`cd "$WORKING_DIR/files"; find .`
fi
TRAP_CMD="umount \"$DEV_FS\";$TRAP_CMD"

# Initialize the environment
echo 'echo -e "\e[32mWelcome to the \e[1mgpg-managing-container\e[m\e[32m environment!\e[m"' >> "$ROOT_HOME/.bashrc"
echo 'echo "To see quick reference, type \"cat README.txt\""' >> "$ROOT_HOME/.bashrc"
echo 'export PS1="[\u@\[\e[1;33m\]gpg-container \[\e[m\]\w]$ "' >> "$ROOT_HOME/.bashrc"
echo 'cd ~' >> "$ROOT_HOME/.bashrc"

# Run
echo "Running container..."
systemd-nspawn -D "$ROOT" -- su "$ORIG_USER"

if [ -e "$ROOT/exported-subkeys" ]; then
	echo "Exported subkeys detected. Applying to your machine..."
	chown "$ORIG_USER:$ORIG_USER" "$ROOT/exported-subkeys"
	sudo -u "$ORIG_USER" gpg --import "$ROOT/exported-subkeys" || (
		echo "Subkey import error. All the modifications are discarded."
		exit 1
	)
else
	echo "You have not exported any subkeys."
fi

REV_CERT=`find "$ROOT" -maxdepth 1 -name '*.gpg-revocation-certificate'`
if [ ! -z "$REV_CERT" ]; then
	REV_CERT_BASE=`basename "$REV_CERT"`
	echo "Exported revocation certificate detected."
	echo "Copying it to ~/.gnupg/$REV_CERT_BASE..."
	chown "$ORIG_USER:$ORIG_USER" "$REV_CERT"
	sudo -u "$ORIG_USER" cp "$REV_CERT" "~/.gnupg/$REV_CERT_BASE"
else
	echo "revocation certificate not detected."
fi

if [ ! -e "$KEYFILE" ]; then
	echo "Encrypting and writing new key to $PACKAGE_DIR..."
	mkdir -p -m 700 "$PACKAGE_DIR" || errorexit "mkdir"
	echo "$PASSWORD" | gpg --batch --passphrase-fd 0 -c -o "$KEYFILE" "$TMP_KEYFILE" || errorexit "gpg"
	chmod 0600 "$KEYFILE"
fi

echo "All finished."
echo "I recommended to make a backup of the USB key and store it in safe places in order to protect your credentials."

exit 0

