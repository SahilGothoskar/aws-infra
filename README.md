### AWS Virtual Private Cloud (VPC) Configuration

```

This Terraform configuration creates a Virtual Private Cloud (VPC) in Amazon Web Services (AWS) with the following components:

- A VPC with a specific CIDR block of 10.0.0.0/16 and tagged with "main-vpc".
- 6 subnets, 3 public and 3 private, with CIDR blocks generated based on the count.index.
- An Internet Gateway with the tag "main-igw" and associated with the VPC.
- 2 route tables, public and private, with respective tags "public-route-table" and "private-route-table".
- Public route table associated with public subnets and private route table associated with private subnets.
- A default route to the internet through the main Internet Gateway.

```
    ### AWS Provider Configuration
```

The provider block sets up the AWS provider for Terraform and allows for the region to be set using the var.region variable. The access 
and secret keys are also specified. This setup makes it possible to use a different region by simply changing the value of var.region.

```
### Subnet Configuration

```
The subnets are created in the aws_subnet block with the public subnets tagged with "public-${count.index + 1}" and private subnets tagged with "private-${count.index + 1}". The CIDR blocks for these subnets are generated based on the value of count.index.

```

### Internet Gateway Configuration

```
An Internet Gateway is created in the aws_internet_gateway block and tagged with "main-igw". It is associated with the main VPC.

```

### Route Table Configuration

```

The public and private route tables are created in the aws_route_table block, with respective tags "public-route-table" and 
"private-route-table".

```
### Route Table Association Configuration

```

The public route table is associated with the public subnets in the aws_route_table_association block, and the private route table is associated with the private subnets.

```
### Default Route Configuration

```

A default route to the internet is created in the aws_route block, where the destination CIDR block is set to 0.0.0.0/0 and the gateway is the main Internet Gateway.

```

### AWS Infrastructure Configuration for S3 and RDS 

```
This Terraform script creates an S3 bucket, applies server-side encryption and lifecycle policies to it, and sets up a policy to deny public access to the bucket. It also provisions an RDS instance with a PostgreSQL engine, along with an IAM policy to enable access to the S3 bucket for the RDS instance.

-  Generates a random name for the S3 bucket using random_pet resource
-  Creates an S3 bucket with a randomly generated name, applies server-side encryption, and sets up a lifecycle policy to transition  objects to Standard-IA after 30 days
-  Applies a policy to deny public access to the S3 bucket
-  Creates an IAM policy to enable the RDS instance to access the S3 bucket and its objects
-  Creates an RDS instance with a PostgreSQL engine and provisions it with a parameter group, subnet group, security group, and sets up an endpoint output

```

### Provisioning AWS Route 53 DNS Record for EC2 Instance 

```

- The variable block defines a variable named domain_name with the type string. This allows the user to input the domain name they want to use.
- The output block defines an output named public_ip with the value of the first public_ip attribute of the EC2 instance resource. This allows the user to retrieve the public IP address of the instance after it's created.
- The data block uses the aws_route53_zone data source to retrieve the Route53 hosted zone ID for the given domain name.
- The resource block creates a new Route53 aws_route53_record resource. This resource maps the domain name to the EC2 instance's public IP address by creating a DNS record of type A. The zone_id argument specifies the ID of the Route53 hosted zone, which is obtained from the data block. 
- The ttl argument specifies the time-to-live value for the DNS record, and the records argument specifies the IP address to which the domain name should resolve. In this case, the IP address is taken from the public_ip output of the EC2 instance resource.


```

### Provisioning AWS Security Groups for Application and Database Instances with Terraform

```

**aws_security_group.instance resource:**

- Creates a security group for the application instance
- Allows incoming traffic on ports 22 (SSH), 80 (HTTP), 443 (HTTPS), and 5000 (application-specific port) from any IP address
- Allows outgoing traffic to any IP address and any port
- Tags the security group with the name "application-sg"

**aws_security_group.db resource:**

    Creates a security group for the database instance
    Allows incoming traffic on port 5432 (PostgreSQL default port) only from the application instance's security group
    Allows outgoing traffic to any IP address and any port
    Tags the security group with the name "db-sg"
    
```
## To run the code


```
# terraform init 

# terraform plan  ( It will prompt to enter the ami-id and region)

# terraform apply --auto-approve (Enter the ami-id generated from the packer build  and run in the required region )

```