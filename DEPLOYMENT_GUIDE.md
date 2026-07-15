# Deployment Guide

## 1. Project Overview

This project is a production-ready CI/CD reference implementation for a containerized Flask
microservice. It demonstrates an end-to-end DevOps pipeline:

1. Code is pushed to GitHub.
2. GitHub Actions builds a Docker image and assigns it a Semantic Versioning tag (e.g. `v1.2.3`).
3. The image is scanned for vulnerabilities with **Trivy**.
4. On `main`, the image is pushed to **Docker Hub**.
5. The application is deployed to Kubernetes using a **Helm** chart (`helm upgrade --install`,
   fully idempotent).
6. Automated **smoke tests** hit the `/health` endpoint.
7. If anything fails — the deploy, the rollout, or the smoke test — the pipeline **automatically
   rolls back** to the last known-good release.

The same logic is also available as a standalone script (`deploy.sh`) for manual or
break-glass deployments outside of CI.

---

## 2. Folder Structure

```
project/
│
├── .github/
│   └── workflows/
│       └── deploy.yml          # CI/CD pipeline definition
│
├── helm/
│   ├── Chart.yaml               # Helm chart metadata
│   ├── values.yaml              # Default configuration values
│   └── templates/
│       ├── _helpers.tpl         # Shared named templates (labels, names)
│       ├── deployment.yaml      # Kubernetes Deployment
│       ├── service.yaml         # Kubernetes Service (ClusterIP)
│       ├── ingress.yaml         # Kubernetes Ingress
│       ├── hpa.yaml             # HorizontalPodAutoscaler
│       └── serviceaccount.yaml  # Dedicated ServiceAccount
│
├── Dockerfile                    # Multi-stage production image build
├── deploy.sh                     # Manual/CI deployment script
├── DEPLOYMENT_GUIDE.md            # This document
├── requirements.txt               # Python dependencies
├── app.py                         # Flask application source
└── README.md                      # Quick-start overview
```

---

## 3. Prerequisites

Install the following locally (or ensure they exist on your CI runner):

| Tool | Minimum Version | Purpose |
|---|---|---|
| Docker | 24.x | Build/run container images |
| kubectl | 1.28+ | Interact with the Kubernetes cluster |
| Helm | 3.12+ | Deploy the application chart |
| Trivy | 0.50+ | Local vulnerability scanning (optional; CI runs this too) |
| Git | 2.x | Version control / tagging |
| A running Kubernetes cluster | 1.28+ | EKS, GKE, AKS, kind, or minikube all work |
| An NGINX Ingress Controller | any recent | Required if `ingress.enabled: true` |

---

## 4. Docker Hub Secrets

Create a [Docker Hub Access Token](https://hub.docker.com/settings/security) (avoid using your
account password). You will store this as a GitHub secret in the next section.

| Secret | Description |
|---|---|
| `DOCKERHUB_USERNAME` | Your Docker Hub username or organization name |
| `DOCKERHUB_TOKEN` | Docker Hub access token with **Read/Write** permission |

---

## 5. GitHub Secrets

Configure these under **Repository → Settings → Secrets and variables → Actions**:

| Secret | Description |
|---|---|
| `DOCKERHUB_USERNAME` | Docker Hub username/namespace used to tag and push images |
| `DOCKERHUB_TOKEN` | Docker Hub access token |
| `KUBE_CONFIG` | Base64-encoded kubeconfig with access to the target cluster (`cat ~/.kube/config \| base64 -w0`) |

For stronger security in real production environments, prefer short-lived, workload-identity-based
cluster credentials (e.g. cloud IAM roles for GitHub OIDC) over a long-lived static kubeconfig.

---

## 6. Kubernetes Requirements

- A namespace will be created automatically (`app-production` by default, idempotent creation).
- Cluster RBAC: the service account used by CI must be able to create/update Deployments,
  Services, Ingresses, HPAs, and ServiceAccounts in the target namespace.
- Metrics Server must be installed for the HPA (`autoscaling.enabled: true`) to function.
- An Ingress controller (e.g. `ingress-nginx`) and `cert-manager` (for TLS) if `ingress.enabled: true`.

---

## 7. Helm Installation

```bash
# Validate the chart's syntax and structure
helm lint ./helm

# Preview rendered Kubernetes manifests without applying them
helm template devops-assessment-app-production ./helm

# Install or upgrade (idempotent — safe to re-run)
helm upgrade --install devops-assessment-app-production ./helm \
  --namespace app-production \
  --create-namespace \
  --set image.repository=your-dockerhub-username/devops-assessment-app \
  --set image.tag=v1.0.0 \
  --wait --timeout 120s
```

---

## 8. Workflow Explanation (`.github/workflows/deploy.yml`)

| Job | Trigger | Purpose |
|---|---|---|
| `build` | push + pull_request | Computes the next SemVer tag from the latest git tag, builds the Docker image with Buildx, saves it as an artifact for downstream jobs |
| `scan` | push + pull_request | Loads the built image and scans it with **Trivy**; fails the build on CRITICAL/HIGH vulnerabilities; uploads SARIF results to the GitHub Security tab |
| `push` | push to `main` only | Logs into Docker Hub and pushes both the versioned tag and `latest` |
| `deploy` | push to `main` only | Runs `helm lint`, renders the chart, deploys with `helm upgrade --install` (retried up to 3 times), waits on `kubectl rollout status`, runs smoke tests against `/health`, and **automatically rolls back** via `helm rollback` (falling back to `kubectl rollout undo`) if any prior step failed |

