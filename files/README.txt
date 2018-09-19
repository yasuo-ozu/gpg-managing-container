= Quick reference for gpg-managing-container =

# Generate the key
gpg --gen-key

# List your keys (and check your MASTERID)
gpg --list-keys name

# Add photo
gpg --edit-key MASTERID
addphoto

# Create subkeys
gpg --edit-key MASTERID
addkey

# Apply subkey to your host
apply-subkey

# Copy revocation-certificate to your host
export-revocation-certificate

