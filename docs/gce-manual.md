# Manual Google Compute Engine installation

This guide creates a dedicated Google Compute Engine VM, a persistent profile
disk, and an optional GCS backup bucket. It uses placeholders only. Review every
command and substitute values for your project and domain.

## Prerequisites

Install and authenticate the Google Cloud CLI, select a billed project, and
choose a domain you control. The examples use an Ubuntu 24.04 amd64 image, an
`e2-standard-2` VM (2 vCPU, 8 GiB RAM), and a 50 GiB balanced Persistent Disk.

```bash
export GCP_PROJECT=remote-chrome-example
export GCP_REGION=us-central1
export GCP_ZONE=us-central1-a
export VM_NAME=remote-chrome
export DISK_NAME=remote-chrome-data
export BUCKET_NAME=remote-chrome-example-backups
export SERVICE_ACCOUNT_NAME=remote-chrome-vm
export DOMAIN=chrome.example.com

gcloud config set project "${GCP_PROJECT}"
gcloud services enable compute.googleapis.com storage.googleapis.com
```

The account running these commands needs permission to manage Compute Engine,
service accounts, project firewall rules, and the selected bucket.

## Reserve a Static IP

Reserve the address before creating DNS or the VM:

```bash
gcloud compute addresses create remote-chrome-ip \
  --project="${GCP_PROJECT}" \
  --region="${GCP_REGION}"

export STATIC_IP="$(
  gcloud compute addresses describe remote-chrome-ip \
    --project="${GCP_PROJECT}" \
    --region="${GCP_REGION}" \
    --format='value(address)'
)"
printf 'Reserved address: %s\n' "${STATIC_IP}"
```

Create an `A` record for `${DOMAIN}` pointing to `${STATIC_IP}`. Wait until the
record resolves publicly before running the installer.

## Create the Service Account

Create a VM identity without project-wide Storage roles:

```bash
gcloud iam service-accounts create "${SERVICE_ACCOUNT_NAME}" \
  --project="${GCP_PROJECT}" \
  --display-name='Remote Chrome VM'

export SA_EMAIL="${SERVICE_ACCOUNT_NAME}@${GCP_PROJECT}.iam.gserviceaccount.com"
```

The VM receives the `cloud-platform` OAuth scope, but IAM still limits what it
can do. The only Storage role granted below is bucket-scoped.

## Create the Backup Bucket

Bucket names are globally unique. Create the bucket with uniform bucket-level
access (UBLA) and public access prevention (PAP), then grant only
`roles/storage.objectUser` on this bucket:

```bash
gcloud storage buckets create "gs://${BUCKET_NAME}" \
  --project="${GCP_PROJECT}" \
  --location="${GCP_REGION}" \
  --uniform-bucket-level-access \
  --public-access-prevention

gcloud storage buckets add-iam-policy-binding "gs://${BUCKET_NAME}" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role='roles/storage.objectUser'
```

That bucket-scoped role permits the VM to upload and list backup objects and to
download them for restore. Do not grant public access or a project-wide Storage
role.

## Create and Attach the Persistent Disk

Create a non-boot balanced Persistent Disk. Do not format it from your local
machine:

```bash
gcloud compute disks create "${DISK_NAME}" \
  --project="${GCP_PROJECT}" \
  --zone="${GCP_ZONE}" \
  --type=pd-balanced \
  --size=50GB
```

The VM creation command in the next section attaches it with the explicit
device name `${DISK_NAME}`.

## Create the VM

Create the Ubuntu 24.04 x86_64 VM with the reserved address, dedicated service
account, persistent disk, and a tag used only by the two public firewall rules:

```bash
gcloud compute instances create "${VM_NAME}" \
  --project="${GCP_PROJECT}" \
  --zone="${GCP_ZONE}" \
  --machine-type=e2-standard-2 \
  --image-family=ubuntu-2404-lts-amd64 \
  --image-project=ubuntu-os-cloud \
  --boot-disk-size=20GB \
  --address="${STATIC_IP}" \
  --service-account="${SA_EMAIL}" \
  --scopes=https://www.googleapis.com/auth/cloud-platform \
  --tags=remote-chrome-server \
  --disk=name="${DISK_NAME}",device-name="${DISK_NAME}",mode=rw,boot=no,auto-delete=no
```

## Open Ports 80 and 443

Expose only TCP 80 and 443, and target only the dedicated VM tag. Internal MCP,
Chrome debugging, VNC, and noVNC ports remain container-internal.

```bash
gcloud compute firewall-rules create remote-chrome-web \
  --project="${GCP_PROJECT}" \
  --direction=INGRESS \
  --allow=tcp:80,tcp:443 \
  --source-ranges=0.0.0.0/0 \
  --target-tags=remote-chrome-server
```

Connect over SSH:

```bash
gcloud compute ssh "${VM_NAME}" \
  --project="${GCP_PROJECT}" \
  --zone="${GCP_ZONE}"
```

## Prepare the Data Disk

Never guess or assume a Linux device name and never substitute `/dev/sdb`.
Resolve the exact stable Google device link, inspect mounts, block layout, and
filesystem metadata, and run `blkid` before considering any format operation:

```bash
EXPECTED_LINK=/dev/disk/by-id/google-remote-chrome-data
test -L "${EXPECTED_LINK}" || {
  printf 'Expected disk link is missing: %s\n' "${EXPECTED_LINK}" >&2
  exit 1
}
RESOLVED_DEVICE="$(readlink -f -- "${EXPECTED_LINK}")"
printf 'Stable link: %s\nResolved device: %s\n' \
  "${EXPECTED_LINK}" "${RESOLVED_DEVICE}"

sudo findmnt --source "${RESOLVED_DEVICE}" || true
sudo lsblk -o NAME,PATH,SIZE,TYPE,FSTYPE,FSVER,LABEL,UUID,MOUNTPOINTS \
  "${RESOLVED_DEVICE}"
sudo blkid "${RESOLVED_DEVICE}" || true
```

Stop if the device, its partitions, `findmnt`, `lsblk`, or `blkid` show data,
a filesystem, or a mount you did not expect. Snapshot or detach it and
investigate. Only format an empty disk after the operator has verified that
this exact device contains no data.

The following destructive command is deliberately gated by two typed
confirmations. Type the exact resolved device path, then explicitly decide that
the inspected disk is empty. If either answer differs, nothing is formatted.

```bash
read -r -p "Type the exact resolved device path (${RESOLVED_DEVICE}): " \
  CONFIRMED_DEVICE
test "${CONFIRMED_DEVICE}" = "${RESOLVED_DEVICE}" || {
  printf 'Device confirmation did not match; refusing to format.\n' >&2
  exit 1
}
read -r -p 'After inspecting all output, type FORMAT EMPTY DISK: ' EMPTY_DECISION
test "${EMPTY_DECISION}" = 'FORMAT EMPTY DISK' || {
  printf 'Empty-disk decision not confirmed; refusing to format.\n' >&2
  exit 1
}
sudo mkfs.ext4 -L remote-chrome-data "${RESOLVED_DEVICE}"
```

Mount by filesystem UUID. Back up `/etc/fstab` before editing it, validate the
UUID, run a mount test, and verify the target:

```bash
export DATA_UUID="$(sudo blkid -s UUID -o value "${RESOLVED_DEVICE}")"
test -n "${DATA_UUID}" || {
  printf 'No filesystem UUID found; refusing to edit /etc/fstab.\n' >&2
  exit 1
}
sudo install -d -m 0750 /var/lib/remote-chrome
sudo cp --archive /etc/fstab /etc/fstab.before-remote-chrome
printf 'UUID=%s /var/lib/remote-chrome ext4 defaults,nofail 0 2\n' \
  "${DATA_UUID}" |
  sudo tee -a /etc/fstab >/dev/null
sudo mount -a
findmnt --target /var/lib/remote-chrome
sudo touch /var/lib/remote-chrome/.mount-test
sudo rm /var/lib/remote-chrome/.mount-test
```

If the new entry is wrong, roll back `/etc/fstab` to the backup before doing
anything else:

```bash
sudo umount /var/lib/remote-chrome 2>/dev/null || true
sudo cp --archive /etc/fstab.before-remote-chrome /etc/fstab
sudo mount -a
findmnt --target /var/lib/remote-chrome || true
```

## Run the Interactive Installer

Confirm DNS points to the reserved address and no existing process owns host
ports 80 or 443. From the VM's SSH session, run:

```bash
curl -fsSL https://raw.githubusercontent.com/eladrave/remotechromemcp/master/vminstall/install.sh | sudo sh
```

Enter the domain, ACME certificate email, `/var/lib/remote-chrome` data
directory, GCS bucket name, and optional systemd backup schedule at `/dev/tty`.
The installer stops on DNS, port, proxy, or certificate preflight failures.

## Verify HTTPS and MCP

At completion, copy the protected handoff to your own password manager. Retrieve
it later only in the SSH terminal:

```bash
sudo remote-chrome status
sudo remote-chrome credentials
curl -fsS "https://${DOMAIN}/healthz"
```

Test the MCP URL and `/login/` URL shown by `credentials`; do not paste the MCP
token or login password into chat.

## Configure GCS Backup

If the bucket was not selected during installation, rerun the guided installer
or a pinned update with the GCS bucket and schedule. Verify the VM identity,
then create a quiesced backup:

```bash
gcloud auth list
gcloud storage ls "gs://${BUCKET_NAME}"
sudo remote-chrome backup
sudo remote-chrome status
```

Backups stop only the browser service, create checksummed objects, upload the
manifest last, then restart and health-check the browser.

## Reboot and Restore Test

First create a backup and record the exact manifest URI reported by
`sudo remote-chrome status`. Reboot, verify the persistent mount and service,
then perform a restore drill only when overwriting the current browser profile
is intended:

```bash
sudo remote-chrome backup
sudo reboot
```

Reconnect after the reboot:

```bash
findmnt --target /var/lib/remote-chrome
sudo remote-chrome status
sudo remote-chrome restore \
  "gs://${BUCKET_NAME}/remote-chrome/<exact-backup>.manifest"
sudo remote-chrome status
```

Use an exact manifest URI from the configured bucket; never invent one. Confirm
that HTTPS, MCP initialization, `/login/`, and the expected profile state still
work after the restore.
