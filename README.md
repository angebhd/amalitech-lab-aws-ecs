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

GitHub Actions ──(OIDC)──▶ push image to ECR
ECR push ──▶ EventBridge ──▶ CodePipeline ──▶ CodeDeploy (blue/green) ──▶ ECS
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
| `taskdef.json` | ECS task definition template consumed by CodeDeploy. |
| `appspec.yaml` | CodeDeploy ECS appspec (container/port to shift traffic to). |

## Deploy (GitSync)

1. In the CloudFormation console: **Create stack → Sync from Git**, point it at
   this repo/branch, and select `deployment-config.json` as the deployment file.
2. CloudFormation provisions the stack and re-syncs on every push to this branch.

## Bootstrap order (one time)

ECR starts empty, so seed an image before the service can become healthy:

1. After the stack creates ECR, push an image tagged `latest` (the GitHub
   Actions workflow on `main` does this via OIDC).
2. Fill the literal placeholders in `taskdef.json` before zipping the config
   source — `<ACCOUNT_ID>` and `<AWS_REGION>` (CodeDeploy only substitutes
   `<IMAGE1_NAME>`).
3. Zip `taskdef.json` + `appspec.yaml` into `config-source.zip` and upload it to
   the artifact bucket (`ArtifactBucketName` output):

   ```bash
   zip config-source.zip taskdef.json appspec.yaml
   aws s3 cp config-source.zip "s3://$(aws cloudformation describe-stacks \
     --stack-name <stack> --query 'Stacks[0].Outputs[?OutputKey==`ArtifactBucketName`].OutputValue' \
     --output text)/config-source.zip"
   ```

Subsequent pushes (immutable git-SHA tags) trigger EventBridge → CodePipeline →
CodeDeploy blue/green automatically.

## Outputs

`AlbDnsName`, `EcrRepositoryUri`, `GitHubActionsRoleArn`, `ArtifactBucketName`,
`ClusterName`, `ServiceName`.
