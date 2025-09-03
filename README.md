# DevOps Engineer - EKS Practical Challenge

## Overview
This project provisions a production-style EKS deployment that runs a small Flask micro-service. The application persists data in PostgreSQL, stores files in s3, and automatically scales under load.

## Deployment Instructions
The deployment is managed using a shell script `deploy.sh` to set up an Amazon Elastic Kubernetes Service (EKS) cluster.

### Prerequisites
- AWS CLI configured with appropriate credentials.
- `kubectl` installed and configured.
- `eksctl` installed for EKS cluster management.
- Docker installed for building container images.

### Steps
1. **Clone the Repository**
   Clone this repository to your local machine.

2. **Run the Deployment Script**
   Execute the `deploy.sh` script to provision the EKS cluster and deploy the application:
   ```bash
   ./deploy.sh
   ```
   - The script creates a "regional" EKS cluster in any region with at least one `e2-standard-4` node (4 vCPU / 16 GiB).
   - It sets up the necessary Kubernetes objects and configures autoscaling.

3. **Verify Deployment**
   Use the following command to check the status of the pods:
   ```bash
   kubectl get pods
   ```
   Ensure all pods are in the `Running` state.

4. **Access the Application**
   The Flask micro-service is exposed externally via an Ingress. Use `kubectl get ingress` to find the external IP and access the endpoints.

5. **Load Testing and Autoscaling**
   - Follow the instructions in the script or additional documentation for a load test.
   - Monitor autoscaling by checking pod replicas with `kubectl get hpa`.

## Application Details
- **Endpoints:**
  - `GET /up` - Returns 200 OK (health probe).
  - `POST /upload` - Accepts a file and saves it to a s3 bucket (`<your-name>-uploads`).
  - `GET /file/<name>` - Streams the file back from s3.
- **Database:** PostgreSQL with a PersistentVolumeClaim.
- **Secret Management:** Uses Kubernetes Secrets for credentials.

## Kubernetes Objects
- Deployment for the Flask app.
- Service (ClusterIP) + Ingress (HTTP/HTTPS) exposing the app externally.
- Readiness & liveness probes wired to `/up`.

## Autoscaling
- HorizontalPodAutoscaler (autoscaling/v2) configured with:
  - `minReplicas: 2`, `maxReplicas: 10`
  - `targetCPUUtilizationPercentage: 75`
  - `targetMemoryUtilizationPercentage: 80`
- Provides a short load test to push utilization over thresholds and demonstrate scaling.

## Infrastructure-as-Code
- EKS cluster, s3 bucket, and Kubernetes manifests are managed via `deploy.sh`.
Load Testing
To demonstrate auto-scaling, you can run a load test:

## Install hey load testing tool
 ```bash
go install github.com/rakyll/hey@latest
```
## Run load test
```bash
hey -n 10000 -c 100 http://<INGRESS_URL>/up
```
## Monitor autoscaling
```bash
kubectl get hpa -n flask-app --watch
```
## View pod scaling
```bash
kubectl get pods -n flask-app --watch
```
