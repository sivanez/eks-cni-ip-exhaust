1. Setup access key and secret via aws configure
2. main.tf will create the following
   - vpc with
   - 2 public subnets
   - IAM role and policies for EKS group and node group
   - K8 resource
     - configMap for VPC CNI
     - deployment to simulate ip exhaustion issue
   - 50 replicas to simulate the ip-exhaustion
3. Navigate tf folder and run
   - terraform init
   - teraform apply
4. Explore the EKS Auto Mode in Managed Console
5. Run 'terraform destroy' to destroy the resources to avoid charges.