#!/bin/bash
set -e

# Configuration
CLUSTER_NAME="flask-app-cluster-3"
REGION="us-west-2"
NODE_TYPE="m5.xlarge"  # 4 vCPU, 16GiB memory (meets requirements)
BUCKET_NAME="sudarsan-$(date +%s)"  # Add timestamp to make bucket name unique
DATABASE_PASSWORD=$(openssl rand -base64 16)

# Create EKS cluster
echo "Creating EKS cluster..."
eksctl create cluster \
  --name $CLUSTER_NAME \
  --region $REGION \
  --node-type $NODE_TYPE \
  --nodes 3 \
  --nodes-min 2 \
  --nodes-max 5 \
  --with-oidc \
  --ssh-access \
  --managed

# Update kubeconfig
aws eks update-kubeconfig --name $CLUSTER_NAME --region $REGION

# Install AWS Load Balancer Controller using the correct method
echo "Installing AWS Load Balancer Controller..."
# Add the EKS chart repository
helm repo add eks https://aws.github.io/eks-charts
helm repo update

# Install the AWS Load Balancer Controller
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=$CLUSTER_NAME \
  --set serviceAccount.create=true \
  --set serviceAccount.name=aws-load-balancer-controller

# Create S3 bucket with proper region handling
echo "Creating S3 bucket..."
if [ "$REGION" = "us-east-1" ]; then
  # us-east-1 doesn't use LocationConstraint
  aws s3api create-bucket \
    --bucket $BUCKET_NAME \
    --region $REGION
else
  # All other regions require LocationConstraint
  aws s3api create-bucket \
    --bucket $BUCKET_NAME \
    --region $REGION \
    --create-bucket-configuration LocationConstraint=$REGION
fi

# Enable bucket versioning
aws s3api put-bucket-versioning \
  --bucket $BUCKET_NAME \
  --versioning-configuration Status=Enabled

# Create namespace
kubectl create namespace flask-app

# Create PostgreSQL secret
kubectl create secret generic postgres-secret \
  --namespace flask-app \
  --from-literal=password=$DATABASE_PASSWORD

# Deploy PostgreSQL with resource limits
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: postgres
  namespace: flask-app
spec:
  serviceName: postgres
  replicas: 1
  selector:
    matchLabels:
      app: postgres
  template:
    metadata:
      labels:
        app: postgres
    spec:
      containers:
      - name: postgres
        image: postgres:13
        env:
        - name: POSTGRES_DB
          value: flaskapp
        - name: POSTGRES_USER
          value: flaskuser
        - name: POSTGRES_PASSWORD
          valueFrom:
            secretKeyRef:
              name: postgres-secret
              key: password
        ports:
        - containerPort: 5432
        volumeMounts:
        - name: postgres-storage
          mountPath: /var/lib/postgresql/data
        resources:
          requests:
            cpu: 500m
            memory: 1Gi
          limits:
            cpu: 1000m
            memory: 2Gi
  volumeClaimTemplates:
  - metadata:
      name: postgres-storage
    spec:
      accessModes: [ "ReadWriteOnce" ]
      storageClassName: gp2
      resources:
        requests:
          storage: 10Gi
EOF

# Create PostgreSQL service
kubectl apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: postgres
  namespace: flask-app
spec:
  selector:
    app: postgres
  ports:
    - protocol: TCP
      port: 5432
      targetPort: 5432
EOF

# Wait for PostgreSQL to be ready with better debugging
echo "Waiting for PostgreSQL to be ready..."
for i in {1..30}; do
  POD_STATUS=$(kubectl get pod postgres-0 -n flask-app -o jsonpath='{.status.phase}' 2>/dev/null || echo "Not Found")
  echo "PostgreSQL pod status: $POD_STATUS (attempt $i/30)"
  
  if [ "$POD_STATUS" = "Running" ]; then
    # Check if PostgreSQL is actually ready inside the container
    if kubectl exec -n flask-app postgres-0 -- pg_isready -U flaskuser -d flaskapp; then
      echo "PostgreSQL is ready!"
      break
    fi
  fi
  
  if [ $i -eq 30 ]; then
    echo "PostgreSQL failed to start within the timeout period."
    echo "Debug information:"
    kubectl describe pod postgres-0 -n flask-app
    kubectl logs postgres-0 -n flask-app
    exit 1
  fi
  
  sleep 10