Pull requests only run `build` and `scan` — they never push images or touch the cluster,
so it's always safe to open a PR against `main`.

---

## 9. Manual Deployment

Use `deploy.sh` for deployments outside of CI (e.g. hotfixes, break-glass access):

```bash
chmod +x deploy.sh
./deploy.sh <environment> <version> <image_registry>

# Example
./deploy.sh production v1.2.3 docker.io/your-dockerhub-username
```

`deploy.sh`:
- Validates that `environment` is one of `dev|staging|production`, `version` matches SemVer
  (`vX.Y.Z`), and `image_registry` is non-empty with no whitespace.
- Confirms `kubectl` and `helm` are installed.
- Ensures the target namespace exists (idempotent).
- Runs `helm lint` before touching the cluster.
- Deploys with `helm upgrade --install`, retrying transient failures with backoff.
- Waits for `kubectl rollout status`.
- Runs a smoke test against `/health` via a temporary `kubectl port-forward`.
- Automatically rolls back (`helm rollback` → `kubectl rollout undo` fallback) if the rollout
  or smoke test fails, using a `trap`-based cleanup handler that also fires on `Ctrl+C`.
- Logs every step with UTC timestamps to `deploy.log`.
- Exits with a distinct, documented exit code per failure class (see below).

### Exit Codes

| Code | Meaning |
|---|---|
| 0 | Success |
| 10 | Invalid arguments |
| 11 | Missing dependency (`kubectl`/`helm` not found) |
| 12 | `helm lint` failed |
| 13 | `helm upgrade --install` failed after retries |
| 14 | `kubectl rollout status` timed out/failed |
| 15 | Smoke test failed |
| 16 | Rollback itself failed (requires manual intervention) |

---

## 10. Rollback Procedure

### Automatic
Both the GitHub Actions workflow and `deploy.sh` roll back automatically when the rollout or
smoke test fails — no manual action needed in most cases.

### Manual rollback
```bash
# View release history
helm history devops-assessment-app-production -n app-production

# Roll back to the previous revision
helm rollback devops-assessment-app-production 0 -n app-production --wait

# Or roll back a raw Deployment directly
kubectl rollout undo deployment/devops-assessment-app-production -n app-production

# Confirm the rollback succeeded
kubectl rollout status deployment/devops-assessment-app-production -n app-production
```

---

## 11. Troubleshooting

| Symptom | Likely Cause | Fix |
|---|---|---|
| `ImagePullBackOff` | Wrong registry/tag, or missing `imagePullSecrets` | Verify `image.repository`/`image.tag`, confirm the image was pushed, add a pull secret for private registries |
| `CrashLoopBackOff` | App fails to start / bad env vars | `kubectl logs <pod> -n <namespace>`, verify `PORT`/`APP_VERSION` env vars |
| `helm upgrade` hangs then times out | Pods never become Ready (failing probes) | Check `kubectl describe pod`, verify `/health` responds on port 5000 |
| Smoke test fails but pods are Running | Service selector/port mismatch | Confirm `service.targetPort` (5000) matches the container port |
| `Error: INSTALLATION FAILED: cannot re-use a name` | Prior failed install left orphaned resources | `helm uninstall <release> -n <namespace>` then redeploy, or use `--replace` cautiously |
| Trivy scan fails the build | Vulnerable base image or dependency | Rebuild from an updated `python:3.12-slim`, run `pip list --outdated`, review the SARIF report in the Security tab |
| `kubectl` "Unable to connect to the server" | Bad/expired `KUBE_CONFIG` secret | Regenerate kubeconfig, re-base64-encode, update the GitHub secret |

---

## 12. Common Errors

- **`Error: unable to build kubernetes objects from release manifest`** — usually an
  `apiVersion` mismatch with your cluster version. Confirm `networking.k8s.io/v1` is supported
  (Kubernetes 1.19+).
- **`Error: failed to download chart`** — you referenced a remote chart path incorrectly; this
  project uses a local chart at `./helm`, not a remote repo.
- **`exec format error`** — image was built for the wrong CPU architecture; add
  `--platform linux/amd64` (or `arm64`) to the `docker build`/Buildx step.
- **`x509: certificate signed by unknown authority`** — kubeconfig's cluster CA doesn't match;
  regenerate the kubeconfig from a trusted source, don't strip TLS verification.

---

## 13. Verification Commands

```bash
# Confirm the Helm release is deployed and healthy
helm status devops-assessment-app-production -n app-production

# Check pod status
kubectl get pods -n app-production -l app.kubernetes.io/instance=devops-assessment-app-production

# Check rollout history
kubectl rollout history deployment/devops-assessment-app-production -n app-production

# Check HPA status
kubectl get hpa -n app-production

# Check ingress
kubectl get ingress -n app-production

# Tail application logs
kubectl logs -f deployment/devops-assessment-app-production -n app-production
```

---

## 14. Smoke Testing Commands

```bash
# Port-forward locally
kubectl port-forward svc/devops-assessment-app-production 18080:80 -n app-production &

# Hit the health endpoint
curl -i http://localhost:18080/health

# Expected response
# HTTP/1.1 200 OK
# {"status": "healthy"}

# Check the deployed version matches what you expect
curl -s http://localhost:18080/version
```
