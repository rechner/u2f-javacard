#!/bin/bash

function usage {
  echo "usage: $0 <cap file> <gp jar> <certificate subject> [extra gp args...]" >&2
  echo "" >&2
  echo "Generates fresh key and certificate, installs applet on a card and" >&2
  echo "uploads a certificate, giving you ready-to-use card" >&2
  echo "" >&2
  echo "If you have a locked card, specify extra arguments like '--key XXX'" >&2
  exit 2
}

if [ -z "$1" -o -z "$2" -o -z "$3" ]; then
  usage
fi

CAP_FILE="$1"
GP_JAR="$2"
CERT_SUBJECT="$3"
shift 3

echo "++ Generating keys and certificates..."

set -e # make shell exit on errors

[ -d "certs" ] || mkdir certs
[ -f "certs/private.pem" ] || openssl ecparam -genkey -name P-256 -out "certs/private.pem"

## Extract OpenSSL config: config is needed to avoid space-consuming extensions like "Subject key info"
if [ ! -f "certs/config.conf" ]; then
  base64 -d <<EOF | gzip -d > "certs/config.conf"
H4sIAJrPK2ECA22MQQqAMAwE73lF/+DZl5QSxC4axFSbKvb3VjzqdWZnvcvYXaAoVkSnQ2xGZB1W
uP5R/BX0YFwFapLU2u7suDGCjjVvhRfUBjUR+f+HQP5NAt0Vsx1wgAAAAA==
EOF
fi

# Generate self-signed cert
[ -f "certs/cert.crt" ] || openssl req -x509 -config "certs/config.conf" -key "certs/private.pem" \
  -sha256 -days 36500 -nodes -out "certs/cert.crt" -subj "/CN=$CERT_SUBJECT"

# Convert from PEM to DER
openssl x509 -in "certs/cert.crt" -outform DER -out "certs/cert.cer"

# Convert private key to just 32 raw bytes
PRIVATE_KEY=$(openssl ec -in "certs/private.pem" -text 2>/dev/null | grep -A 3 priv: | tail -n +2 | tr -d ':[:space:]')
CERT_LENGTH=$(stat --printf "%s" "certs/cert.cer")

echo "++ Installing everything on card..."

function gp {
  echo "+ java -jar \"$GP_JAR\" $@"
  java -jar "$GP_JAR" $@
}

gp "$@" \
  --install "$CAP_FILE" \
  --create A0000006472F0001 \
  --params "00$(printf "%04x" "$CERT_LENGTH")$PRIVATE_KEY"

OFFSET=0
FRAGMENT=64
APDUS=(--apdu "00A4040008A0000006472F0001")

while [ "$OFFSET" -lt "$CERT_LENGTH" ]; do
  CERT_CHUNK=$(dd if="certs/cert.cer" bs=1 skip="$OFFSET" count="$FRAGMENT" status=none | xxd -p -c 9999)
  CHUNK_LENGTH=$(($(echo "$CERT_CHUNK" | wc -c) / 2))
  APDUS=(${APDUS[@]} --apdu "8001$(printf "%04x%02x" "$OFFSET" "$CHUNK_LENGTH")$CERT_CHUNK")
  OFFSET=$(($OFFSET+$FRAGMENT))
done

# Install the certificate
gp ${APDUS[@]}
