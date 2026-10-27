# bootc image pipeline on AWS (Terraform)

Continuously builds a bootc image from a Git repo with CodePipeline and CodeBuild, publishes it to ECR as a signed multi-arch image, and optionally turns each build into an AMI.

```
push to branch / weekly schedule
        │
   ┌────▼────┐   ┌──────────┐   ┌────────────────┐   ┌─────────┐   ┌──────────────────┐   ┌─────────────────────────┐
   │ Source  ├──►│ Builder  ├──►│ Build          ├──►│ Publish ├──►│ AMI (optional)   ├──►│ Promote (optional)      │
   │ Git     │   │ podman   │   │ amd64 │ arm64  │   │ index   │   │ amd64 │ arm64    │   │ approve → :stable       │
   │ commit  │   │ image    │   │ build+lint+push│   │ sign    │   │ bib → snapshot   │   │                         │
   └─────────┘   │ (cached) │   └────────────────┘   │ :latest │   │ → AMI → SSM param│   └─────────────────────────┘
                 └──────────┘                        └─────────┘   └──────────────────┘
```

| Tag | Meaning |
| --- | --- |
| `<commit12>-<exec8>` | Immutable multi-arch build. Unique per run, so scheduled rebuilds of the same commit never overwrite each other. |
| `<commit12>-<exec8>-<arch>` | Per-arch image the index points to. |
| `latest` (`channel_tag`) | Every successful build. |
| `stable` (`promotion_tag`) | Builds that passed manual approval. Point production hosts here. |

## Layout

```
terraform/          Root module: ECR, IAM, CodeBuild projects, CodePipeline V2, KMS, schedule, AMI import
buildspecs/         builder, build, publish, promote, ami — embedded into the CodeBuild projects by Terraform
builder/Containerfile   podman + skopeo + cosign + awscli image every build runs on
example/Containerfile   Minimal bootc image to drop into your source repo
```

Your source repo only needs the Containerfile and whatever it copies in. Buildspecs live here, so changing how images are built is a `terraform apply`, not a commit to every image repo.

## Deploy

1. Put a Containerfile in your image repo (start from `example/Containerfile`).
2. For RHEL bases, create a Secrets Manager secret with a [registry service account](https://access.redhat.com/terms-based-registry/):
   ```bash
   aws secretsmanager create-secret --name rh-registry \
     --secret-string '{"username":"1234567|my-svc","password":"..."}'
   ```
3. Configure and apply:
   ```bash
   cd terraform
   cp terraform.tfvars.example terraform.tfvars   # edit repository_id, architectures, ...
   terraform init
   terraform apply
   ```
4. If Terraform created the Git connection, open **Developer Tools → Settings → Connections** in the console and finish the handshake once (`connection_status` goes from `PENDING` to `AVAILABLE`). The first pipeline run fails until then. Rerun it with "Release change".

The first run builds the builder image (a few minutes). After that the Builder stage is a skip until `builder/Containerfile` changes.

## Consume the image

**Switch a host to the pipeline's image:**

```bash
sudo bootc switch <image_repository_url>:stable
sudo bootc upgrade --apply   # or let bootc-fetch-apply-updates.timer do it
```

**Registry auth.** bootc reads `/etc/ostree/auth.json`. ECR tokens last 12 hours, so hosts need a refresh before each check for updates:

```ini
# /etc/systemd/system/ecr-auth.service  (run from a timer every 6h, and before bootc-fetch-apply-updates.service)
[Service]
Type=oneshot
ExecStart=/bin/sh -c 'aws ecr get-login-password --region us-east-1 | podman login --authfile /etc/ostree/auth.json --username AWS --password-stdin 111122223333.dkr.ecr.us-east-1.amazonaws.com'
```

Credentials depend on where the host runs:

- **On EC2:** attach `image_pull_policy_arn` to the instance profile.
- **Edge devices outside AWS:** use IAM Roles Anywhere so devices authenticate with an X.509 certificate instead of long-lived keys. Alternatively, mirror ECR into an on-site registry (Quay, Harbor) and point devices there.

**Enforce signatures on hosts.** Bake these two files into the image so hosts refuse unsigned updates.

`/etc/containers/policy.json`, which requires a signature for this repository only:

```json
{
  "default": [{ "type": "insecureAcceptAnything" }],
  "transports": {
    "docker": {
      "111122223333.dkr.ecr.us-east-1.amazonaws.com/edge-os": [
        { "type": "sigstoreSigned", "keyPath": "/etc/pki/containers/edge-os.pub", "signedIdentity": { "type": "matchRepository" } }
      ]
    },
    "docker-daemon": { "": [{ "type": "insecureAcceptAnything" }] }
  }
}
```

`/etc/containers/registries.d/edge-os.yaml`, which tells the client to look for cosign signatures next to the image:

```yaml
docker:
  111122223333.dkr.ecr.us-east-1.amazonaws.com/edge-os:
    use-sigstore-attachments: true
```

Write `terraform output -raw cosign_public_key` to `/etc/pki/containers/edge-os.pub` in the image. Then use `bootc switch --enforce-container-sigpolicy` for the first switch. Check a build by hand with:

```bash
cosign verify --key cosign.pub --insecure-ignore-tlog <image>@<digest>
```

**Launch from AMIs** (`enable_ami = true`). Each build writes its AMI ID to `/<name>/bootc/ami/<arch>` in SSM Parameter Store. A launch template using `resolve:ssm:/<name>/bootc/ami/amd64` always gets the newest one. AMI hosts still update in place with `bootc upgrade`, so AMIs only matter for new instances.

## Notes and troubleshooting

- **Podman inside CodeBuild** relies on `privileged_mode` and on `quay.io/podman/stable` declaring `/var/lib/containers` as a volume, so overlay storage sits on a real filesystem. If a build fails with overlay mount errors, add `ENV STORAGE_DRIVER=vfs` to `builder/Containerfile`. This is slower but works anywhere.
- **bootc-image-builder needs loop devices.** The AMI stage checks for them up front and fails with a clear message if CodeBuild's managed hosts don't expose them. The fix is a CodeBuild reserved-capacity fleet (EC2 compute): create an `aws_codebuild_fleet` and add a `fleet { fleet_arn = ... }` block to the `environment` of `aws_codebuild_project.ami`.
- **Base image updates.** `rebuild_schedule` reruns the pipeline weekly with no commit, so CVE fixes in the base image reach hosts. `--pull=always` makes sure the build sees them.
- **Concurrency.** The pipeline uses the V2 default (superseded): a newer run replaces an older one waiting at the same stage, including at approval. Set `execution_mode = "QUEUED"` on `aws_codepipeline.bootc` if every build must be reviewed.
- **Retention.** ECR expires only untagged images (`untagged_image_expiry_days`). Tagged builds stay until you prune them, since per-arch images and signatures must outlive any index that references them.
- **Cost drivers.** Builds use `BUILD_GENERAL1_LARGE` by default. Each AMI adds a 20–40 minute import plus snapshot storage. Leave `enable_ami` off unless you launch new instances from these images.

## Tear down

```bash
terraform destroy
```

The image repository is not force-deleted, so destroy stops while it still holds images. Empty it first, or set `force_delete = true` on `aws_ecr_repository.image`. AMIs and snapshots made by the pipeline aren't tracked in Terraform; deregister them separately.