done

# Create AWS IAM policy for S3 access
cat > s3-policy.json <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "s3:PutObject",
                "s3:GetObject",
                "s3:ListBucket"
            ],
            "Resource": [
                "arn:aws:s3:::${BUCKET_NAME}",
                "arn:aws:s3:::${BUCKET_NAME}/*"
            ]
        }
    ]
}
EOF

S3_POLICY_ARN=$(aws iam create-policy \
  --policy-name flask-app-s3-policy \
  --policy-document file://s3-policy.json \
  --query 'Policy.Arn' \
  --output text)

# Create IAM service account for the Flask app
eksctl create iamserviceaccount \
  --name flask-app-sa \
  --namespace flask-app \
  --cluster $CLUSTER_NAME \
  --attach-policy-arn $S3_POLICY_ARN \
  --approve \
  --override-existing-serviceaccounts

# Deploy Flask application
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: flask-app
  namespace: flask-app
  labels:
    app: flask-app
spec:
  replicas: 2
  selector:
    matchLabels:
      app: flask-app
  template:
    metadata:
      labels:
        app: flask-app
    spec:
      serviceAccountName: flask-app-sa
      containers:
      - name: flask-app
        image: 412373517844.dkr.ecr.us-east-1.amazonaws.com/sudarsan/flask-app:latest  # Update with your ECR image
        ports:
        - containerPort: 5000
        env:
        - name: BUCKET_NAME
          value: "${BUCKET_NAME}"
        - name: DATABASE_URL
          value: "postgresql://flaskuser:${DATABASE_PASSWORD}@postgres:5432/flaskapp"
        - name: AWS_REGION
          value: "${REGION}"
        livenessProbe:
          httpGet:
            path: /up
            port: 5000
          initialDelaySeconds: 30
          periodSeconds: 10
        readinessProbe:
          httpGet:
            path: /up
            port: 5000
          initialDelaySeconds: 5
          periodSeconds: 5
        resources:
          requests:
            cpu: 500m
            memory: 512Mi
          limits:
            cpu: 1000m
            memory: 1024Mi
EOF

# Create Flask service
kubectl apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: flask-service
  namespace: flask-app
spec:
  selector:
    app: flask-app
  ports:
    - protocol: TCP
      port: 80
      targetPort: 5000
EOF

# Deploy Ingress
kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: flask-ingress
  namespace: flask-app
  annotations:
    kubernetes.io/ingress.class: alb
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/healthcheck-path: /up
    alb.ingress.kubernetes.io/healthcheck-port: "5000"
spec:
  rules:
  - http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: flask-service
            port:
              number: 80
EOF

# Deploy Horizontal Pod Autoscaler
kubectl apply -f - <<EOF
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: flask-app-hpa
  namespace: flask-app
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: flask-app
  minReplicas: 2
  maxReplicas: 10
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 75
  - type: Resource
    resource:
      name: memory
      target:
        type: Utilization
        averageUtilization: 80
EOF

echo "Deployment completed successfully!"
echo "Waiting for ingress to be created (this may take a few minutes)..."

# Wait for the ingress to be created
sleep 120

# Get the ingress URL
INGRESS_URL=$(kubectl get ingress flask-ingress -n flask-app -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "S3 Bucket Name: ${BUCKET_NAME}"
echo "Application URL: http://${INGRESS_URL}"
echo "You can test the application with:"
echo "curl http://${INGRESS_URL}/up"