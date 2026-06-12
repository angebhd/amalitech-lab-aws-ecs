# Architecture — AWS ECS CI/CD Lab

Highly available, containerized Java web app on **Amazon ECS (Fargate)** in a
custom multi-AZ VPC, fronted by a public **Application Load Balancer**, with
**blue/green** deployments driven by image pushes. Infrastructure is provisioned
by **CloudFormation GitSync**; CI authenticates with **GitHub OIDC** (no static
keys). Region: `eu-north-1`.

## 1. Network architecture

Tasks run **inside the private subnets**; the ALB and NAT Gateway live in the
public subnets.

```mermaid
flowchart TB
    users(["Internet / Users"])
    igw["Internet Gateway"]

    subgraph VPC["VPC 10.0.0.0/16"]
        subgraph PUB["Public subnets — AZ A 10.0.0.0/24 and AZ B 10.0.1.0/24"]
            alb["Application Load Balancer<br/>internet-facing, multi-AZ"]
            nat["NAT Gateway<br/>single / regional"]
        end

        subgraph PRIVA["Private subnet — AZ A 10.0.10.0/24"]
            taskA["Fargate task :8080"]
            vpceA["VPC endpoint ENIs<br/>ecr.api · ecr.dkr · logs"]
        end

        subgraph PRIVB["Private subnet — AZ B 10.0.11.0/24"]
            taskB["Fargate task :8080"]
            vpceB["VPC endpoint ENIs<br/>ecr.api · ecr.dkr · logs"]
        end
    end

    ecr[("Amazon ECR")]
    cw[("CloudWatch Logs")]

    users -->|HTTP 80| igw --> alb
    alb --> taskA
    alb --> taskB
    taskA -->|egress| nat
    taskB -->|egress| nat
    nat --> igw
    taskA --> vpceA
    taskB --> vpceB
    vpceA --> ecr
    vpceB --> ecr
    vpceA --> cw
    vpceB --> cw
```

- ECS tasks sit in the two **private** subnets (`AssignPublicIp: DISABLED`),
  one per AZ for high availability.
- ALB + a **single regional NAT Gateway** sit in the **public** subnets (the NAT
  is physically in AZ A's public subnet and shared by both private subnets).
- Image pulls / logging go through **VPC endpoints** whose ENIs live in the
  private subnets — tasks reach ECR and CloudWatch privately. (An `s3` gateway
  endpoint, attached to the private route table, backs ECR layer downloads.)

## 2. Blue/green traffic routing

The ALB has **two listeners** and **two target groups**. "Blue" and "Green" are
just the two interchangeable slots — at any time one holds the live task set and
the other is free for the next release.

```mermaid
flowchart LR
    alb["Application Load Balancer"]

    prod["Prod listener :80"]
    test["Test listener :8080"]

    blue["Blue target group :8080"]
    green["Green target group :8080"]

    live["ECS task set — current revision"]
    new["ECS task set — new revision"]

    alb --> prod
    alb --> test
    prod -->|live traffic| blue --> live
    test -->|pre-cutover validation| green --> new

    cd["CodeDeploy"] -.->|when green is healthy, swap prod to green| prod
    cd -.->|then drain and terminate| live
```

During a deploy CodeDeploy launches the new revision into the **idle** target
group (green here), validates it via the test listener + ALB health checks, then
**repoints the production listener** from blue → green. The old task set is
drained and terminated after a wait. The next deploy reverses the roles.

## 3. Security groups (least privilege)

```mermaid
flowchart LR
    net(["0.0.0.0/0"]) -->|"port 80"| albsg["ALB SG"]
    albsg -->|"port 8080"| tasksg["Task SG"]
    tasksg -->|"port 443"| vpcesg["VPC Endpoint SG"]
```

- **ALB SG** — inbound `80` from the internet.
- **Task SG** — inbound app port `8080` only from the ALB SG.
- **VPC Endpoint SG** — inbound `443` only from the Task SG.

## 4. CI/CD and deployment pipeline

```mermaid
flowchart LR
    dev(["Developer push to main"]) --> gha["GitHub Actions<br/>OIDC, no static keys"]

    gha -->|push image| ecr[("Amazon ECR<br/>tag ange_buhendwa_sha")]
    gha -->|upload bundle| s3[("S3 artifact bucket<br/>config-source.zip")]

    ecr -->|push event| eb["EventBridge rule"]
    eb -->|start| cp["CodePipeline"]
    s3 -->|S3 source| cp

    cp -->|CodeDeployToECS| cd["CodeDeploy<br/>blue/green"]
    cd -->|register taskdef + shift traffic| ecs["ECS Fargate service"]
```

1. Push to `main` → GitHub Actions assumes an IAM role via **OIDC** and builds the image.
2. Image is tagged **`ange_buhendwa_<commit-sha>`** (consistent, immutable) and
   pushed to ECR; the deploy bundle (`taskdef.json` + `appspec.yaml`, image URI
   baked in) is uploaded to S3.
3. The ECR push emits an **EventBridge** event that starts **CodePipeline**.
4. CodePipeline runs **CodeDeploy (blue/green)** — see section 2.

## 5. Application auto scaling

- ECS service: **min 1 / desired 1 / max 4** tasks.
- Target-tracking on **average CPU = 50%** (`ECSServiceAverageCPUUtilization`).

## 6. Components

| Layer | Resources |
|-------|-----------|
| Network | VPC, 2 public + 2 private subnets, IGW, single NAT GW, route tables |
| Connectivity | VPC endpoints: `ecr.api`, `ecr.dkr`, `logs` (interface) + `s3` (gateway) |
| Compute | ECS cluster, Fargate task definition, service (CODE_DEPLOY controller) |
| Edge | ALB, prod listener `:80`, test listener `:8080`, blue + green target groups |
| Images | ECR repo (immutable tags, scan-on-push, lifecycle: keep last 10) |
| CI | GitHub Actions + IAM OIDC provider/role (ECR push, S3 upload) |
| CD | EventBridge rule, CodePipeline, CodeDeploy app + deployment group, S3 artifacts |
| Observability | CloudWatch Logs (`/ecs/ecs-cicd`), Container Insights |
| Scaling | Application Auto Scaling target + CPU target-tracking policy |

> Provisioned via **CloudFormation GitSync** from this `infrastructure` branch
> (`template.yaml` + `deployment-config.json`). The application code,
> `Dockerfile`, and GitHub Actions workflow live on `main`.
