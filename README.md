# DevOps Assessment: Flask CI/CD Pipeline

Production-ready CI/CD reference implementation: a Flask microservice, a multi-stage Dockerfile,
a Helm chart, a GitHub Actions pipeline (build → scan → push → deploy → smoke test → auto-rollback),
and a standalone `deploy.sh` for manual deployments.

See **[DEPLOYMENT_GUIDE.md](./DEPLOYMENT_GUIDE.md)** for full documentation.

## Quick Start

```bash
# Run locally
pip install -r requirements.txt
python app.py
curl http://localhost:5000/health

# Build the Docker image
docker build -t devops-assessment-app:v1.0.0 .
docker run -p 5000:5000 devops-assessment-app:v1.0.0

# Lint and preview the Helm chart
helm lint ./helm
helm template devops-assessment-app ./helm

# Deploy manually
./deploy.sh production v1.0.0 docker.io/your-dockerhub-username
```

## Stack

- **App**: Python 3.12 / Flask / Gunicorn
- **Container**: Multi-stage Docker build, non-root user, healthcheck
- **CI/CD**: GitHub Actions (SemVer tagging, Trivy scanning, Docker Hub, Helm, smoke tests, auto-rollback)
- **Orchestration**: Kubernetes via Helm (Deployment, Service, Ingress, HPA)

## Repository Layout

```
project/
├── .github/workflows/deploy.yml
├── helm/{Chart.yaml,values.yaml,templates/}
├── Dockerfile
├── deploy.sh
├── DEPLOYMENT_GUIDE.md
├── requirements.txt
├── app.py
└── README.md
```
