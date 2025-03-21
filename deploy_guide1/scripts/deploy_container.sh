name: Build and Deploy with Self-hosted Runner

on:
  push:
    branches: [ main ]  # Trigger workflow on push to the main branch

jobs:
  build-and-deploy:
    runs-on: self-hosted  # Uses a self-hosted runner

    steps:
      - name: Checkout code
        uses: actions/checkout@v2  # Clones the repository

      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@v1
        with:
          aws-access-key-id: ${{ secrets.AWS_ACCESS_KEY_ID }}
          aws-secret-access-key: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
          aws-region: ap-south-1  # AWS region for deployment

      - name: Login to Amazon ECR
        id: login-ecr
        uses: aws-actions/amazon-ecr-login@v1  # Logs into Amazon ECR

      - name: Build, tag, and push image to Amazon ECR
        id: build-image
        env:
          ECR_REGISTRY: ${{ steps.login-ecr.outputs.registry }}
          ECR_REPOSITORY: ${{ secrets.ECR_REPOSITORY }}
          IMAGE_TAG: ${{ github.sha }}
        run: |
          # Build the docker image
          docker build -t $ECR_REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG .
          docker tag $ECR_REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG $ECR_REGISTRY/$ECR_REPOSITORY:latest
          
          # Push the docker images to ECR
          docker push $ECR_REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG
          docker push $ECR_REGISTRY/$ECR_REPOSITORY:latest

      - name: Install Nginx
        run: |
          # Install Nginx if not installed
          if ! command -v nginx &> /dev/null; then
            echo "Installing Nginx..."
            sudo apt-get update
            sudo apt-get install -y nginx
          fi
          
          # Ensure necessary directories exist
          sudo mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled

      - name: Deploy Container
        env:
          ECR_REGISTRY: ${{ steps.login-ecr.outputs.registry }}
          ECR_REPOSITORY: ${{ secrets.ECR_REPOSITORY }}
          IMAGE_TAG: ${{ github.sha }}
        run: |
          # Stop and remove any existing container
          docker stop streamlit-container 2>/dev/null || true
          docker rm streamlit-container 2>/dev/null || true
          
          # Run the new container
          docker run -d --name streamlit-container -p 8501:8501 --restart always $ECR_REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG
          
          # Configure Nginx
          echo "Creating Nginx configuration..."
          cat > /tmp/streamlit_nginx << 'EOL'
          server {
              listen 80;
              server_name _;
              location / {
                  proxy_pass http://localhost:8501;
                  proxy_http_version 1.1;
                  proxy_set_header Upgrade $http_upgrade;
                  proxy_set_header Connection "upgrade";
                  proxy_set_header Host $host;
                  proxy_cache_bypass $http_upgrade;
                  proxy_read_timeout 86400;
              }
          }
          EOL
          
          # Apply Nginx configuration
          sudo cp /tmp/streamlit_nginx /etc/nginx/sites-available/streamlit
          sudo ln -sf /etc/nginx/sites-available/streamlit /etc/nginx/sites-enabled/
          sudo rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true
          
          # Test and restart Nginx
          sudo nginx -t && sudo systemctl restart nginx
