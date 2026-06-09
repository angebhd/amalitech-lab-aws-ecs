# AWS ECS CI/CD — Infrastructure

CloudFormation (deployed via **GitSync**) for a highly available, containerized
Java web app on **Amazon ECS (Fargate)** with **blue/green** deployments.

> This is the **`infrastructure`** orphan branch — infra code only. The
> application code (Spring Boot app + `Dockerfile`) lives on `main`.

## Architecture

```
Internet ──▶ ALB (public subnets, 2 AZ)
                │  prod listener :80  ┐
                │  test listener :8080│─▶ blue / green target groups
                ▼
        ECS Fargate service (private subnets, 2 AZ)
                │   pulls image via VPC endpoints (ecr.api / ecr.dkr / s3 / logs)
                ▼
              Amazon ECR (immutable tags, scan on push)

GitHub Actions ──(OIDC)──▶ build + push immutable SHA image to ECR
                       └──▶ upload config-source.zip (taskdef+appspec, image baked in)
ECR push ──▶ EventBridge ──▶ CodePipeline (S3 source) ──▶ CodeDeploy (blue/green) ──▶ ECS
```

- **Single regional NAT Gateway** for private-subnet egress (cost optimization).
- **VPC interface endpoints** (`ecr.api`, `ecr.dkr`, `logs`) + **S3 gateway
  endpoint** so image pulls and logging stay on the AWS network.
- **Least-privilege security groups**: ALB allows `:80` from the internet; tasks
  accept the container port only from the ALB; endpoints accept `:443` only from
  tasks.
- **Auto scaling**: 1 desired / 1 min / 4 max, target tracking on average CPU.
- **OIDC**: GitHub Actions assumes an IAM role to push to ECR — no static keys.

## Files

| File | Purpose |
|------|---------|
| `template.yaml` | The full CloudFormation stack. |
| `deployment-config.json` | GitSync deployment file (template path + parameters + tags). |

> The CodeDeploy deploy descriptors (`taskdef.json`, `appspec.yaml`) live with
> the application on `main` under `deploy/`. The GitHub Actions workflow renders
> them with the exact image URI and uploads `config-source.zip` to the artifact
> bucket — the pipeline's S3 source action consumes it.

## Image tagging — strictly immutable

The ECR repo is `IMMUTABLE`. Every build is tagged with the **commit SHA** only;
no mutable `latest` tag is ever re-pointed. Because the deploy bundle bakes in
that exact SHA image URI, the pipeline deploys precisely the pushed image —
there is no ECR source action tracking a moving tag.

## Deploy (GitSync)

1. In the CloudFormation console: **Create stack → Sync from Git**, point it at
   this repo/branch, and select `deployment-config.json` as the deployment file.
2. CloudFormation provisions the stack and re-syncs on every push to this branch.

## Bootstrap

The stack creates cleanly on its own: the service starts on a small public
placeholder image (`BootstrapImage`) that serves HTTP 200 on the container port,
so it passes ALB health checks before any application image exists.

Then push to `main` once — the GitHub Actions workflow (OIDC) builds the
SHA-tagged image, renders `taskdef.json`/`appspec.yaml`, uploads
`config-source.zip` to the artifact bucket, and pushes the image. That ECR push
fires EventBridge → CodePipeline → CodeDeploy, which replaces the placeholder
with the real image (blue/green). Every subsequent push repeats the flow.

## Outputs

`AlbDnsName`, `EcrRepositoryUri`, `GitHubActionsRoleArn`, `ArtifactBucketName`,
`ClusterName`, `ServiceName`.
