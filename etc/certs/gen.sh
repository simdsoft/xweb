# refer to: 
#   - https://www.baeldung.com/openssl-self-signed-cert
#   - https://gist.github.com/Barakat/675c041fd94435b270a25b5881987a30
#   - https://stackoverflow.com/questions/18233835/creating-an-x509-v3-user-certificate-by-signing-csr
#   - https://certificatetools.com/
# cert settings

script_dir=$(cd "$(dirname "$0")" && pwd)
cd $script_dir

function years_to_days {
  years=$1
  time_ts=`date +%s`
  date_year=`date +%Y`
  date_ts=`date -d @$time_ts --iso-8601=seconds`
  date_expire_year=`expr $date_year + $years`
  date_expire_ts=${date_ts/$date_year/$date_expire_year}
  time_expire_ts=`date -d $date_expire_ts +%s`
  days=$((($time_expire_ts - $time_ts) / 86400))
  echo $days
}

# v1 only support single domain name ssl cert
is_v1=$1
force=$2
key_bits=2048
# firefox requre domain name
domain_name="xweb.dev"
hash_alg=-sha384
issued_org='Simdsoft Limited'

# issuer information
issuer_valid_years=1003
issuer_org='Simdsoft Limited'
issuer_name="Simdsoft RSA CA $issuer_valid_years"
issuer_subj="/C=CN/O=$issuer_org/CN=$issuer_name"


valid_years=3

if [ "$force" = 'true' ] ; then
  echo 'force regen certs ...'
  rm ./ca-**
  rm ./server.*
fi

# Create Self-Signed Root CA(Certificate Authority)
issuer_valid_days=`years_to_days $issuer_valid_years`
if [ ! -f "ca-prk.pem" ] ; then
  if [ "$is_v1" != 'true' ] ; then
    openssl req -newkey rsa:$key_bits $hash_alg -nodes -keyout ca-prk.pem -x509 -days $issuer_valid_days -out ca-cer.pem -subj "$issuer_subj"; cp ca-cer.pem ca-cer.crt
  else
    openssl genrsa -out ca-prk.pem $key_bits
    openssl req -new $hash_alg -key ca-prk.pem -out ca-csr.pem -subj "$issuer_subj"
    openssl x509 -req -signkey ca-prk.pem -in ca-csr.pem -out ca-cer.pem -days $issuer_valid_days
  fi
fi

# Server

# 1. Generate unencrypted 2048-bits RSA private key for the server (CA) & Generate CSR for the server
valid_days=`years_to_days $valid_years`
openssl req -newkey rsa:$key_bits $hash_alg -nodes -keyout server.key -out server-csr.pem -subj "/C=CN/O=$issued_org/CN=$domain_name"

# 2. Sign with our RootCA
if [ "$is_v1" != 'true' ] ; then
  # subjectAltName in extfile is important for browser visit
  v3ext_file=`pwd`/v3.ext
  openssl x509 -req $hash_alg -in server-csr.pem -CA ca-cer.pem -CAkey ca-prk.pem -CAcreateserial -out server.crt -days $valid_days -extfile $v3ext_file
else
  openssl x509 -req $hash_alg -in server-csr.pem -CA ca-cer.pem -CAkey ca-prk.pem -CAcreateserial -out server.crt -days $valid_days
fi

rm -rf ./server-csr.pem

# Check if the certificate is signed properly
openssl x509 -in server.crt -noout -text

cd -
