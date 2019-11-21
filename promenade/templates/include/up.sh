# Disable overwriting our resolv.conf
#
if [ -h /etc/resolv.conf ]; then
  log "=== Removing resolv.conf symlink ==="
  rm -f /etc/resolv.conf
fi

CURATED_DIRS=(
    /etc/kubernetes
    /var/lib/etcd
)

APT_INSTALL_TIMEOUT=${APT_INSTALL_TIMEOUT:-1800}

for DIR in "${CURATED_DIRS[@]}"; do
    mkdir -p "${DIR}"
    chmod 700 "${DIR}"
done

# Unpack prepared files into place
#
set +x
log
log === Extracting prepared files ===
{{ decrypt_setup_command }}
echo "{{ encrypted_tarball | b64enc }}" | base64 -d | {{ decrypt_command }} | tar -zxv -C / | tee /etc/promenade-manifest
{{ decrypt_teardown_command }}
set -x

# Enabling kubectl bash autocompletion
#
kubectl completion bash > /etc/bash_completion.d/kubectl

for DIR in "${CURATED_DIRS[@]}"; do
    chmod -R go-rwx "${DIR}"
done

# Adding apt repositories
#
set +x
log
log === Adding APT Keys===
set -x
{% for role in roles %}
{%- for key in config.get_path('HostSystem:packages.' + role + '.keys', []) %}
apt-key add - <<"ENDKEY"
{{ key }}
ENDKEY
{%- endfor %}
{%- endfor %}

# Disable swap
#
set +x
log
log === Disabling swap ===
set -x
swapoff -a
sed --in-place '/\bswap\b/d' /etc/fstab

# Set proxy variables
#
set +x
log
log === Setting proxy variables ===
set -x
export http_proxy={{ config['KubernetesNetwork:proxy.url'] | default('', true) }}
export https_proxy={{ config['KubernetesNetwork:proxy.url'] | default('', true) }}
export no_proxy={{ config.get(kind='KubernetesNetwork') | fill_no_proxy }}


# Install system packages
#
set +x
log
log === Installing system packages ===
set -x

end=$(($(date +%s) + APT_INSTALL_TIMEOUT))
while true; do
    if ! apt-get update; then
        now=$(date +%s)
        if [[ ${now} -gt ${end} ]]; then
            log Failed to update apt-cache.
            exit 1
        fi
        sleep 10
    else
        break
    fi
done

{% for role in roles %}
    while true; do
        if ! DEBIAN_FRONTEND=noninteractive apt-get install -o Dpkg::Options::="--force-confold" -y --no-install-recommends \
                {%- for package in config['HostSystem:packages.' + role + '.additional'] | default([]) %}
                {{ package }} \
                {%- endfor %}
                {%- if config['HostSystem:packages.' + role + '.required.docker']  is defined %}
                    {{ config['HostSystem:packages.' + role + '.required.docker'] }} \
                {%- elif config['HostSystem:packages.' + role + '.required.runtime']  is defined %}
                    {{ config['HostSystem:packages.' + role + '.required.runtime'] }} \
                {%- endif %}
                {{ config['HostSystem:packages.' + role + '.required.socat'] }}; then
            now=$(date +%s)
            if [[ ${now} -gt ${end} ]]; then
                log Failed to install apt packages.
                exit 1
            fi
            sleep 10
        else
            break
        fi
    done
{% endfor %}

# Start core processes
#
set +x
log
log === Starting Docker and Kubelet ===
set -x
systemctl daemon-reload

{% for a in ['enable','start','stop','disable'] %}
{% for u in config.get_units_by_action(a) %}
systemctl {{ a }} {{ u }}
{% endfor %}
{% endfor %}

if systemctl -q is-enabled docker > /dev/null 2>&1; then
  systemctl restart docker || true
fi
if systemctl -q is-enabled containerd > /dev/null 2>&1; then
  systemctl restart containerd || true
fi
systemctl enable kubelet
systemctl restart kubelet
