Supabase Root 2021 CA (public root certificate, not a secret).
Source: https://supabase-downloads.s3-ap-southeast-1.amazonaws.com/prod/ssl/prod-ca-2021.crt (2026-09-02)
Verified 2026-09-02: openssl s_client -connect aws-1-eu-central-1.pooler.supabase.com:5432 -starttls postgres -CAfile <this file> -> Verify return code: 0 (ok)
sha256 Fingerprint=80:70:25:AD:50:D4:ED:21:9D:2C:9C:7D:29:9C:00:4F:82:4E:B0:0C:F7:F6:5A:FE:F6:07:D0:7B:72:E6:CA:FA
Validity: 2021-04-28 .. 2031-04-26
Use: SUPABASE_CA_CERT="$(awk 'BEGIN{ORS="\\n"}1' admin/certs/supabase-prod-ca-2021.crt)"
