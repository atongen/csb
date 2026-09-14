(* AWS credential injection: which variables an `aws_profile=` launch owns.

   csb injects SHORT-LIVED credentials and nothing else. The host's ~/.aws stays
   in the read deny floor, so a launch carries the session in its environment or
   it has no AWS access at all -- there is no file for the sandbox to fall back
   to, and the two pins below make sure the SDK does not go looking for one.

   The variable names are data, like an agent adapter's: bin/csb extracts and
   injects whatever this table names and decides nothing about which variables
   those are. *)

(* What `aws configure export-credentials --format env` emits for a TEMPORARY
   session, and what bin/csb requires ALL of. A profile resolving to long-lived
   IAM user keys emits only the first two, which is exactly how the launch
   detects -- and refuses -- credentials that never expire. *)
let expiry_var = "AWS_CREDENTIAL_EXPIRATION"

let cred_vars =
  [ "AWS_ACCESS_KEY_ID"; "AWS_SECRET_ACCESS_KEY"; "AWS_SESSION_TOKEN"; expiry_var ]

(* export-credentials does not emit the region. Both spellings are injected from
   the profile's configured one, because which of the two an SDK reads depends on
   the SDK. *)
let region_vars = [ "AWS_REGION"; "AWS_DEFAULT_REGION" ]

(* Pinned for the launch so the in-sandbox SDK uses the injected session and
   nothing else. Under --real-home the real ~/.aws exists but is denied, and an
   SDK that tries to read it gets a sandbox denial rather than a clean miss. *)
let file_pins =
  [ ("AWS_CONFIG_FILE", "/dev/null"); ("AWS_SHARED_CREDENTIALS_FILE", "/dev/null") ]

(* Naming a profile inside the sandbox sends the SDK to the denied ~/.aws for its
   definition, so these may not be kept across the scrub alongside an injection. *)
let profile_vars = [ "AWS_PROFILE"; "AWS_DEFAULT_PROFILE" ]

(* Every variable the injection owns: no other layer may name one of these. *)
let owned = cred_vars @ region_vars @ List.map fst file_pins

(* Every AWS endpoint sits under this, which is what the --filter-egress hint in
   Resolve tests an allowlist against. *)
let endpoint_suffix = "amazonaws.com"
