#!/bin/bash

# --- CONFIGURATION ---
ANSIBLE_PROJECT="/home/noc/ansible"           
INVENTORY="$ANSIBLE_PROJECT/inventory"
ANSIBLE_ENV=(PYTHONNOUSERSITE=1 PYENV_VERSION=3.9.7 ANSIBLE_CONFIG="$ANSIBLE_PROJECT/ansible.cfg")

# Check dependencies
for bin in sshpass jq ansible env grep sed col; do
  command -v $bin >/dev/null || { echo "Missing dependency: $bin"; exit 1; }
done

# --- FUNCTIONS ---
get_creds() {
  local fqdn="$1"
  local raw_output
  local clean_line

  # 1. Run Ansible with a custom delimiter message
  raw_output="$(env "${ANSIBLE_ENV[@]}" ansible "$fqdn" \
      -i "$INVENTORY" \
      -m debug \
      -a "msg=__START_CREDS__|{{ansible_user}}|{{ansible_password}}|{{ansible_ssh_port}}|{{ansible_ssh_args}}|__END_CREDS__" \
      --connection=local)"

  # 2. Extract the specific line
  clean_line="$(echo "$raw_output" | grep "__START_CREDS__" | grep "__END_CREDS__")"

  if [[ -z "$clean_line" ]]; then 
      echo "    [Ansible Error] Raw Output: $raw_output"
      return 1 
  fi

  # 3. Clean up the delimiters
  local payload
  payload=$(echo "$clean_line" | sed -n 's/.*__START_CREDS__|\(.*\)|__END_CREDS__.*/\1/p')

  # 4. Split by pipe '|'
  VAULT_USER=$(echo "$payload" | cut -d'|' -f1)
  VAULT_PASS=$(echo "$payload" | cut -d'|' -f2)
  SSH_PORT=$(echo "$payload" | cut -d'|' -f3)
  SSH_ARGS=$(echo "$payload" | cut -d'|' -f4)

  # Validate
  if [[ "$VAULT_PASS" == *"{{"* && "$VAULT_PASS" == *"}}"* ]]; then
      echo "    [Error] Password variable was not resolved: $VAULT_PASS"
      return 1
  fi
  
  # Handle undefined vars
  if [[ "$VAULT_USER" =~ "VARIABLE IS NOT DEFINED" ]]; then VAULT_USER=""; fi
  if [[ "$SSH_PORT" =~ "VARIABLE IS NOT DEFINED" ]]; then SSH_PORT=""; fi
  if [[ "$SSH_ARGS" =~ "VARIABLE IS NOT DEFINED" ]]; then SSH_ARGS=""; fi

  [[ -n "$VAULT_PASS" && ! "$VAULT_PASS" =~ "VARIABLE IS NOT DEFINED" ]]
}

# --- MAIN SCRIPT ---

mapfile -t devices < devices.txt
timeStamp=$(date +%Y%m%d)
fileName="./data/locker_${timeStamp}.txt"
defectFile="./data/defect_${timeStamp}.csv"
previousTimestamp=$(date -d "yesterday" +%Y%m%d)
previousDefectFile="./data/defect_${previousTimestamp}.csv"

mkdir -p ./data
touch "$defectFile" "$fileName"

for device in "${devices[@]}"
do
  target_host="$device.vpn.ipsip.eu"
  
  echo "---------------------------------------------"
  echo "Processing $device..."

  # 1. RETRIEVE CREDENTIALS
  if ! get_creds "$target_host"; then
    echo "ERROR: Could not find credentials for $target_host"
    continue
  fi

  ssh_user="${VAULT_USER:-$USER}"

  # 2. PREPARE SSH OPTIONS
  SSH_OPTS=()
  [[ -n "$SSH_PORT" ]] && SSH_OPTS+=(-p "$SSH_PORT")
  [[ -n "$SSH_ARGS" ]] && SSH_OPTS+=($SSH_ARGS) # Jump host args

  # Flags: -tt is CRITICAL for sudo, but requires us to fix the output later
  SSH_FLAGS=(-tt -o PreferredAuthentications=password -o PubkeyAuthentication=no -o StrictHostKeyChecking=no -o ConnectTimeout=15)

  echo "${device}_${timeStamp}" >> "$fileName"

  # 3. RUN COMMANDS
  echo "  > Connecting as $ssh_user..."
  
  # Command A: Dump table
  # FIX ADDED: '-P pager=off' stops the hang.
  # FIX ADDED: '| col -bx' removes the garbage characters from the TTY output.
  SSHPASS="$VAULT_PASS" sshpass -e ssh "${SSH_FLAGS[@]}" "${SSH_OPTS[@]}" \
      "$ssh_user@$target_host" "sudo -u postgres psql -P pager=off -d apv_device2 -c \"SELECT * FROM locker\"" \
      | col -bx >> "$fileName" 2>/dev/null

  # Command B: Get defect count
  # FIX ADDED: '-P pager=off' here too, just in case.
  defectCount=$(SSHPASS="$VAULT_PASS" sshpass -e ssh "${SSH_FLAGS[@]}" "${SSH_OPTS[@]}" \
      "$ssh_user@$target_host" "sudo -u postgres psql -P pager=off -t -A -d apv_device2 -c \"SELECT COUNT(*) FROM locker WHERE status='DEFECT';\"" 2>/dev/null | col -bx | tr -d ' \t\n\r')

  # Validate Result
  if [[ -z "$defectCount" ]]; then
     echo "  ! Warning: Connection failed or no output returned."
     defectCount=0 
  elif ! [[ "$defectCount" =~ ^[0-9]+$ ]]; then
     # Attempt to clean result: Extract first number found
     cleanCount=$(echo "$defectCount" | grep -oE '[0-9]+' | head -n1)
     if [[ -n "$cleanCount" ]]; then
        defectCount=$cleanCount
     else
        echo "  ! Warning: Received invalid data: '$defectCount'"
        defectCount=0
     fi
  fi

  echo "${device}:${defectCount}" >> "$defectFile"
  echo "=============================================" >> "$fileName"

  # 4. COMPARE WITH YESTERDAY
  if [ -f "$previousDefectFile" ]; then
    previousCountLine=$(grep "^${device}:" "$previousDefectFile" || true)
    previousDefectCount=0
    
    if [ ! -z "$previousCountLine" ]; then
      previousDefectCount=$(echo "$previousCountLine" | cut -d: -f2)
    fi
    
    if [[ "$defectCount" -gt "$previousDefectCount" ]]; then
      difference=$((defectCount - previousDefectCount))
      echo ""
      echo "!!! ALERT: DEFECT SPIKE on $device !!!"
      echo "Previous: $previousDefectCount | Current: $defectCount | Increase: +$difference"
      echo ""
    else
      echo "  > Status: Stable ($defectCount vs $previousDefectCount)"
    fi
  else
    echo "  > NOTE: No history found for comparison."
  fi
  
  unset VAULT_PASS VAULT_USER SSH_ARGS
done